import 'dart:io';
import 'package:postgres/postgres.dart';
import 'package:termora/features/database/domain/db_models.dart';

/// PostgreSQL 访问封装(基于 package:postgres v3)
/// 元数据查询参考 DBeaver postgresql 插件的做法:走 pg_catalog / information_schema
class PostgresService {
  PostgresService._();

  /// 每页行数(表数据浏览)
  static const pageSize = 200;

  static Future<Connection> open(DbConnectionConfig config) {
    SecurityContext? securityContext;
    var sslMode = config.useSsl ? SslMode.require : SslMode.disable;
    if (config.useSsl) {
      final hasRootCert =
          config.sslRootCertPath != null &&
          config.sslRootCertPath!.isNotEmpty;
      final hasClientCert =
          config.sslClientCertPath != null &&
          config.sslClientCertPath!.isNotEmpty;
      final hasClientKey =
          config.sslClientKeyPath != null &&
          config.sslClientKeyPath!.isNotEmpty;
      if (hasRootCert || hasClientCert || hasClientKey) {
        securityContext = SecurityContext(withTrustedRoots: true);
        if (hasRootCert) {
          securityContext.setTrustedCertificates(config.sslRootCertPath!);
          sslMode = SslMode.verifyFull;
        }
        if (hasClientCert) {
          securityContext.useCertificateChain(config.sslClientCertPath!);
        }
        if (hasClientKey) {
          securityContext.usePrivateKey(config.sslClientKeyPath!);
        }
      }
    }

    return Connection.open(
      Endpoint(
        host: config.host,
        port: config.port,
        database: config.database,
        username: config.username,
        password: config.password,
      ),
      settings: ConnectionSettings(
        sslMode: sslMode,
        securityContext: securityContext,
        connectTimeout: const Duration(seconds: 8),
      ),
    );
  }

  /// 测试连接:能连上即成功,返回服务器版本
  static Future<String> testConnection(DbConnectionConfig config) async {
    final conn = await open(config);
    try {
      final result = await conn.execute('SHOW server_version');
      return result.isEmpty ? 'unknown' : '${result.first.first}';
    } finally {
      await conn.close();
    }
  }

  /// 服务器版本
  static Future<String?> serverVersion(Connection conn) async {
    final v = await conn.execute('SHOW server_version');
    return v.isEmpty ? null : '${v.first.first}';
  }

  /// 列出用户 schema(排除系统 schema)
  static Future<List<String>> listSchemas(Connection conn) async {
    final result = await conn.execute(
      "SELECT nspname FROM pg_catalog.pg_namespace "
      "WHERE nspname NOT LIKE 'pg\\_%' AND nspname <> 'information_schema' "
      "ORDER BY nspname",
    );
    return [for (final row in result) row.first as String];
  }

  /// 列出 schema 下的表和视图
  static Future<List<DbTableInfo>> listTables(
    Connection conn,
    String schema,
  ) async {
    final result = await conn.execute(
      Sql.named(
        "SELECT table_name, table_type FROM information_schema.tables "
        "WHERE table_schema = @schema "
        "ORDER BY table_type, table_name",
      ),
      parameters: {'schema': schema},
    );
    return [
      for (final row in result)
        DbTableInfo(
          name: row[0] as String,
          isView: (row[1] as String).contains('VIEW'),
        ),
    ];
  }

  /// 合成全行过滤 + 列过滤为 WHERE 子句(无别名,直接引用列名)+ 参数
  static (String, Map<String, Object?>) _combineWhere(
    String filter,
    List<DbColumnFilter> columnFilters,
  ) {
    final clauses = <String>[];
    final params = <String, Object?>{};
    if (filter.isNotEmpty) {
      clauses.add('_t::text ILIKE @filter');
      params['filter'] = '%$filter%';
    }
    final (colWhere, colParams) = buildWhere(columnFilters);
    if (colWhere.isNotEmpty) {
      clauses.add(colWhere);
      params.addAll(colParams);
    }
    final where = clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')} ';
    return (where, params);
  }

  /// 浏览表数据(分页)。多取一行用于判断是否还有下一页。
  static Future<(DbQueryOutput, bool hasMore, DbEditContext?)> fetchTableData(
    Connection conn,
    String schema,
    String table, {
    int page = 0,
    String? orderBy,
    bool ascending = true,
    String filter = '',
    List<DbColumnFilter> columnFilters = const [],
  }) async {
    final target = '${_quoteIdent(schema)}.${_quoteIdent(table)}';
    final (where, params) = _combineWhere(filter, columnFilters);
    final order = orderBy == null
        ? ''
        : 'ORDER BY ${_quoteIdent(orderBy)} ${ascending ? 'ASC' : 'DESC'} ';
    final sql =
        'SELECT * FROM $target AS _t '
        '$where$order'
        'LIMIT ${pageSize + 1} OFFSET ${page * pageSize}';
    final watch = Stopwatch()..start();
    final result = params.isEmpty
        ? await conn.execute(sql)
        : await conn.execute(Sql.named(sql), parameters: params);
    watch.stop();

    final hasMore = result.length > pageSize;
    final rows = hasMore ? result.sublist(0, pageSize) : result;
    final editContext = await resolveEditContext(conn, result);
    return (
      DbQueryOutput(
        columns: _columnNames(result),
        rows: [
          for (final row in rows) _normalizeRow(row),
        ],
        affectedRows: rows.length,
        elapsed: watch.elapsed,
      ),
      hasMore,
      editContext,
    );
  }

  /// 行数统计(带过滤条件时统计过滤后的行数)
  static Future<int> countRows(
    Connection conn,
    String schema,
    String table, {
    String filter = '',
    List<DbColumnFilter> columnFilters = const [],
  }) async {
    final target = '${_quoteIdent(schema)}.${_quoteIdent(table)}';
    final (where, params) = _combineWhere(filter, columnFilters);
    final sql = 'SELECT count(*) FROM $target AS _t $where';
    final result = params.isEmpty
        ? await conn.execute(sql)
        : await conn.execute(Sql.named(sql), parameters: params);
    return result.first.first as int;
  }

  /// 解析结果集的编辑上下文:所有列来自同一张表(tableOid 相同)且
  /// 结果中包含该表完整主键时可编辑;别名列通过 columnOid 映射回真实列。
  static Future<DbEditContext?> resolveEditContext(
    Connection conn,
    Result result,
  ) async {
    final cols = result.schema.columns;
    if (cols.isEmpty) return null;
    final tableOids = {for (final c in cols) c.tableOid};
    final oid = tableOids.length == 1 ? tableOids.first : null;
    if (oid == null || oid == 0) return null;

    // 一次取回表名 + 全部列(名称/类型/主键标记)
    final metaResult = await conn.execute(
      Sql.named('''
SELECT n.nspname, c.relname, a.attnum, a.attname,
       pg_catalog.format_type(a.atttypid, a.atttypmod),
       COALESCE(i.indisprimary, false)
FROM pg_attribute a
JOIN pg_class c ON c.oid = a.attrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_index i
  ON i.indrelid = a.attrelid AND a.attnum = ANY(i.indkey) AND i.indisprimary
WHERE a.attrelid = @oid AND a.attnum > 0 AND NOT a.attisdropped'''),
      parameters: {'oid': oid},
    );
    if (metaResult.isEmpty) return null;

    final schema = metaResult.first[0] as String;
    final table = metaResult.first[1] as String;
    final byAttnum = {
      for (final row in metaResult)
        row[2] as int: (
          name: row[3] as String,
          type: row[4] as String,
          isPk: row[5] as bool,
        ),
    };

    final columnNames = <String?>[];
    final columnTypes = <String>[];
    for (final col in cols) {
      final attr = byAttnum[col.columnOid];
      columnNames.add(attr?.name);
      columnTypes.add(attr?.type ?? 'text');
    }

    // 主键的每一列都必须出现在结果集中,否则不可编辑(pkColumnIndexes 为空)
    final pkAttnums = [
      for (final entry in byAttnum.entries)
        if (entry.value.isPk) entry.key,
    ];
    var pkIndexes = <int>[];
    for (final attnum in pkAttnums) {
      final index = cols.indexWhere((c) => c.columnOid == attnum);
      if (index < 0) {
        pkIndexes = const [];
        break;
      }
      pkIndexes.add(index);
    }
    if (pkAttnums.isEmpty) pkIndexes = const [];

    return DbEditContext(
      schema: schema,
      table: table,
      columnNames: columnNames,
      columnTypes: columnTypes,
      pkColumnIndexes: pkIndexes,
    );
  }

  /// 表结构:列(pg_catalog,含精确类型/默认值/主键)+ 索引 + 行数估计
  static Future<DbTableStructure> fetchTableStructure(
    Connection conn,
    String schema,
    String table,
  ) async {
    final columnsResult = await conn.execute(
      Sql.named('''
SELECT a.attname,
       pg_catalog.format_type(a.atttypid, a.atttypmod) AS data_type,
       NOT a.attnotnull AS nullable,
       pg_get_expr(d.adbin, d.adrelid) AS default_value,
       COALESCE(i.indisprimary, false) AS is_pk,
       col_description(a.attrelid, a.attnum) AS comment
FROM pg_attribute a
JOIN pg_class c ON c.oid = a.attrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
LEFT JOIN pg_index i
  ON i.indrelid = a.attrelid AND a.attnum = ANY(i.indkey) AND i.indisprimary
WHERE n.nspname = @schema AND c.relname = @table
  AND a.attnum > 0 AND NOT a.attisdropped
ORDER BY a.attnum'''),
      parameters: {'schema': schema, 'table': table},
    );

    final indexesResult = await conn.execute(
      Sql.named(
        'SELECT indexname, indexdef FROM pg_indexes '
        'WHERE schemaname = @schema AND tablename = @table ORDER BY indexname',
      ),
      parameters: {'schema': schema, 'table': table},
    );

    // 行数估计 + 表总大小 + 表注释
    final metaResult = await conn.execute(
      Sql.named('''
SELECT c.reltuples::bigint AS approx_rows,
       pg_total_relation_size(c.oid)::bigint AS total_bytes,
       obj_description(c.oid) AS comment
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = @schema AND c.relname = @table'''),
      parameters: {'schema': schema, 'table': table},
    );
    final meta = metaResult.isEmpty ? null : metaResult.first;

    return DbTableStructure(
      columns: [
        for (final row in columnsResult)
          DbColumnInfo(
            name: row[0] as String,
            dataType: row[1] as String,
            nullable: row[2] as bool,
            defaultValue: row[3] as String?,
            isPrimaryKey: row[4] as bool,
            comment: row[5] as String?,
          ),
      ],
      indexes: [
        for (final row in indexesResult)
          DbIndexInfo(
            name: row[0] as String,
            definition: row[1] as String,
          ),
      ],
      approxRows: meta == null ? 0 : (meta[0] as int),
      totalBytes: meta == null ? 0 : (meta[1] as int),
      comment: meta == null ? null : meta[2] as String?,
    );
  }

  /// 更新单个单元格 — 按主键定位行,RETURNING 回读数据库中的最终值
  /// (可能经过类型转换/触发器修改)。[newValue] 为 null 表示 SET NULL。
  static Future<Object?> updateCell(
    Connection conn, {
    required String schema,
    required String table,
    required String column,
    required String dataType,
    required Map<String, Object?> pkValues,
    String? newValue,
  }) async {
    if (pkValues.isEmpty) {
      throw StateError('没有主键,无法定位要更新的行');
    }

    // 值以文本参数传入,CAST 成目标列类型(dataType 来自 pg_catalog,可信)
    final setExpr = newValue == null
        ? 'NULL'
        : 'CAST(@newValue AS $dataType)';

    final pkNames = pkValues.keys.toList();
    final where = [
      for (var i = 0; i < pkNames.length; i++)
        '${_quoteIdent(pkNames[i])} = @pk$i',
    ].join(' AND ');

    final result = await conn.execute(
      Sql.named(
        'UPDATE ${_quoteIdent(schema)}.${_quoteIdent(table)} '
        'SET ${_quoteIdent(column)} = $setExpr '
        'WHERE $where '
        'RETURNING ${_quoteIdent(column)}',
      ),
      parameters: {
        'newValue': ?newValue,
        for (var i = 0; i < pkNames.length; i++) 'pk$i': pkValues[pkNames[i]],
      },
    );

    if (result.affectedRows != 1) {
      throw StateError('更新影响了 ${result.affectedRows} 行(预期 1 行),已回读刷新');
    }
    return _normalizeValue(result.first.first);
  }

  /// 批量提交累积编辑(dbeaver 式)— 全部包在一个事务里,任一失败整体回滚。
  /// 返回成功提交的语句数。
  static Future<int> applyChanges(
    Connection conn, {
    required DbEditContext context,
    required DbQueryOutput output,
    required DbEditSession session,
  }) async {
    if (!context.editable) {
      throw StateError('该结果集没有完整主键,无法保存改动');
    }

    final schema = _quoteIdent(context.schema);
    final table = _quoteIdent(context.table);
    final target = '$schema.$table';

    return conn.runTx((tx) async {
      var applied = 0;

      // 1. DELETE 标记删除的原始行
      for (final rowIndex in session.removedRows) {
        if (rowIndex < 0 || rowIndex >= output.rows.length) continue;
        final (where, params) = _pkWhere(context, output.rows[rowIndex]);
        final result = await tx.execute(
          Sql.named('DELETE FROM $target WHERE $where'),
          parameters: params,
        );
        if (result.affectedRows != 1) {
          throw StateError('删除行影响了 ${result.affectedRows} 行(预期 1)');
        }
        applied++;
      }

      // 2. UPDATE 修改的单元格(按行合并成一条 UPDATE)
      for (final entry in session.editedCells.entries) {
        final rowIndex = entry.key;
        if (session.removedRows.contains(rowIndex)) continue; // 删了就不改
        if (rowIndex < 0 || rowIndex >= output.rows.length) continue;

        final setClauses = <String>[];
        final params = <String, Object?>{};
        var i = 0;
        for (final cell in entry.value.entries) {
          final colName = context.columnNames[cell.key];
          if (colName == null) continue; // 表达式列跳过
          final type = context.columnTypes[cell.key];
          if (cell.value == null) {
            setClauses.add('${_quoteIdent(colName)} = NULL');
          } else {
            setClauses.add(
              '${_quoteIdent(colName)} = CAST(@set$i AS $type)',
            );
            params['set$i'] = '${cell.value}';
            i++;
          }
        }
        if (setClauses.isEmpty) continue;

        final (where, whereParams) = _pkWhere(context, output.rows[rowIndex]);
        params.addAll(whereParams);
        final result = await tx.execute(
          Sql.named(
            'UPDATE $target SET ${setClauses.join(', ')} WHERE $where',
          ),
          parameters: params,
        );
        if (result.affectedRows != 1) {
          throw StateError('更新行影响了 ${result.affectedRows} 行(预期 1)');
        }
        applied++;
      }

      // 3. INSERT 新增行(只提交已填的列,其余用列默认值)
      for (final row in session.addedRows) {
        final cols = <String>[];
        final placeholders = <String>[];
        final params = <String, Object?>{};
        var i = 0;
        for (var c = 0; c < row.length; c++) {
          final value = row[c];
          if (identical(value, DbEditSession.unsetValue)) continue;
          final colName = context.columnNames[c];
          if (colName == null) continue;
          cols.add(_quoteIdent(colName));
          if (value == null) {
            placeholders.add('NULL');
          } else {
            placeholders.add('CAST(@ins$i AS ${context.columnTypes[c]})');
            params['ins$i'] = '$value';
            i++;
          }
        }
        final sql = cols.isEmpty
            ? 'INSERT INTO $target DEFAULT VALUES'
            : 'INSERT INTO $target (${cols.join(', ')}) '
                  'VALUES (${placeholders.join(', ')})';
        await tx.execute(Sql.named(sql), parameters: params);
        applied++;
      }

      return applied;
    });
  }

  /// 构造主键 WHERE 子句 + 参数(参数名 pk0/pk1…)
  static (String, Map<String, Object?>) _pkWhere(
    DbEditContext context,
    List<Object?> row,
  ) {
    final clauses = <String>[];
    final params = <String, Object?>{};
    var i = 0;
    for (final pkIndex in context.pkColumnIndexes) {
      final name = context.columnNames[pkIndex]!;
      clauses.add('${_quoteIdent(name)} = @pk$i');
      params['pk$i'] = row[pkIndex];
      i++;
    }
    return (clauses.join(' AND '), params);
  }

  /// 执行任意 SQL(SQL 编辑器)。
  /// package:postgres 的一次 execute() 不支持多语句脚本(内部 Future 会被
  /// 完成多次),所以参考 DBeaver 的做法:客户端先拆分语句,逐条顺序执行。
  /// 返回最后一条有结果集语句的行,affectedRows 为所有语句累加。
  /// 同时解析结果集的编辑上下文(单表来源 + 完整主键时结果可编辑)。
  static Future<(DbQueryOutput, DbEditContext?)> runSql(
    Connection conn,
    String sql,
  ) async {
    final statements = splitStatements(sql);
    if (statements.isEmpty) return (const DbQueryOutput(), null);

    final watch = Stopwatch()..start();
    var totalAffected = 0;
    Result? lastWithRows;
    for (final statement in statements) {
      final result = await conn.execute(
        statement,
        queryMode: QueryMode.simple,
        timeout: const Duration(seconds: 60),
      );
      totalAffected += result.affectedRows;
      if (result.schema.columns.isNotEmpty) {
        lastWithRows = result;
      }
    }
    watch.stop();

    DbEditContext? editContext;
    if (lastWithRows != null) {
      try {
        editContext = await resolveEditContext(conn, lastWithRows);
      } catch (_) {
        editContext = null; // 解析失败仅意味着结果不可编辑
      }
    }

    return (
      DbQueryOutput(
        columns: lastWithRows == null ? const [] : _columnNames(lastWithRows),
        rows: [
          if (lastWithRows != null)
            for (final row in lastWithRows) _normalizeRow(row),
        ],
        affectedRows: totalAffected,
        elapsed: watch.elapsed,
      ),
      editContext,
    );
  }

  /// 拆分 SQL 脚本为独立语句 — 跳过字符串('' / "")、dollar-quote($tag$…$tag$)、
  /// 行注释(--)与块注释(/* */)中的分号
  static List<String> splitStatements(String sql) {
    final statements = <String>[];
    final buffer = StringBuffer();

    void flush() {
      final statement = buffer.toString().trim();
      if (statement.isNotEmpty) statements.add(statement);
      buffer.clear();
    }

    var i = 0;
    while (i < sql.length) {
      final ch = sql[i];
      final next = i + 1 < sql.length ? sql[i + 1] : '';

      // 行注释
      if (ch == '-' && next == '-') {
        final end = sql.indexOf('\n', i);
        final stop = end < 0 ? sql.length : end;
        buffer.write(sql.substring(i, stop));
        i = stop;
        continue;
      }
      // 块注释(不处理嵌套,与多数客户端一致)
      if (ch == '/' && next == '*') {
        final end = sql.indexOf('*/', i + 2);
        final stop = end < 0 ? sql.length : end + 2;
        buffer.write(sql.substring(i, stop));
        i = stop;
        continue;
      }
      // 单引号字符串('' 转义)
      if (ch == "'") {
        final end = _findQuoteEnd(sql, i, "'");
        buffer.write(sql.substring(i, end));
        i = end;
        continue;
      }
      // 双引号标识符("" 转义)
      if (ch == '"') {
        final end = _findQuoteEnd(sql, i, '"');
        buffer.write(sql.substring(i, end));
        i = end;
        continue;
      }
      // dollar-quote: $tag$ ... $tag$
      if (ch == r'$') {
        final match = RegExp(
          r'^\$[A-Za-z_]*\$',
        ).firstMatch(sql.substring(i));
        if (match != null) {
          final tag = match.group(0)!;
          final end = sql.indexOf(tag, i + tag.length);
          final stop = end < 0 ? sql.length : end + tag.length;
          buffer.write(sql.substring(i, stop));
          i = stop;
          continue;
        }
      }
      // 语句分隔
      if (ch == ';') {
        flush();
        i++;
        continue;
      }

      buffer.write(ch);
      i++;
    }
    flush();
    return statements;
  }

  /// 返回从 [start](指向起始引号)开始的引用串结束位置(不含),
  /// 双写引号视为转义
  static int _findQuoteEnd(String sql, int start, String quote) {
    var i = start + 1;
    while (i < sql.length) {
      if (sql[i] == quote) {
        if (i + 1 < sql.length && sql[i + 1] == quote) {
          i += 2; // 转义的引号
          continue;
        }
        return i + 1;
      }
      i++;
    }
    return sql.length;
  }

  static List<String> _columnNames(Result result) {
    if (result.schema.columns.isEmpty) return const [];
    var index = 0;
    return [
      for (final col in result.schema.columns)
        col.columnName ?? 'column_${++index}',
    ];
  }

  /// PostgreSQL 标识符引用("镶入语句的 schema/表名必须转义)
  static String _quoteIdent(String ident) =>
      '"${ident.replaceAll('"', '""')}"';

  /// UUID 类型的 OID
  static const _uuidOid = 2950;

  /// 归一化一行的值:把 postgres 未解码的 [UndecodedBytes](如 binary 的 uuid)
  /// 转成可读值,避免网格里显示 "Instance of 'UndecodedBytes'"。
  static List<Object?> _normalizeRow(Iterable<Object?> row) =>
      [for (final v in row) _normalizeValue(v)];

  static Object? _normalizeValue(Object? value) {
    if (value is! UndecodedBytes) return value;
    // UUID 的 binary 表示是 16 字节,需格式化为 8-4-4-4-12 十六进制
    if (value.isBinary &&
        value.typeOid == _uuidOid &&
        value.bytes.length == 16) {
      return _formatUuid(value.bytes);
    }
    // 其余未解码类型:文本编码直接解码;失败则回退为字节
    try {
      return value.asString;
    } catch (_) {
      return value.bytes;
    }
  }

  static String _formatUuid(List<int> bytes) {
    final hex = [
      for (final b in bytes) b.toRadixString(16).padLeft(2, '0'),
    ].join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }
}
