import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:termora/features/database/domain/db_models.dart';

/// SQLite 访问封装(package:sqlite3,macOS 直接绑系统 libsqlite3)。
/// config.database 存数据库文件路径;schema 对应 ATTACH 的库名(通常只有 main)。
/// 驱动是同步 API,本地文件足够快,统一包成 Future 与其它引擎对齐。
class SqliteService {
  SqliteService._();

  static const pageSize = 200;

  static Future<Database> open(DbConnectionConfig config) async {
    final path = config.database.trim();
    if (path.isEmpty) {
      throw StateError('未指定数据库文件路径');
    }
    // 不隐式建库:路径打错时静默创建空文件很难排查
    if (!File(path).existsSync()) {
      throw StateError('数据库文件不存在: $path');
    }
    return sqlite3.open(path);
  }

  static Future<String> testConnection(DbConnectionConfig config) async {
    final db = await open(config);
    try {
      return db.select('SELECT sqlite_version()').first.values.first
          as String;
    } finally {
      db.close();
    }
  }

  static Future<String?> serverVersion(Database db) async {
    try {
      return db.select('SELECT sqlite_version()').first.values.first
          as String;
    } catch (_) {
      return null;
    }
  }

  /// 标识符转义(双引号)
  static String _ident(String name) => '"${name.replaceAll('"', '""')}"';

  static String _qualified(String schema, String table) =>
      '${_ident(schema)}.${_ident(table)}';

  /// main + ATTACH 的库(temp 隐藏)
  static Future<List<String>> listSchemas(Database db) async {
    final result = db.select(
      'SELECT name FROM pragma_database_list ORDER BY seq',
    );
    return [
      for (final row in result.rows)
        if (row.first != 'temp') row.first as String,
    ];
  }

  static Future<List<DbTableInfo>> listTables(
    Database db,
    String schema,
  ) async {
    final result = db.select(
      "SELECT name, type FROM ${_ident(schema)}.sqlite_master "
      "WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' "
      'ORDER BY type, name',
      [],
    );
    return [
      for (final row in result.rows)
        DbTableInfo(name: row[0] as String, isView: row[1] == 'view'),
    ];
  }

  /// pragma_table_info 的列元数据(pk 为主键内序号,0 = 非主键)
  static List<({String name, String type, bool notnull, String? dflt, int pk})>
  _tableColumns(Database db, String schema, String table) {
    final result = db.select(
      'SELECT name, type, "notnull", dflt_value, pk '
      'FROM pragma_table_info(?1, ?2) ORDER BY cid',
      [table, schema],
    );
    return [
      for (final row in result.rows)
        (
          name: row[0] as String,
          type: (row[1] as String?)?.isEmpty ?? true
              ? 'TEXT'
              : row[1] as String,
          notnull: row[2] == 1,
          dflt: row[3] == null ? null : '${row[3]}',
          pk: (row[4] as num).toInt(),
        ),
    ];
  }

  /// 合成 WHERE + 位置参数(全行过滤 + 列过滤,统一 CAST 成文本比较;
  /// SQLite 的 LIKE 对 ASCII 默认不区分大小写,近似 ILIKE)
  static (String, List<Object?>) _buildWhere(
    Database db,
    String schema,
    String table,
    String filter,
    List<DbColumnFilter> columnFilters,
  ) {
    final clauses = <String>[];
    final params = <Object?>[];

    if (filter.isNotEmpty) {
      final cols = _tableColumns(db, schema, table);
      if (cols.isNotEmpty) {
        final ors = <String>[];
        for (final c in cols) {
          ors.add('CAST(${_ident(c.name)} AS TEXT) LIKE ?');
          params.add('%$filter%');
        }
        clauses.add('(${ors.join(' OR ')})');
      }
    }

    for (final f in columnFilters) {
      final (frag, p) = _columnFragment(f);
      clauses.add('($frag)');
      params.addAll(p);
    }

    final where = clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')} ';
    return (where, params);
  }

  /// 列过滤片段(SQLite 语法,值统一文本语义)
  static (String, List<Object?>) _columnFragment(DbColumnFilter f) {
    final raw = _ident(f.column);
    final col = 'CAST($raw AS TEXT)';
    switch (f.op) {
      case DbFilterOp.isNull:
        return ('$raw IS NULL', const []);
      case DbFilterOp.isNotNull:
        return ('$raw IS NOT NULL', const []);
      case DbFilterOp.like:
        return ('$col LIKE ?', ['%${f.value}%']);
      case DbFilterOp.inList:
        final items = f.value
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
        if (items.isEmpty) return ('1', const []);
        final placeholders = List.filled(items.length, '?').join(', ');
        return ('$col IN ($placeholders)', items);
      case DbFilterOp.equals:
        return ('$col = ?', [f.value]);
      case DbFilterOp.notEquals:
        return ('$col <> ?', [f.value]);
      case DbFilterOp.greater:
        return ('$col > ?', [f.value]);
      case DbFilterOp.less:
        return ('$col < ?', [f.value]);
      case DbFilterOp.greaterEqual:
        return ('$col >= ?', [f.value]);
      case DbFilterOp.lessEqual:
        return ('$col <= ?', [f.value]);
    }
  }

  static Future<(DbQueryOutput, bool, DbEditContext?)> fetchTableData(
    Database db,
    String schema,
    String table, {
    int page = 0,
    String? orderBy,
    bool ascending = true,
    String filter = '',
    List<DbColumnFilter> columnFilters = const [],
  }) async {
    final (where, params) = _buildWhere(
      db,
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
    final watch = Stopwatch()..start();
    final result = db.select(sql, params);
    watch.stop();

    final hasMore = result.rows.length > pageSize;
    final rows = hasMore ? result.rows.sublist(0, pageSize) : result.rows;
    return (
      DbQueryOutput(
        columns: result.columnNames,
        rows: rows,
        affectedRows: rows.length,
        elapsed: watch.elapsed,
      ),
      hasMore,
      _editContext(db, schema, table, result.columnNames),
    );
  }

  /// 表浏览(SELECT *)的编辑上下文:列一一对应真实列,
  /// 有声明主键且全部在结果中才可编辑(无主键的 rowid 表/视图只读)
  static DbEditContext? _editContext(
    Database db,
    String schema,
    String table,
    List<String> resultColumns,
  ) {
    final info = _tableColumns(db, schema, table);
    if (info.isEmpty) return null;
    final byName = {for (final c in info) c.name: c};

    final columnNames = <String?>[];
    final columnTypes = <String>[];
    for (final col in resultColumns) {
      final c = byName[col];
      columnNames.add(c?.name);
      columnTypes.add(c?.type ?? 'TEXT');
    }

    final pkCols = [
      for (final c in info)
        if (c.pk > 0) c,
    ]..sort((a, b) => a.pk.compareTo(b.pk));
    var pkIndexes = <int>[];
    for (final c in pkCols) {
      final index = resultColumns.indexOf(c.name);
      if (index < 0) {
        pkIndexes = const [];
        break;
      }
      pkIndexes.add(index);
    }
    if (pkCols.isEmpty) pkIndexes = const [];

    return DbEditContext(
      schema: schema,
      table: table,
      columnNames: columnNames,
      columnTypes: columnTypes,
      pkColumnIndexes: pkIndexes,
    );
  }

  static Future<int> countRows(
    Database db,
    String schema,
    String table, {
    String filter = '',
    List<DbColumnFilter> columnFilters = const [],
  }) async {
    final (where, params) = _buildWhere(
      db,
      schema,
      table,
      filter,
      columnFilters,
    );
    final result = db.select(
      'SELECT count(*) FROM ${_qualified(schema, table)} $where',
      params,
    );
    return (result.first.values.first as num).toInt();
  }

  static Future<DbTableStructure> fetchTableStructure(
    Database db,
    String schema,
    String table,
  ) async {
    final columns = _tableColumns(db, schema, table);

    final indexResult = db.select(
      "SELECT name, sql FROM ${_ident(schema)}.sqlite_master "
      "WHERE type = 'index' AND tbl_name = ?1 ORDER BY name",
      [table],
    );

    var approxRows = 0;
    try {
      approxRows = (db
                  .select('SELECT count(*) FROM ${_qualified(schema, table)}')
                  .first
                  .values
                  .first
              as num)
          .toInt();
    } catch (_) {}

    // 表体积需要 dbstat 虚表(编译开关),没有就不显示
    var totalBytes = 0;
    try {
      final size = db.select(
        'SELECT sum(pgsize) FROM ${_ident(schema)}.dbstat WHERE name = ?1',
        [table],
      );
      totalBytes = (size.first.values.first as num?)?.toInt() ?? 0;
    } catch (_) {}

    return DbTableStructure(
      columns: [
        for (final c in columns)
          DbColumnInfo(
            name: c.name,
            dataType: c.type,
            nullable: !c.notnull && c.pk == 0,
            defaultValue: c.dflt,
            isPrimaryKey: c.pk > 0,
          ),
      ],
      indexes: [
        for (final row in indexResult.rows)
          DbIndexInfo(
            name: row[0] as String,
            // 自动索引(unique 约束等)没有 DDL 文本
            definition: row[1] as String? ?? '(自动索引)',
          ),
      ],
      approxRows: approxRows,
      totalBytes: totalBytes,
    );
  }

  /// 执行 SQL 脚本:prepareMultiple 天然支持多语句(正确跳过字符串/注释),
  /// 逐条执行,返回最后一条有结果集语句的行。
  /// 对最后一条有结果集的 SELECT 语句,尝试解析来源表以提供编辑上下文。
  static Future<(DbQueryOutput, DbEditContext?)> runSql(
    Database db,
    String sql,
  ) async {
    final watch = Stopwatch()..start();
    final statements = db.prepareMultiple(sql);
    ResultSet? lastWithRows;
    String? lastSqlWithRows;
    var totalAffected = 0;
    try {
      for (final statement in statements) {
        final result = statement.select();
        if (result.columnNames.isNotEmpty) {
          lastWithRows = result;
          lastSqlWithRows = statement.sql;
        } else if (_isDml(statement.sql)) {
          totalAffected += db.updatedRows;
        }
      }
    } finally {
      for (final statement in statements) {
        statement.close();
      }
    }
    watch.stop();

    // 尝试从最后一条 SELECT 解析编辑上下文
    DbEditContext? editContext;
    if (lastWithRows != null && lastSqlWithRows != null) {
      try {
        editContext = _resolveRunSqlEditContext(
          db,
          lastSqlWithRows,
          lastWithRows.columnNames,
        );
      } catch (_) {
        editContext = null;
      }
    }

    return (
      DbQueryOutput(
        columns: lastWithRows?.columnNames ?? const [],
        rows: lastWithRows?.rows ?? const [],
        affectedRows: lastWithRows?.rows.length ?? totalAffected,
        elapsed: watch.elapsed,
      ),
      editContext,
    );
  }

  /// 从 SELECT 语句推断编辑上下文:
  /// 识别 "SELECT ... FROM [schema.]table ..." 中的单表来源,
  /// 然后走 _editContext 检查主键覆盖。
  static DbEditContext? _resolveRunSqlEditContext(
    Database db,
    String sql,
    List<String> resultColumns,
  ) {
    final parsed = _parseSelectTable(sql);
    if (parsed == null) return null;
    final (schema, table) = parsed;
    return _editContext(db, schema, table, resultColumns);
  }

  /// 简单解析 SELECT 的 FROM 子句,提取单表名(含可选的 schema 前缀)。
  /// 支持带引号标识符 "name" 和不带引号的 name。
  /// 仅匹配 FROM 后紧跟一张表(子查询/JOIN/多表跳过),返回 (schema, table)。
  static (String, String)? _parseSelectTable(String sql) {
    // 去掉头部空白并做大小写不敏感匹配
    final normalized = sql.trimLeft();
    if (!normalized.toLowerCase().startsWith('select')) return null;

    // 找 FROM 关键字(跳过字符串、括号嵌套)
    final fromIndex = _findKeyword(normalized, 'from');
    if (fromIndex < 0) return null;

    // FROM 后面提取标识符
    var pos = fromIndex + 4; // "FROM".length
    // 跳过空白
    while (pos < normalized.length && normalized[pos] == ' ') {
      pos++;
    }

    // 提取第一个标识符(可能是 schema 或 table)
    final (id1, pos2) = _extractIdentifier(normalized, pos);
    if (id1 == null) return null;

    // 检查是否有 . 分隔(schema.table)
    var p = pos2;
    while (p < normalized.length && normalized[p] == ' ') {
      p++;
    }

    if (p < normalized.length && normalized[p] == '.') {
      p++;
      while (p < normalized.length && normalized[p] == ' ') {
        p++;
      }
      final (id2, _) = _extractIdentifier(normalized, p);
      if (id2 == null) return null;
      return (id1, id2);
    }

    // 无 schema 前缀 → 默认 main
    return ('main', id1);
  }

  /// 在 SQL 中找顶层的关键字(跳过括号嵌套和字符串),
  /// 返回关键字起始下标;找不到返回 -1。
  static int _findKeyword(String sql, String keyword) {
    final lower = sql.toLowerCase();
    final kw = keyword.toLowerCase();
    var depth = 0;
    var i = 0;
    while (i < sql.length) {
      final ch = sql[i];
      if (ch == '(' ) { depth++; i++; continue; }
      if (ch == ')' ) { depth--; i++; continue; }
      if (ch == "'" || ch == '"') {
        i = _skipQuoted(sql, i);
        continue;
      }
      if (depth == 0 &&
          i + kw.length <= lower.length &&
          lower.substring(i, i + kw.length) == kw) {
        // 确保是完整单词边界
        final before = i > 0 ? sql[i - 1] : ' ';
        final after = i + kw.length < sql.length ? sql[i + kw.length] : ' ';
        if (_isWordBoundary(before) && _isWordBoundary(after)) {
          return i;
        }
      }
      i++;
    }
    return -1;
  }

  static bool _isWordBoundary(String ch) =>
      !RegExp(r'[a-zA-Z0-9_]').hasMatch(ch);

  /// 跳过引号字符串,返回引号闭合后的下一个位置
  static int _skipQuoted(String sql, int start) {
    final quote = sql[start];
    var i = start + 1;
    while (i < sql.length) {
      if (sql[i] == quote) {
        if (i + 1 < sql.length && sql[i + 1] == quote) {
          i += 2; // 转义引号
        } else {
          return i + 1;
        }
      } else {
        i++;
      }
    }
    return sql.length;
  }

  /// 从 pos 开始提取一个 SQL 标识符(带引号或裸标识符),
  /// 返回 (标识符, 下一个位置)。
  static (String?, int) _extractIdentifier(String sql, int pos) {
    if (pos >= sql.length) return (null, pos);

    // 带双引号的标识符
    if (sql[pos] == '"') {
      final buf = StringBuffer();
      var i = pos + 1;
      while (i < sql.length) {
        if (sql[i] == '"') {
          if (i + 1 < sql.length && sql[i + 1] == '"') {
            buf.write('"');
            i += 2;
          } else {
            return (buf.toString(), i + 1);
          }
        } else {
          buf.write(sql[i]);
          i++;
        }
      }
      return (null, sql.length);
    }

    // 裸标识符(字母、数字、下划线)
    final start = pos;
    while (pos < sql.length && RegExp(r'[a-zA-Z0-9_]').hasMatch(sql[pos])) {
      pos++;
    }
    if (pos == start) return (null, pos);
    return (sql.substring(start, pos), pos);
  }

  /// db.updatedRows(sqlite3_changes)只对 DML 有意义,DDL 会残留上一次的值
  static bool _isDml(String sql) {
    final head = sql.trimLeft().toLowerCase();
    return head.startsWith('insert') ||
        head.startsWith('update') ||
        head.startsWith('delete') ||
        head.startsWith('replace');
  }

  /// 批量提交累积编辑 — 与 postgres 行为对齐:单事务,任一失败整体回滚。
  static Future<int> applyChanges(
    Database db, {
    required DbEditContext context,
    required DbQueryOutput output,
    required DbEditSession session,
  }) async {
    if (!context.editable) {
      throw StateError('该结果集没有完整主键,无法保存改动');
    }
    final target = _qualified(context.schema, context.table);

    var applied = 0;
    db.execute('BEGIN');
    try {
      // 1. DELETE 标记删除的原始行
      for (final rowIndex in session.removedRows) {
        if (rowIndex < 0 || rowIndex >= output.rows.length) continue;
        final (where, params) = _pkWhere(context, output.rows[rowIndex]);
        db.execute('DELETE FROM $target WHERE $where', params);
        if (db.updatedRows != 1) {
          throw StateError('删除行影响了 ${db.updatedRows} 行(预期 1)');
        }
        applied++;
      }

      // 2. UPDATE 修改的单元格(按行合并成一条 UPDATE)
      for (final entry in session.editedCells.entries) {
        final rowIndex = entry.key;
        if (session.removedRows.contains(rowIndex)) continue; // 删了就不改
        if (rowIndex < 0 || rowIndex >= output.rows.length) continue;

        final setClauses = <String>[];
        final params = <Object?>[];
        for (final cell in entry.value.entries) {
          final colName = context.columnNames[cell.key];
          if (colName == null) continue;
          if (cell.value == null) {
            setClauses.add('${_ident(colName)} = NULL');
          } else {
            // 文本绑定,靠列亲和性(type affinity)落成目标类型
            setClauses.add('${_ident(colName)} = ?');
            params.add('${cell.value}');
          }
        }
        if (setClauses.isEmpty) continue;

        final (where, whereParams) = _pkWhere(context, output.rows[rowIndex]);
        db.execute(
          'UPDATE $target SET ${setClauses.join(', ')} WHERE $where',
          [...params, ...whereParams],
        );
        if (db.updatedRows != 1) {
          throw StateError('更新行影响了 ${db.updatedRows} 行(预期 1)');
        }
        applied++;
      }

      // 3. INSERT 新增行(只提交已填的列,其余用列默认值)
      for (final row in session.addedRows) {
        final cols = <String>[];
        final placeholders = <String>[];
        final params = <Object?>[];
        for (var c = 0; c < row.length; c++) {
          final value = row[c];
          if (identical(value, DbEditSession.unsetValue)) continue;
          final colName = context.columnNames[c];
          if (colName == null) continue;
          cols.add(_ident(colName));
          if (value == null) {
            placeholders.add('NULL');
          } else {
            placeholders.add('?');
            params.add('$value');
          }
        }
        final sql = cols.isEmpty
            ? 'INSERT INTO $target DEFAULT VALUES'
            : 'INSERT INTO $target (${cols.join(', ')}) '
                  'VALUES (${placeholders.join(', ')})';
        db.execute(sql, params);
        applied++;
      }

      db.execute('COMMIT');
      return applied;
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// 构造主键 WHERE 子句 + 位置参数
  static (String, List<Object?>) _pkWhere(
    DbEditContext context,
    List<Object?> row,
  ) {
    final clauses = <String>[];
    final params = <Object?>[];
    for (final pkIndex in context.pkColumnIndexes) {
      clauses.add('${_ident(context.columnNames[pkIndex]!)} = ?');
      params.add(row[pkIndex]);
    }
    return (clauses.join(' AND '), params);
  }
}
