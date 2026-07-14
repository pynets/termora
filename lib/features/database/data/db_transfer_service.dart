import 'dart:io';

import 'package:termora/features/database/data/db_service.dart';
import 'package:termora/features/database/data/postgres_service.dart';
import 'package:termora/features/database/domain/db_etl.dart';
import 'package:termora/features/database/domain/db_migration.dart';
import 'package:termora/features/database/domain/db_models.dart';
import 'package:termora/features/database/domain/db_transfer_task.dart';

/// 传输进度(导出/导入/迁移共用):[done]/[total] 是表级进度,
/// [message] 是追加到日志区的一行文本。
class DbTransferProgress {
  const DbTransferProgress({
    required this.message,
    this.done = 0,
    this.total = 0,
  });

  final String message;
  final int done;
  final int total;
}

typedef DbTransferOnProgress = void Function(DbTransferProgress progress);
typedef DbTransferCancelled = bool Function();

/// 用户取消(区别于失败,UI 不当错误渲染)
class DbTransferCancelledException implements Exception {
  @override
  String toString() => 'cancelled';
}

/// 迁移/导入结果摘要
class DbTransferSummary {
  const DbTransferSummary({
    this.tables = 0,
    this.rows = 0,
    this.statements = 0,
  });

  final int tables;
  final int rows;
  final int statements;
}

/// 数据库导出 / 导入 / 迁移编排。
/// 与会话层解耦:按配置自行开关连接,不影响页面上的活动会话。
class DbTransferService {
  DbTransferService._();

  /// 单条 INSERT 携带的行数(源分页 200 行,攒 batchPages 页发一条)
  static const rowsPerInsert = 200;

  static void _check(DbTransferCancelled? isCancelled) {
    if (isCancelled != null && isCancelled()) {
      throw DbTransferCancelledException();
    }
  }

  /// 解析待传输的 (schema, table) 目标列表。优先级:
  /// [wholeDatabase](所有非系统 schema 全部表,跳过视图)
  ///   > [schemaTables](多 schema;某 schema 的值为空 = 该 schema 全部表)
  ///   > [schema] 下选中的 [tables]。
  static Future<List<({String schema, String table})>> _resolveTargets(
    DbConnection conn, {
    String? schema,
    List<String> tables = const [],
    Map<String, List<String>> schemaTables = const {},
    bool wholeDatabase = false,
  }) async {
    final targets = <({String schema, String table})>[];
    Future<List<String>> allTables(String s) async => [
      for (final info in await DbService.listTables(conn, s))
        if (!info.isView && !_isExtensionTable(s, info.name)) info.name,
    ];

    if (wholeDatabase) {
      for (final s in await DbService.listSchemas(conn)) {
        for (final t in await allTables(s)) {
          targets.add((schema: s, table: t));
        }
      }
    } else if (schemaTables.isNotEmpty) {
      for (final entry in schemaTables.entries) {
        final tabs = entry.value.isEmpty
            ? await allTables(entry.key)
            : entry.value;
        for (final t in tabs) {
          targets.add((schema: entry.key, table: t));
        }
      }
    } else if (schema != null) {
      for (final t in tables) {
        targets.add((schema: schema, table: t));
      }
    }
    return targets;
  }

  // ══════════════ 导出 ══════════════

  /// 把源库导出为 SQL 脚本(结构 + 数据),语法按 [targetEngine] 生成 —
  /// 同引擎还原度最高,跨引擎走类型映射。
  /// [wholeDatabase] 为整库(所有 schema);否则导出 [schema] 下的 [tables]。
  /// 整库且目标支持 schema(pg/ch)时保留源 schema(CREATE SCHEMA + 限定名)。
  /// [etlRules] 按源表名给出 ETL 规则(行过滤/列裁剪改名/值转换)。
  static Future<DbTransferSummary> exportToScript({
    required DbConnectionConfig source,
    String? schema,
    List<String> tables = const [],
    Map<String, List<String>> schemaTables = const {},
    bool wholeDatabase = false,
    required DbEngine targetEngine,
    required String filePath,
    bool includeDrop = true,
    bool includeData = true,
    Map<String, DbEtlTableRule> etlRules = const {},
    DbTransferOnProgress? onProgress,
    DbTransferCancelled? isCancelled,
  }) async {
    final conn = await DbService.open(source);
    IOSink? sink;
    try {
      final targets = await _resolveTargets(
        conn,
        schema: schema,
        tables: tables,
        schemaTables: schemaTables,
        wholeDatabase: wholeDatabase,
      );
      // 跨多个 schema 时必须保留 schema(限定名),否则同名表会互相覆盖;
      // 单 schema 落到目标默认库/schema。目标为 SQLite 无 schema 概念。
      final preserveSchema =
          {for (final t in targets) t.schema}.length > 1 &&
          targetEngine != DbEngine.sqlite;
      final createdSchemas = <String>{};
      var postgisWritten = false;

      sink = File(filePath).openWrite();
      sink.writeln('-- Termora export');
      sink.writeln(
        '-- source: ${source.engine.label} '
        '${wholeDatabase ? '(整库)' : schema}',
      );
      sink.writeln('-- dialect: ${targetEngine.label}');
      sink.writeln();

      var totalRows = 0;
      for (var i = 0; i < targets.length; i++) {
        final (schema: srcSchema, table: table) = targets[i];
        _check(isCancelled);
        onProgress?.call(
          DbTransferProgress(
            message: '$srcSchema.$table',
            done: i,
            total: targets.length,
          ),
        );

        final targetSchema = preserveSchema ? srcSchema : null;
        if (preserveSchema && createdSchemas.add(srcSchema)) {
          final ddl = DbMigration.buildCreateSchema(targetEngine, srcSchema);
          if (ddl != null) sink.writeln('$ddl;');
        }

        final rule = etlRules[table];
        final targetTable = rule?.targetTableName ?? table;
        final structure = await DbService.fetchTableStructure(
          conn,
          srcSchema,
          table,
        );
        var columns = [
          for (final c in structure.columns)
            DbMigrationColumn.from(source.engine, c),
        ];
        if (rule != null) {
          columns = rule.applyToColumns(source.engine, columns);
        }
        // PostGIS 列:导入端需要 postgis 扩展,脚本里带上(一次)
        if (targetEngine == DbEngine.postgres &&
            !postgisWritten &&
            columns.any(
              (c) => DbMigration.isGeoType(
                DbMigration.targetColumnType(source.engine, targetEngine, c),
              ),
            )) {
          postgisWritten = true;
          sink.writeln('CREATE EXTENSION IF NOT EXISTS postgis;');
        }
        for (final statement in DbMigration.buildCreateTable(
          source.engine,
          targetEngine,
          targetTable,
          columns,
          drop: includeDrop,
          schema: targetSchema,
        )) {
          sink.writeln('$statement;');
        }
        sink.writeln();

        if (includeData) {
          final typeByName = _targetTypesByName(
            source.engine,
            targetEngine,
            columns,
          );
          totalRows += await _forEachBatch(
            conn,
            srcSchema,
            table,
            rule?.rowFilters ?? const [],
            isCancelled,
            (columnNames, rows) async {
              final (outColumns, outRows) = rule == null
                  ? (columnNames, rows)
                  : rule.applyToBatch(columnNames, rows);
              sink!.writeln(
                '${DbMigration.buildInsert(targetEngine, targetTable, outColumns, outRows, schema: targetSchema, columnTypes: [
                  for (final c in outColumns) typeByName[c] ?? '',
                ])};',
              );
            },
          );
          sink.writeln();
        }
      }
      await sink.flush();
      onProgress?.call(
        DbTransferProgress(
          message: '✓ $totalRows rows',
          done: targets.length,
          total: targets.length,
        ),
      );
      return DbTransferSummary(tables: targets.length, rows: totalRows);
    } finally {
      await sink?.close();
      await conn.close();
    }
  }

  // ══════════════ 导入 ══════════════

  /// 在 [target] 连接上逐条执行 SQL 脚本。
  /// 语句拆分复用 postgres 的通用拆分器(正确跳过字符串/注释里的分号);
  /// 逐条执行也顺带绕开 ClickHouse HTTP 不支持多语句的限制。
  static Future<DbTransferSummary> importScript({
    required DbConnectionConfig target,
    required String script,
    DbTransferOnProgress? onProgress,
    DbTransferCancelled? isCancelled,
  }) async {
    final statements = PostgresService.splitStatements(script);
    if (statements.isEmpty) return const DbTransferSummary();

    final conn = await DbService.open(target);
    try {
      for (var i = 0; i < statements.length; i++) {
        _check(isCancelled);
        final statement = statements[i];
        try {
          await DbService.runSql(conn, statement);
        } catch (e) {
          final preview = statement.length > 120
              ? '${statement.substring(0, 120)}…'
              : statement;
          throw StateError('#${i + 1}: $e\n$preview');
        }
        if ((i + 1) % 20 == 0 || i == statements.length - 1) {
          onProgress?.call(
            DbTransferProgress(
              message: '${i + 1}/${statements.length}',
              done: i + 1,
              total: statements.length,
            ),
          );
        }
      }
      return DbTransferSummary(statements: statements.length);
    } finally {
      await conn.close();
    }
  }

  // ══════════════ 迁移 ══════════════

  /// 把源连接迁移到目标连接。
  /// [wholeDatabase] 为整库(所有 schema);否则迁移 [schema] 下的 [tables]。
  /// 整库且目标支持 schema(pg/ch)时保留源 schema(建 schema + 限定名);
  /// 否则落到目标默认库/schema。
  /// [overwrite] 时先 DROP TABLE IF EXISTS 再建表(覆盖目标同名表)。
  /// [etlRules] 按源表名给出 ETL 规则(行过滤/列裁剪改名/值转换)。
  /// 跨引擎不可能有分布式事务:失败即中断,日志里能看到已完成的表。
  static Future<DbTransferSummary> migrate({
    required DbConnectionConfig source,
    required DbConnectionConfig target,
    String? schema,
    List<String> tables = const [],
    Map<String, List<String>> schemaTables = const {},
    bool wholeDatabase = false,
    bool overwrite = true,
    bool copyData = true,
    Map<String, DbEtlTableRule> etlRules = const {},
    DbTransferOnProgress? onProgress,
    DbTransferCancelled? isCancelled,
  }) async {
    final sourceConn = await DbService.open(source);
    final DbConnection targetConn;
    try {
      targetConn = await DbService.open(target);
    } catch (e) {
      await sourceConn.close();
      rethrow;
    }

    try {
      final targets = await _resolveTargets(
        sourceConn,
        schema: schema,
        tables: tables,
        schemaTables: schemaTables,
        wholeDatabase: wholeDatabase,
      );
      // 跨多个 schema 时必须保留 schema(限定名),否则同名表会互相覆盖。
      final preserveSchema =
          {for (final t in targets) t.schema}.length > 1 &&
          target.engine != DbEngine.sqlite;
      final createdSchemas = <String>{};
      var postgisEnsured = false;

      var totalRows = 0;
      for (var i = 0; i < targets.length; i++) {
        final (schema: srcSchema, table: table) = targets[i];
        _check(isCancelled);
        onProgress?.call(
          DbTransferProgress(
            message: '$srcSchema.$table',
            done: i,
            total: targets.length,
          ),
        );

        final targetSchema = preserveSchema ? srcSchema : null;
        if (preserveSchema && createdSchemas.add(srcSchema)) {
          final ddl = DbMigration.buildCreateSchema(target.engine, srcSchema);
          if (ddl != null) await DbService.runSql(targetConn, ddl);
        }

        // 1. 目标端建表(覆盖式先 DROP;应用 ETL 的列裁剪/改名/类型强转)
        final rule = etlRules[table];
        final targetTable = rule?.targetTableName ?? table;
        final structure = await DbService.fetchTableStructure(
          sourceConn,
          srcSchema,
          table,
        );
        var columns = [
          for (final c in structure.columns)
            DbMigrationColumn.from(source.engine, c),
        ];
        if (rule != null) {
          columns = rule.applyToColumns(source.engine, columns);
        }
        // PostGIS 列需要目标端有 postgis 扩展(best-effort,失败交给建表报错)
        if (target.engine == DbEngine.postgres &&
            !postgisEnsured &&
            columns.any(
              (c) => DbMigration.isGeoType(
                DbMigration.targetColumnType(source.engine, target.engine, c),
              ),
            )) {
          postgisEnsured = true;
          try {
            await DbService.runSql(
              targetConn,
              'CREATE EXTENSION IF NOT EXISTS postgis',
            );
          } catch (e) {
            // 不中断(可能扩展已可用/权限不足);写日志提示,建表若失败错误自会浮出
            onProgress?.call(
              DbTransferProgress(
                message: '! CREATE EXTENSION postgis: $e',
                done: i,
                total: targets.length,
              ),
            );
          }
        }
        for (final statement in DbMigration.buildCreateTable(
          source.engine,
          target.engine,
          targetTable,
          columns,
          drop: overwrite,
          schema: targetSchema,
        )) {
          await DbService.runSql(targetConn, statement);
        }

        // 2. 分页拷贝数据(行过滤推给源库,值转换在批内应用)
        if (copyData) {
          final typeByName = _targetTypesByName(
            source.engine,
            target.engine,
            columns,
          );
          var tableRows = 0;
          await _forEachBatch(
            sourceConn,
            srcSchema,
            table,
            rule?.rowFilters ?? const [],
            isCancelled,
            (columnNames, rows) async {
              final (outColumns, outRows) = rule == null
                  ? (columnNames, rows)
                  : rule.applyToBatch(columnNames, rows);
              await DbService.runSql(
                targetConn,
                DbMigration.buildInsert(
                  target.engine,
                  targetTable,
                  outColumns,
                  outRows,
                  schema: targetSchema,
                  columnTypes: [
                    for (final c in outColumns) typeByName[c] ?? '',
                  ],
                ),
              );
              tableRows += rows.length;
              onProgress?.call(
                DbTransferProgress(
                  message: '  $srcSchema.$table: $tableRows',
                  done: i,
                  total: targets.length,
                ),
              );
            },
          );
          totalRows += tableRows;
        }
      }
      onProgress?.call(
        DbTransferProgress(
          message: '✓ $totalRows rows',
          done: targets.length,
          total: targets.length,
        ),
      );
      return DbTransferSummary(tables: targets.length, rows: totalRows);
    } finally {
      await targetConn.close();
      await sourceConn.close();
    }
  }

  // ══════════════ 保存的任务 ══════════════

  /// 执行一个已保存的任务(任务列表一键重跑 / 定时调度共用)。
  /// 连接由调用方按 id 解析后传入([source]:export/migrate 的源,也是 import
  /// 脚本执行的目标;[target]:migrate 的目标)。
  /// 导出路径支持 `{ts}` 占位符 → 运行时替换为时间戳(备份不互相覆盖)。
  static Future<DbTransferSummary> runTask(
    DbTransferTask task, {
    required DbConnectionConfig source,
    DbConnectionConfig? target,
    DbTransferOnProgress? onProgress,
    DbTransferCancelled? isCancelled,
  }) async {
    switch (task.mode) {
      case DbTransferMode.export:
        final path = _expandPath(task.filePath ?? '${task.name}.sql');
        return exportToScript(
          source: source,
          schema: task.wholeDatabase ? null : task.schema,
          tables: task.wholeDatabase ? const [] : task.tables,
          schemaTables: task.wholeDatabase ? const {} : task.schemaTables,
          wholeDatabase: task.wholeDatabase,
          targetEngine: task.exportDialect ?? source.engine,
          filePath: path,
          includeDrop: task.overwrite,
          includeData: task.includeData,
          etlRules: task.etlRules,
          onProgress: onProgress,
          isCancelled: isCancelled,
        );
      case DbTransferMode.importScript:
        final script = await File(task.filePath!).readAsString();
        return importScript(
          target: source,
          script: script,
          onProgress: onProgress,
          isCancelled: isCancelled,
        );
      case DbTransferMode.migrate:
        if (target == null) throw StateError('迁移任务缺少目标连接');
        return migrate(
          source: source,
          target: target,
          schema: task.wholeDatabase ? null : task.schema,
          tables: task.wholeDatabase ? const [] : task.tables,
          schemaTables: task.wholeDatabase ? const {} : task.schemaTables,
          wholeDatabase: task.wholeDatabase,
          overwrite: task.overwrite,
          copyData: task.includeData,
          etlRules: task.etlRules,
          onProgress: onProgress,
          isCancelled: isCancelled,
        );
    }
  }

  /// 展开导出路径里的 `{ts}` 占位符为 yyyyMMdd-HHmmss 时间戳
  static String _expandPath(String path) {
    if (!path.contains('{ts}')) return path;
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final ts =
        '${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    return path.replaceAll('{ts}', ts);
  }

  /// 扩展自带的系统表(整库/整 schema 枚举时跳过;显式点名选中的不拦)。
  /// 迁走它们会和目标端 CREATE EXTENSION 冲突——如 PostGIS 的 spatial_ref_sys
  /// 被当普通表搬过去后,目标端装 postgis 时建表撞名而失败。
  static bool _isExtensionTable(String schema, String table) =>
      table == 'spatial_ref_sys' ||
      (schema == 'topology' && (table == 'topology' || table == 'layer'));

  /// 目标列名 → 目标列类型(INSERT 字面量需要类型感知,如 pg 数组列)
  static Map<String, String> _targetTypesByName(
    DbEngine sourceEngine,
    DbEngine targetEngine,
    List<DbMigrationColumn> columns,
  ) => {
    for (final c in columns)
      c.name: DbMigration.targetColumnType(sourceEngine, targetEngine, c),
  };

  /// 按页遍历表数据,每攒够 [rowsPerInsert] 行回调一批;返回总行数。
  /// [rowFilters] 为 ETL 行过滤,由各引擎 service 转成对应 WHERE 下推执行。
  static Future<int> _forEachBatch(
    DbConnection conn,
    String schema,
    String table,
    List<DbColumnFilter> rowFilters,
    DbTransferCancelled? isCancelled,
    Future<void> Function(List<String> columns, List<List<Object?>> rows)
    emit,
  ) async {
    var page = 0;
    var total = 0;
    List<String>? columnNames;
    final buffer = <List<Object?>>[];

    for (;;) {
      _check(isCancelled);
      final (output, hasMore, _) = await DbService.fetchTableData(
        conn,
        schema,
        table,
        page: page,
        columnFilters: rowFilters,
      );
      columnNames ??= output.columns;
      buffer.addAll(output.rows);
      total += output.rows.length;

      while (buffer.length >= rowsPerInsert) {
        final batch = buffer.sublist(0, rowsPerInsert);
        buffer.removeRange(0, rowsPerInsert);
        await emit(columnNames, batch);
      }
      if (!hasMore) break;
      page++;
    }
    if (buffer.isNotEmpty) {
      await emit(columnNames, buffer);
    }
    return total;
  }
}
