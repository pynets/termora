import 'dart:io';

import 'package:termora/features/database/data/db_service.dart';
import 'package:termora/features/database/domain/db_live_metrics.dart';
import 'package:termora/features/database/domain/db_metrics.dart';
import 'package:termora/features/database/domain/db_models.dart';

/// 采集数据库整体指标(概览面板用)。自开自关连接,与页面活动会话解耦。
class DbMetricsService {
  DbMetricsService._();

  static const _topN = 12;

  static Future<DbMetrics> load(DbConnectionConfig config) async {
    final conn = await DbService.open(config);
    try {
      return switch (config.engine) {
        DbEngine.postgres => await _postgres(conn),
        DbEngine.clickhouse => await _clickhouse(conn),
        DbEngine.sqlite => await _sqlite(conn, config),
      };
    } finally {
      await conn.close();
    }
  }

  // ══════════════ 实时采样(轻量,复用已开连接;每 N 秒一次)══════════════

  /// 在已开连接上做一次轻量采样;[previous] 用于把累积计数器换算成每秒速率。
  static Future<DbLiveSample> sampleLive(
    DbConnection conn,
    DbConnectionConfig config, {
    DbLiveSample? previous,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    switch (config.engine) {
      case DbEngine.postgres:
        final rows = await _rows(conn, '''
SELECT
  (SELECT count(*) FROM pg_stat_activity
     WHERE datname = current_database())::int,
  (SELECT xact_commit + xact_rollback FROM pg_stat_database
     WHERE datname = current_database())::bigint,
  (SELECT sum(blks_hit)::float8 / NULLIF(sum(blks_hit) + sum(blks_read), 0)
     FROM pg_stat_database WHERE datname = current_database()),
  pg_database_size(current_database())::bigint''');
        final r = rows.isEmpty ? const <Object?>[] : rows.first;
        final counter = r.length > 1 ? _int(r[1]) : 0;
        return DbLiveSample(
          tMillis: now,
          activeConnections: r.isNotEmpty ? _int(r[0]) : null,
          cacheHit: r.length > 2 ? _double(r[2]) : null,
          dbBytes: r.length > 3 ? _int(r[3]) : 0,
          counter: counter,
          ratePerSec: _rate(previous, counter, now),
        );

      case DbEngine.clickhouse:
        final rows = await _rows(conn, '''
SELECT
  (SELECT value FROM system.metrics WHERE metric = 'Query'),
  (SELECT value FROM system.events WHERE event = 'Query'),
  (SELECT sum(bytes_on_disk) FROM system.parts
     WHERE active AND database = currentDatabase())''');
        final r = rows.isEmpty ? const <Object?>[] : rows.first;
        final counter = r.length > 1 ? _int(r[1]) : 0;
        return DbLiveSample(
          tMillis: now,
          activeConnections: r.isNotEmpty ? _int(r[0]) : null,
          dbBytes: r.length > 2 ? _int(r[2]) : 0,
          counter: counter,
          ratePerSec: _rate(previous, counter, now),
        );

      case DbEngine.sqlite:
        var bytes = 0;
        try {
          bytes = File(config.database).lengthSync();
        } catch (_) {}
        return DbLiveSample(tMillis: now, dbBytes: bytes);
    }
  }

  /// 累积计数器 → 每秒速率(计数器回退=服务重启,返回 null)
  static double? _rate(DbLiveSample? prev, int counter, int nowMs) {
    if (prev?.counter == null) return null;
    final dc = counter - prev!.counter!;
    final dt = (nowMs - prev.tMillis) / 1000.0;
    if (dt <= 0 || dc < 0) return null;
    return dc / dt;
  }

  // ── 通用小工具 ──

  static Future<List<List<Object?>>> _rows(DbConnection c, String sql) async {
    final (out, _) = await DbService.runSql(c, sql);
    return out.rows;
  }

  static int _int(Object? v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('$v') ?? double.tryParse('$v')?.toInt() ?? 0;
  }

  static double? _double(Object? v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse('$v');
  }

  // ══════════════ PostgreSQL ══════════════

  static Future<DbMetrics> _postgres(DbConnection c) async {
    final version = await DbService.serverVersion(c);

    final size = await _rows(c, 'SELECT pg_database_size(current_database())');
    final databaseBytes = size.isEmpty ? 0 : _int(size.first.first);

    final counts = await _rows(c, '''
SELECT
  count(*) FILTER (WHERE table_type = 'BASE TABLE'),
  count(*) FILTER (WHERE table_type = 'VIEW'),
  count(DISTINCT table_schema)
FROM information_schema.tables
WHERE table_schema NOT LIKE 'pg\\_%' AND table_schema <> 'information_schema' ''');
    final tableCount = counts.isEmpty ? 0 : _int(counts.first[0]);
    final viewCount = counts.isEmpty ? 0 : _int(counts.first[1]);
    final schemaCount = counts.isEmpty ? 0 : _int(counts.first[2]);

    // reltuples 对从未 ANALYZE 的表是 -1,统计时按 0 计
    final top = await _rows(c, '''
SELECT n.nspname, c.relname,
       pg_total_relation_size(c.oid)::bigint,
       GREATEST(c.reltuples, 0)::bigint
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p')
  AND n.nspname NOT LIKE 'pg\\_%' AND n.nspname <> 'information_schema'
ORDER BY 3 DESC
LIMIT $_topN''');

    final schemaAgg = await _rows(c, '''
SELECT n.nspname, count(*),
       COALESCE(sum(pg_total_relation_size(c.oid)), 0)::bigint,
       COALESCE(sum(GREATEST(c.reltuples, 0)), 0)::bigint
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p')
  AND n.nspname NOT LIKE 'pg\\_%' AND n.nspname <> 'information_schema'
GROUP BY n.nspname
ORDER BY 3 DESC''');

    var approxRows = 0;
    for (final r in schemaAgg) {
      approxRows += _int(r[3]);
    }

    int? active, maxConn;
    try {
      final cn = await _rows(c, '''
SELECT (SELECT count(*) FROM pg_stat_activity
        WHERE datname = current_database()),
       (SELECT setting::int FROM pg_settings WHERE name = 'max_connections')''');
      if (cn.isNotEmpty) {
        active = _int(cn.first[0]);
        maxConn = _int(cn.first[1]);
      }
    } catch (_) {}

    double? cacheHit;
    try {
      final ch = await _rows(c, '''
SELECT sum(blks_hit)::float8 / NULLIF(sum(blks_hit) + sum(blks_read), 0)
FROM pg_stat_database WHERE datname = current_database()''');
      if (ch.isNotEmpty) cacheHit = _double(ch.first.first);
    } catch (_) {}

    Duration? uptime;
    try {
      final up = await _rows(
        c,
        'SELECT extract(epoch FROM now() - pg_postmaster_start_time())::bigint',
      );
      if (up.isNotEmpty) uptime = Duration(seconds: _int(up.first.first));
    } catch (_) {}

    return DbMetrics(
      engine: DbEngine.postgres,
      version: version,
      databaseBytes: databaseBytes,
      schemaCount: schemaCount,
      tableCount: tableCount,
      viewCount: viewCount,
      approxRows: approxRows,
      activeConnections: active,
      maxConnections: maxConn,
      cacheHitRatio: cacheHit,
      uptime: uptime,
      topTables: [
        for (final r in top)
          DbTableMetric(
            schema: '${r[0]}',
            table: '${r[1]}',
            bytes: _int(r[2]),
            rows: _int(r[3]),
          ),
      ],
      schemas: [
        for (final r in schemaAgg)
          DbSchemaMetric(
            schema: '${r[0]}',
            tableCount: _int(r[1]),
            bytes: _int(r[2]),
          ),
      ],
    );
  }

  // ══════════════ ClickHouse ══════════════

  static Future<DbMetrics> _clickhouse(DbConnection c) async {
    final version = await DbService.serverVersion(c);

    final counts = await _rows(c, '''
SELECT
  countIf(engine NOT LIKE '%View'),
  countIf(engine LIKE '%View')
FROM system.tables WHERE database = currentDatabase()''');
    final tableCount = counts.isEmpty ? 0 : _int(counts.first[0]);
    final viewCount = counts.isEmpty ? 0 : _int(counts.first[1]);

    final top = await _rows(c, '''
SELECT database, table, sum(bytes_on_disk), sum(rows)
FROM system.parts WHERE active AND database = currentDatabase()
GROUP BY database, table ORDER BY 3 DESC LIMIT $_topN''');

    final agg = await _rows(c, '''
SELECT sum(bytes_on_disk), sum(rows)
FROM system.parts WHERE active AND database = currentDatabase()''');
    final databaseBytes = agg.isEmpty ? 0 : _int(agg.first[0]);
    final approxRows = agg.isEmpty ? 0 : _int(agg.first[1]);

    int schemaCount = 1;
    try {
      schemaCount = (await DbService.listSchemas(c)).length;
    } catch (_) {}

    Duration? uptime;
    try {
      final up = await _rows(c, 'SELECT uptime()');
      if (up.isNotEmpty) uptime = Duration(seconds: _int(up.first.first));
    } catch (_) {}

    return DbMetrics(
      engine: DbEngine.clickhouse,
      version: version,
      databaseBytes: databaseBytes,
      schemaCount: schemaCount,
      tableCount: tableCount,
      viewCount: viewCount,
      approxRows: approxRows,
      uptime: uptime,
      topTables: [
        for (final r in top)
          DbTableMetric(
            schema: '${r[0]}',
            table: '${r[1]}',
            bytes: _int(r[2]),
            rows: _int(r[3]),
          ),
      ],
    );
  }

  // ══════════════ SQLite ══════════════

  static Future<DbMetrics> _sqlite(
    DbConnection c,
    DbConnectionConfig config,
  ) async {
    final version = await DbService.serverVersion(c);

    var databaseBytes = 0;
    try {
      databaseBytes = File(config.database).lengthSync();
    } catch (_) {}

    final tableRows = await _rows(c, '''
SELECT name, type FROM sqlite_master
WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\'
ORDER BY name''');
    var tableCount = 0, viewCount = 0;
    final tableNames = <String>[];
    for (final r in tableRows) {
      if (r[1] == 'view') {
        viewCount++;
      } else {
        tableCount++;
        tableNames.add('${r[0]}');
      }
    }

    // 逐表 count(*)(sqlite 表通常不多;取行数最多的若干张)
    final metrics = <DbTableMetric>[];
    var approxRows = 0;
    for (final name in tableNames) {
      try {
        final cnt = await _rows(
          c,
          'SELECT count(*) FROM "${name.replaceAll('"', '""')}"',
        );
        final rows = cnt.isEmpty ? 0 : _int(cnt.first.first);
        approxRows += rows;
        metrics.add(DbTableMetric(schema: '', table: name, rows: rows));
      } catch (_) {}
    }
    metrics.sort((a, b) => b.rows.compareTo(a.rows));

    return DbMetrics(
      engine: DbEngine.sqlite,
      version: version,
      databaseBytes: databaseBytes,
      schemaCount: 1,
      tableCount: tableCount,
      viewCount: viewCount,
      approxRows: approxRows,
      topTables: metrics.take(_topN).toList(),
    );
  }
}
