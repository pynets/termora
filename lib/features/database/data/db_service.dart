import 'package:postgres/postgres.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:termora/features/database/data/clickhouse_service.dart';
import 'package:termora/features/database/data/postgres_service.dart';
import 'package:termora/features/database/data/sqlite_service.dart';
import 'package:termora/features/database/domain/db_models.dart';

/// 统一连接句柄 — 屏蔽底层驱动差异
/// (postgres 长连接 / clickhouse 无状态 HTTP / sqlite 本地文件句柄)
sealed class DbConnection {
  DbEngine get engine;
  Future<void> close();
}

class PgConnection extends DbConnection {
  PgConnection(this.raw);
  final Connection raw;
  @override
  DbEngine get engine => DbEngine.postgres;
  @override
  Future<void> close() => raw.close();
}

class ChConnection extends DbConnection {
  ChConnection(this.config);
  final DbConnectionConfig config;
  @override
  DbEngine get engine => DbEngine.clickhouse;
  @override
  Future<void> close() async {} // HTTP 无长连接
}

class SqliteConnection extends DbConnection {
  SqliteConnection(this.raw);
  final sqlite.Database raw;
  @override
  DbEngine get engine => DbEngine.sqlite;
  @override
  Future<void> close() async => raw.close();
}

/// 数据库驱动门面 — 按引擎把调用分发到对应 service。
/// providers 只依赖这一层,不直接碰具体驱动。
class DbService {
  DbService._();

  static Future<DbConnection> open(DbConnectionConfig config) async {
    switch (config.engine) {
      case DbEngine.postgres:
        return PgConnection(await PostgresService.open(config));
      case DbEngine.clickhouse:
        await ClickHouseService.ping(config);
        return ChConnection(config);
      case DbEngine.sqlite:
        return SqliteConnection(await SqliteService.open(config));
    }
  }

  static Future<String> testConnection(DbConnectionConfig config) {
    return switch (config.engine) {
      DbEngine.postgres => PostgresService.testConnection(config),
      DbEngine.clickhouse => ClickHouseService.testConnection(config),
      DbEngine.sqlite => SqliteService.testConnection(config),
    };
  }

  static Future<String?> serverVersion(DbConnection c) {
    return switch (c) {
      PgConnection p => PostgresService.serverVersion(p.raw),
      ChConnection ch => ClickHouseService.serverVersion(ch.config),
      SqliteConnection s => SqliteService.serverVersion(s.raw),
    };
  }

  static Future<List<String>> listSchemas(DbConnection c) {
    return switch (c) {
      PgConnection p => PostgresService.listSchemas(p.raw),
      ChConnection ch => ClickHouseService.listSchemas(ch.config),
      SqliteConnection s => SqliteService.listSchemas(s.raw),
    };
  }

  static Future<List<DbTableInfo>> listTables(DbConnection c, String schema) {
    return switch (c) {
      PgConnection p => PostgresService.listTables(p.raw, schema),
      ChConnection ch => ClickHouseService.listTables(ch.config, schema),
      SqliteConnection s => SqliteService.listTables(s.raw, schema),
    };
  }

  static Future<(DbQueryOutput, bool, DbEditContext?)> fetchTableData(
    DbConnection c,
    String schema,
    String table, {
    int page = 0,
    String? orderBy,
    bool ascending = true,
    String filter = '',
    List<DbColumnFilter> columnFilters = const [],
  }) {
    return switch (c) {
      PgConnection p => PostgresService.fetchTableData(
        p.raw,
        schema,
        table,
        page: page,
        orderBy: orderBy,
        ascending: ascending,
        filter: filter,
        columnFilters: columnFilters,
      ),
      ChConnection ch => ClickHouseService.fetchTableData(
        ch.config,
        schema,
        table,
        page: page,
        orderBy: orderBy,
        ascending: ascending,
        filter: filter,
        columnFilters: columnFilters,
      ),
      SqliteConnection s => SqliteService.fetchTableData(
        s.raw,
        schema,
        table,
        page: page,
        orderBy: orderBy,
        ascending: ascending,
        filter: filter,
        columnFilters: columnFilters,
      ),
    };
  }

  static Future<int> countRows(
    DbConnection c,
    String schema,
    String table, {
    String filter = '',
    List<DbColumnFilter> columnFilters = const [],
  }) {
    return switch (c) {
      PgConnection p => PostgresService.countRows(
        p.raw,
        schema,
        table,
        filter: filter,
        columnFilters: columnFilters,
      ),
      ChConnection ch => ClickHouseService.countRows(
        ch.config,
        schema,
        table,
        filter: filter,
        columnFilters: columnFilters,
      ),
      SqliteConnection s => SqliteService.countRows(
        s.raw,
        schema,
        table,
        filter: filter,
        columnFilters: columnFilters,
      ),
    };
  }

  static Future<DbTableStructure> fetchTableStructure(
    DbConnection c,
    String schema,
    String table,
  ) {
    return switch (c) {
      PgConnection p =>
        PostgresService.fetchTableStructure(p.raw, schema, table),
      ChConnection ch =>
        ClickHouseService.fetchTableStructure(ch.config, schema, table),
      SqliteConnection s =>
        SqliteService.fetchTableStructure(s.raw, schema, table),
    };
  }

  static Future<(DbQueryOutput, DbEditContext?)> runSql(
    DbConnection c,
    String sql,
  ) {
    return switch (c) {
      PgConnection p => PostgresService.runSql(p.raw, sql),
      ChConnection ch => ClickHouseService.runSql(ch.config, sql),
      SqliteConnection s => SqliteService.runSql(s.raw, sql),
    };
  }

  /// 批量提交编辑(postgres / sqlite 支持;clickhouse 只读)
  static Future<int> applyChanges(
    DbConnection c, {
    required DbEditContext context,
    required DbQueryOutput output,
    required DbEditSession session,
  }) {
    return switch (c) {
      PgConnection p => PostgresService.applyChanges(
        p.raw,
        context: context,
        output: output,
        session: session,
      ),
      ChConnection _ => throw UnsupportedError('ClickHouse 连接为只读,不支持编辑'),
      SqliteConnection s => SqliteService.applyChanges(
        s.raw,
        context: context,
        output: output,
        session: session,
      ),
    };
  }
}
