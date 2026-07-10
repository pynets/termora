import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:termora/features/database/domain/db_models.dart';
import 'package:termora/core/l10n/app_l10n.dart';

/// ClickHouse 错误(HTTP 返回非 200 时的服务端文本)
class ClickHouseException implements Exception {
  ClickHouseException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// ClickHouse 访问封装(HTTP 接口,和 DBeaver 的 JDBC 驱动一致走 8123)。
/// 只读:浏览库/表、分页看数据、表结构、SQL 查询、排序、过滤。
class ClickHouseService {
  ClickHouseService._();

  static const pageSize = 200;

  /// 系统库(导航树中隐藏)
  static const _systemSchemas = {
    'system',
    'INFORMATION_SCHEMA',
    'information_schema',
  };

  // ══════════════ HTTP 底层 ══════════════

  /// 发送一条 SQL,以 JSONCompact 解析(SELECT 类)。无结果集的语句返回空。
  static Future<_ChResult> _query(
    DbConnectionConfig config,
    String sql, {
    Map<String, String> params = const {},
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final scheme = config.useSsl ? 'https' : 'http';
    final uri = Uri.parse('$scheme://${config.host}:${config.port}/').replace(
      queryParameters: {
        if (config.database.isNotEmpty) 'database': config.database,
        'default_format': 'JSONCompact',
        for (final e in params.entries) 'param_${e.key}': e.value,
      },
    );

    final http.Response resp;
    try {
      resp = await http
          .post(
            uri,
            headers: {
              'X-ClickHouse-User': config.username,
              if (config.password.isNotEmpty)
                'X-ClickHouse-Key': config.password,
              'Content-Type': 'text/plain; charset=UTF-8',
            },
            body: sql,
          )
          .timeout(timeout);
    } catch (e) {
      throw ClickHouseException(tr2('无法连接到 {0}:{1} — {2}', [config.host, config.port, e]));
    }

    final body = utf8.decode(resp.bodyBytes);
    if (resp.statusCode != 200) {
      throw ClickHouseException(_trimError(body));
    }
    if (body.trim().isEmpty) {
      return const _ChResult(columns: [], rows: [], elapsed: Duration.zero);
    }
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      final meta = (json['meta'] as List<dynamic>? ?? [])
          .map((m) => (m as Map<String, dynamic>)['name'] as String)
          .toList();
      final data = (json['data'] as List<dynamic>? ?? [])
          .map((r) => List<Object?>.from(r as List))
          .toList();
      final elapsedSec =
          ((json['statistics'] as Map<String, dynamic>?)?['elapsed'] as num?)
              ?.toDouble() ??
          0;
      return _ChResult(
        columns: meta,
        rows: data,
        elapsed: Duration(microseconds: (elapsedSec * 1e6).round()),
      );
    } catch (_) {
      // 非 JSON(例如 DDL 成功返回空文本)
      return const _ChResult(columns: [], rows: [], elapsed: Duration.zero);
    }
  }

  static String _trimError(String body) {
    final line = body.trim().split('\n').first;
    // ClickHouse 错误形如 "Code: 62. DB::Exception: ..."
    return line.length > 300 ? '${line.substring(0, 300)}…' : line;
  }

  /// 标识符转义(反引号)
  static String _ident(String name) => '`${name.replaceAll('`', r'\`')}`';

  static String _qualified(String schema, String table) =>
      '${_ident(schema)}.${_ident(table)}';

  // ══════════════ 只读接口 ══════════════

  /// 打开连接:HTTP 无长连接,做一次探活确保可达
  static Future<void> ping(DbConnectionConfig config) async {
    await _query(config, 'SELECT 1', timeout: const Duration(seconds: 8));
  }

  static Future<String> testConnection(DbConnectionConfig config) async {
    final result = await _query(config, 'SELECT version()');
    return result.rows.isEmpty ? 'unknown' : '${result.rows.first.first}';
  }

  static Future<String?> serverVersion(DbConnectionConfig config) async {
    try {
      final result = await _query(config, 'SELECT version()');
      return result.rows.isEmpty ? null : '${result.rows.first.first}';
    } catch (_) {
      return null;
    }
  }

  static Future<List<String>> listSchemas(DbConnectionConfig config) async {
    final result = await _query(
      config,
      'SELECT name FROM system.databases ORDER BY name',
    );
    return [
      for (final row in result.rows)
        if (!_systemSchemas.contains(row.first)) row.first as String,
    ];
  }

  static Future<List<DbTableInfo>> listTables(
    DbConnectionConfig config,
    String schema,
  ) async {
    final result = await _query(
      config,
      'SELECT name, engine FROM system.tables '
      'WHERE database = {schema:String} ORDER BY name',
      params: {'schema': schema},
    );
    return [
      for (final row in result.rows)
        DbTableInfo(
          name: row[0] as String,
          isView: (row[1] as String? ?? '').contains('View'),
        ),
    ];
  }

  /// 表列名(全行过滤时用)
  static Future<List<String>> _columnNames(
    DbConnectionConfig config,
    String schema,
    String table,
  ) async {
    final result = await _query(
      config,
      'SELECT name FROM system.columns '
      'WHERE database = {s:String} AND table = {t:String} ORDER BY position',
      params: {'s': schema, 't': table},
    );
    return [for (final row in result.rows) row.first as String];
  }

  /// 合成 WHERE + 参数(全行过滤 + 列过滤,统一用 toString 文本语义)
  static Future<(String, Map<String, String>)> _buildWhere(
    DbConnectionConfig config,
    String schema,
    String table,
    String filter,
    List<DbColumnFilter> columnFilters,
  ) async {
    final clauses = <String>[];
    final params = <String, String>{};

    if (filter.isNotEmpty) {
      final cols = await _columnNames(config, schema, table);
      if (cols.isNotEmpty) {
        params['q'] = '%$filter%';
        final ors = [
          for (final c in cols) 'toString(${_ident(c)}) ILIKE {q:String}',
        ];
        clauses.add('(${ors.join(' OR ')})');
      }
    }

    for (var i = 0; i < columnFilters.length; i++) {
      final (frag, p) = _columnFragment(columnFilters[i], 'cf$i');
      clauses.add('($frag)');
      params.addAll(p);
    }

    final where = clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')} ';
    return (where, params);
  }

  /// 列过滤片段(ClickHouse 语法,值统一 toString 文本比较)
  static (String, Map<String, String>) _columnFragment(
    DbColumnFilter f,
    String pname,
  ) {
    final col = 'toString(${_ident(f.column)})';
    final raw = _ident(f.column);
    switch (f.op) {
      case DbFilterOp.isNull:
        return ('$raw IS NULL', const {});
      case DbFilterOp.isNotNull:
        return ('$raw IS NOT NULL', const {});
      case DbFilterOp.like:
        return ('$col ILIKE {$pname:String}', {pname: '%${f.value}%'});
      case DbFilterOp.inList:
        final items = f.value
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
        if (items.isEmpty) return ('1', const {});
        final placeholders = <String>[];
        final params = <String, String>{};
        for (var i = 0; i < items.length; i++) {
          placeholders.add('{$pname$i:String}');
          params['$pname$i'] = items[i];
        }
        return ('$col IN (${placeholders.join(', ')})', params);
      case DbFilterOp.equals:
        return ('$col = {$pname:String}', {pname: f.value});
      case DbFilterOp.notEquals:
        return ('$col != {$pname:String}', {pname: f.value});
      case DbFilterOp.greater:
        return ('$col > {$pname:String}', {pname: f.value});
      case DbFilterOp.less:
        return ('$col < {$pname:String}', {pname: f.value});
      case DbFilterOp.greaterEqual:
        return ('$col >= {$pname:String}', {pname: f.value});
      case DbFilterOp.lessEqual:
        return ('$col <= {$pname:String}', {pname: f.value});
    }
  }

  static Future<(DbQueryOutput, bool, DbEditContext?)> fetchTableData(
    DbConnectionConfig config,
    String schema,
    String table, {
    int page = 0,
    String? orderBy,
    bool ascending = true,
    String filter = '',
    List<DbColumnFilter> columnFilters = const [],
  }) async {
    final (where, params) = await _buildWhere(
      config,
      schema,
      table,
      filter,
      columnFilters,
    );
    final order = orderBy == null
        ? ''
        : 'ORDER BY ${_ident(orderBy)} ${ascending ? 'ASC' : 'DESC'} ';
    final sql =
        'SELECT * FROM ${_qualified(schema, table)} '
        '$where$order'
        'LIMIT ${pageSize + 1} OFFSET ${page * pageSize}';
    final result = await _query(config, sql, params: params);

    final hasMore = result.rows.length > pageSize;
    final rows = hasMore ? result.rows.sublist(0, pageSize) : result.rows;
    return (
      DbQueryOutput(
        columns: result.columns,
        rows: rows,
        affectedRows: rows.length,
        elapsed: result.elapsed,
      ),
      hasMore,
      null, // ClickHouse 只读,无编辑上下文
    );
  }

  static Future<int> countRows(
    DbConnectionConfig config,
    String schema,
    String table, {
    String filter = '',
    List<DbColumnFilter> columnFilters = const [],
  }) async {
    final (where, params) = await _buildWhere(
      config,
      schema,
      table,
      filter,
      columnFilters,
    );
    final result = await _query(
      config,
      'SELECT count() FROM ${_qualified(schema, table)} $where',
      params: params,
    );
    return result.rows.isEmpty
        ? 0
        : int.tryParse('${result.rows.first.first}') ?? 0;
  }

  static Future<DbTableStructure> fetchTableStructure(
    DbConnectionConfig config,
    String schema,
    String table,
  ) async {
    final columnsResult = await _query(
      config,
      'SELECT name, type, default_expression, comment, is_in_primary_key '
      'FROM system.columns '
      'WHERE database = {s:String} AND table = {t:String} ORDER BY position',
      params: {'s': schema, 't': table},
    );

    final metaResult = await _query(
      config,
      'SELECT sum(rows), sum(bytes_on_disk) FROM system.parts '
      'WHERE database = {s:String} AND table = {t:String} AND active',
      params: {'s': schema, 't': table},
    );
    final tableResult = await _query(
      config,
      'SELECT comment, sorting_key FROM system.tables '
      'WHERE database = {s:String} AND table = {t:String}',
      params: {'s': schema, 't': table},
    );

    final meta = metaResult.rows.isEmpty ? null : metaResult.rows.first;
    final tableRow = tableResult.rows.isEmpty ? null : tableResult.rows.first;
    final sortingKey = tableRow == null ? '' : '${tableRow[1] ?? ''}';

    return DbTableStructure(
      columns: [
        for (final row in columnsResult.rows)
          DbColumnInfo(
            name: row[0] as String,
            dataType: row[1] as String,
            nullable: (row[1] as String).startsWith('Nullable('),
            defaultValue: (row[2] as String?)?.isEmpty ?? true
                ? null
                : row[2] as String,
            isPrimaryKey: '${row[4]}' == '1',
            comment: (row[3] as String?)?.isEmpty ?? true
                ? null
                : row[3] as String,
          ),
      ],
      indexes: [
        if (sortingKey.isNotEmpty)
          DbIndexInfo(name: 'ORDER BY', definition: sortingKey),
      ],
      approxRows: meta == null
          ? 0
          : int.tryParse('${meta[0] ?? 0}') ?? 0,
      totalBytes: meta == null ? 0 : int.tryParse('${meta[1] ?? 0}') ?? 0,
      comment: tableRow == null || '${tableRow[0] ?? ''}'.isEmpty
          ? null
          : '${tableRow[0]}',
    );
  }

  static Future<(DbQueryOutput, DbEditContext?)> runSql(
    DbConnectionConfig config,
    String sql,
  ) async {
    final result = await _query(
      config,
      sql.trim(),
      timeout: const Duration(seconds: 60),
    );
    return (
      DbQueryOutput(
        columns: result.columns,
        rows: result.rows,
        affectedRows: result.rows.length,
        elapsed: result.elapsed,
      ),
      null,
    );
  }
}

/// ClickHouse 查询解析结果
class _ChResult {
  const _ChResult({
    required this.columns,
    required this.rows,
    required this.elapsed,
  });
  final List<String> columns;
  final List<List<Object?>> rows;
  final Duration elapsed;
}
