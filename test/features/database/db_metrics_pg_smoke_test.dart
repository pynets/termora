@Tags(['smoke'])
library;

// DbMetricsService(PostgreSQL)冒烟 — 需要本地 55432 临时 PG:
//   flutter test --run-skipped --tags smoke test/features/database/db_metrics_pg_smoke_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:termora/features/database/data/db_service.dart';
import 'package:termora/features/database/data/db_metrics_service.dart';
import 'package:termora/features/database/domain/db_models.dart';

const _pg = DbConnectionConfig(
  id: 'pgm',
  name: 'pgm',
  host: 'localhost',
  port: 55432,
  database: 'postgres',
  username: 'postgres',
  password: '',
);

void main() {
  test('pg 指标:大小/计数/topTables/连接/缓存/uptime', () async {
    final conn = await DbService.open(_pg);
    try {
      await DbService.runSql(conn, 'DROP TABLE IF EXISTS metric_big');
      await DbService.runSql(
        conn,
        'CREATE TABLE metric_big (id bigint PRIMARY KEY, v text)',
      );
      await DbService.runSql(
        conn,
        "INSERT INTO metric_big SELECT i, repeat('x', 200) "
        'FROM generate_series(1, 2000) i',
      );
      await DbService.runSql(conn, 'ANALYZE metric_big');
    } finally {
      await conn.close();
    }

    final m = await DbMetricsService.load(_pg);

    expect(m.engine, DbEngine.postgres);
    expect(m.version, isNotEmpty);
    expect(m.databaseBytes, greaterThan(0));
    expect(m.tableCount, greaterThanOrEqualTo(1));
    expect(m.approxRows, greaterThanOrEqualTo(2000));

    // metric_big 应出现在 topTables,且体量、行数被采到
    final big = m.topTables.where((t) => t.table == 'metric_big').toList();
    expect(big, isNotEmpty);
    expect(big.first.bytes, greaterThan(0));
    expect(big.first.rows, greaterThanOrEqualTo(2000));

    // pg 专属指标拿得到
    expect(m.activeConnections, isNotNull);
    expect(m.maxConnections, greaterThan(0));
    expect(m.cacheHitRatio, isNotNull);
    expect(m.cacheHitRatio!, inInclusiveRange(0, 1));
    expect(m.uptime, isNotNull);
    expect(m.uptime!.inSeconds, greaterThanOrEqualTo(0));

    // schema 分布(public)
    expect(m.schemas.any((s) => s.schema == 'public'), isTrue);

    final cleanup = await DbService.open(_pg);
    try {
      await DbService.runSql(cleanup, 'DROP TABLE IF EXISTS metric_big');
    } finally {
      await cleanup.close();
    }
  });
}
