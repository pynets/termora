import 'dart:convert';
import 'package:termora/core/l10n/app_l10n.dart';

/// 数据库引擎类型
enum DbEngine {
  postgres('PostgreSQL', 5432, 'postgres', 'postgres'),
  clickhouse('ClickHouse', 8123, 'default', 'default'),
  sqlite('SQLite', 0, '', '');

  const DbEngine(
    this.label,
    this.defaultPort,
    this.defaultDatabase,
    this.defaultUser,
  );

  final String label;
  final int defaultPort;
  final String defaultDatabase;
  final String defaultUser;

  /// 是否支持数据编辑(ClickHouse 只读)
  bool get supportsEdit => this != DbEngine.clickhouse;

  /// 文件型数据库(无主机/端口/账号,database 字段存文件路径)
  bool get isFileBased => this == DbEngine.sqlite;

  static DbEngine fromName(String? name) => DbEngine.values.firstWhere(
    (e) => e.name == name,
    orElse: () => DbEngine.postgres,
  );
}

/// 一条已保存的数据库连接配置(参考 DBeaver 连接配置的核心字段)
class DbConnectionConfig {
  const DbConnectionConfig({
    required this.id,
    required this.name,
    this.engine = DbEngine.postgres,
    this.host = 'localhost',
    this.port = 5432,
    this.database = 'postgres',
    this.username = 'postgres',
    this.password = '',
    this.useSsl = false,
    this.sslClientCertPath,
    this.sslClientKeyPath,
    this.sslRootCertPath,
  });

  final String id;
  final String name;
  final DbEngine engine;
  final String host;
  final int port;
  final String database;
  final String username;
  final String password;
  final bool useSsl;
  final String? sslClientCertPath;
  final String? sslClientKeyPath;
  final String? sslRootCertPath;

  DbConnectionConfig copyWith({
    String? name,
    DbEngine? engine,
    String? host,
    int? port,
    String? database,
    String? username,
    String? password,
    bool? useSsl,
    String? sslClientCertPath,
    String? sslClientKeyPath,
    String? sslRootCertPath,
  }) {
    return DbConnectionConfig(
      id: id,
      name: name ?? this.name,
      engine: engine ?? this.engine,
      host: host ?? this.host,
      port: port ?? this.port,
      database: database ?? this.database,
      username: username ?? this.username,
      password: password ?? this.password,
      useSsl: useSsl ?? this.useSsl,
      sslClientCertPath: sslClientCertPath ?? this.sslClientCertPath,
      sslClientKeyPath: sslClientKeyPath ?? this.sslClientKeyPath,
      sslRootCertPath: sslRootCertPath ?? this.sslRootCertPath,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'engine': engine.name,
    'host': host,
    'port': port,
    'database': database,
    'username': username,
    // 仅做 base64 混淆,防止偏好文件被直接肉眼读取;并非加密
    'password': base64Encode(utf8.encode(password)),
    'useSsl': useSsl,
    if (sslClientCertPath != null) 'sslClientCertPath': sslClientCertPath,
    if (sslClientKeyPath != null) 'sslClientKeyPath': sslClientKeyPath,
    if (sslRootCertPath != null) 'sslRootCertPath': sslRootCertPath,
  };

  factory DbConnectionConfig.fromJson(Map<String, dynamic> json) {
    String decodePassword(dynamic raw) {
      if (raw is! String || raw.isEmpty) return '';
      try {
        return utf8.decode(base64Decode(raw));
      } catch (_) {
        return raw;
      }
    }

    return DbConnectionConfig(
      id: json['id'] as String,
      name: json['name'] as String? ?? tr('未命名连接'),
      engine: DbEngine.fromName(json['engine'] as String?),
      host: json['host'] as String? ?? 'localhost',
      port: (json['port'] as num?)?.toInt() ?? 5432,
      database: json['database'] as String? ?? 'postgres',
      username: json['username'] as String? ?? 'postgres',
      password: decodePassword(json['password']),
      useSsl: json['useSsl'] as bool? ?? false,
      sslClientCertPath: json['sslClientCertPath'] as String?,
      sslClientKeyPath: json['sslClientKeyPath'] as String?,
      sslRootCertPath: json['sslRootCertPath'] as String?,
    );
  }
}

/// 导航树中的表条目
class DbTableInfo {
  const DbTableInfo({required this.name, required this.isView});

  final String name;
  final bool isView;
}

/// 表的列定义
class DbColumnInfo {
  const DbColumnInfo({
    required this.name,
    required this.dataType,
    required this.nullable,
    this.defaultValue,
    this.isPrimaryKey = false,
    this.comment,
    this.isGenerated = false,
  });

  final String name;
  final String dataType;
  final bool nullable;

  /// 默认值表达式;生成列时是生成表达式(pg GENERATED … AS 的括号内)
  final String? defaultValue;
  final bool isPrimaryKey;

  /// 列注释(COMMENT ON COLUMN)
  final String? comment;

  /// 生成列(pg GENERATED ALWAYS AS … STORED):不能 INSERT,
  /// 表达式在 [defaultValue]
  final bool isGenerated;
}

/// 表的索引定义
class DbIndexInfo {
  const DbIndexInfo({required this.name, required this.definition});

  final String name;
  final String definition;
}

/// 表级约束类型(结构读取 + 迁移用)
enum DbConstraintType { foreignKey, check }

/// 表级约束(外键 / CHECK)。[definition] 是源引擎方言的约束体,
/// 如 `FOREIGN KEY (uid) REFERENCES users(id) ON DELETE CASCADE`。
class DbConstraintInfo {
  const DbConstraintInfo({
    required this.name,
    required this.type,
    required this.definition,
    this.refSchema,
    this.refTable,
  });

  final String name;
  final DbConstraintType type;
  final String definition;

  /// 外键引用的目标(迁移时重写 REFERENCES 用)
  final String? refSchema;
  final String? refTable;
}

/// 表结构(结构面板)
class DbTableStructure {
  const DbTableStructure({
    this.columns = const [],
    this.indexes = const [],
    this.constraints = const [],
    this.approxRows = 0,
    this.totalBytes = 0,
    this.comment,
  });

  final List<DbColumnInfo> columns;
  final List<DbIndexInfo> indexes;

  /// 外键 / CHECK 约束(pg/sqlite 抓取;CH 无此概念)
  final List<DbConstraintInfo> constraints;

  /// pg_class.reltuples 的行数估计(-1 表示从未 analyze)
  final int approxRows;

  /// 表总大小(含索引/TOAST),字节
  final int totalBytes;

  /// 表注释(COMMENT ON TABLE)
  final String? comment;

  /// 人类可读的大小
  String get prettySize {
    if (totalBytes <= 0) return '—';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var size = totalBytes.toDouble();
    var unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit++;
    }
    final text = unit == 0 ? size.toStringAsFixed(0) : size.toStringAsFixed(1);
    return '$text ${units[unit]}';
  }
}

/// 结果集的编辑上下文 — 结果列同源于一张表且包含完整主键时可编辑
/// (由 RowDescription 的 tableOid/columnOid 解析,别名列也能映射回真实列)
class DbEditContext {
  const DbEditContext({
    required this.schema,
    required this.table,
    required this.columnNames,
    required this.columnTypes,
    required this.pkColumnIndexes,
  });

  final String schema;
  final String table;

  /// 每个结果列对应的真实列名(表达式列为 null,不可编辑)
  final List<String?> columnNames;

  /// 每个结果列的类型(format_type,未知为 'text')
  final List<String> columnTypes;

  /// 构成主键的结果列下标(为空 = 不可编辑)
  final List<int> pkColumnIndexes;

  bool get editable => pkColumnIndexes.isNotEmpty;
}

/// 列级过滤操作符(dbeaver 的列过滤)
enum DbFilterOp {
  equals('=', '等于'),
  notEquals('≠', '不等于'),
  like('LIKE', '包含'),
  greater('>', '大于'),
  less('<', '小于'),
  greaterEqual('≥', '大于等于'),
  lessEqual('≤', '小于等于'),
  isNull('IS NULL', '为空'),
  isNotNull('IS NOT NULL', '不为空'),
  inList('IN', '在列表中');

  const DbFilterOp(this.symbol, this.labelZh);

  final String symbol;
  final String labelZh;

  String get label => AppL10n.tr(labelZh);

  /// 是否需要输入值(IS NULL / IS NOT NULL 不需要)
  bool get needsValue => this != isNull && this != isNotNull;
}

/// 单列过滤条件
class DbColumnFilter {
  const DbColumnFilter({
    required this.column,
    required this.op,
    this.value = '',
  });

  final String column;
  final DbFilterOp op;
  final String value;

  /// 构造 WHERE 片段 + 参数(参数名以 [paramName] 为前缀,避免多列冲突)
  /// 值以文本参数绑定,LIKE 自动加 %,IN 按逗号拆分。
  (String, Map<String, Object?>) toSqlFragment(String paramName) {
    final quoted = '"${column.replaceAll('"', '""')}"';
    switch (op) {
      case DbFilterOp.isNull:
        return ('$quoted IS NULL', const {});
      case DbFilterOp.isNotNull:
        return ('$quoted IS NOT NULL', const {});
      case DbFilterOp.like:
        return ('$quoted::text ILIKE @$paramName', {paramName: '%$value%'});
      case DbFilterOp.inList:
        final items = value
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
        if (items.isEmpty) return ('TRUE', const {});
        final placeholders = <String>[];
        final params = <String, Object?>{};
        for (var i = 0; i < items.length; i++) {
          placeholders.add('@$paramName$i');
          params['$paramName$i'] = items[i];
        }
        return ('$quoted::text IN (${placeholders.join(', ')})', params);
      case DbFilterOp.equals:
        return ('$quoted::text = @$paramName', {paramName: value});
      case DbFilterOp.notEquals:
        return ('$quoted::text <> @$paramName', {paramName: value});
      case DbFilterOp.greater:
        return ('$quoted > @$paramName', {paramName: value});
      case DbFilterOp.less:
        return ('$quoted < @$paramName', {paramName: value});
      case DbFilterOp.greaterEqual:
        return ('$quoted >= @$paramName', {paramName: value});
      case DbFilterOp.lessEqual:
        return ('$quoted <= @$paramName', {paramName: value});
    }
  }

  DbColumnFilter copyWith({DbFilterOp? op, String? value}) => DbColumnFilter(
    column: column,
    op: op ?? this.op,
    value: value ?? this.value,
  );

  Map<String, dynamic> toJson() => {
    'column': column,
    'op': op.name,
    if (value.isNotEmpty) 'value': value,
  };

  factory DbColumnFilter.fromJson(Map<String, dynamic> json) => DbColumnFilter(
    column: json['column'] as String? ?? '',
    op: DbFilterOp.values.firstWhere(
      (e) => e.name == json['op'],
      orElse: () => DbFilterOp.equals,
    ),
    value: json['value'] as String? ?? '',
  );
}

/// 把多个列过滤合成 WHERE 子句(AND 连接)+ 参数
(String, Map<String, Object?>) buildWhere(List<DbColumnFilter> filters) {
  if (filters.isEmpty) return ('', const {});
  final clauses = <String>[];
  final params = <String, Object?>{};
  for (var i = 0; i < filters.length; i++) {
    final (frag, p) = filters[i].toSqlFragment('cf$i');
    clauses.add('($frag)');
    params.addAll(p);
  }
  return (clauses.join(' AND '), params);
}

/// 累积编辑缓冲(dbeaver 式:改动先攒着,统一提交/回滚)
/// - editedCells: 原始行下标 → 列下标 → 新值(含设为 null)
/// - addedRows: 新增行(长度 = 列数,以 [unsetValue] 表示未填,提交时用列默认值)
/// - removedRows: 标记删除的原始行下标
class DbEditSession {
  DbEditSession({
    Map<int, Map<int, Object?>>? editedCells,
    List<List<Object?>>? addedRows,
    Set<int>? removedRows,
  }) : editedCells = editedCells ?? {},
       addedRows = addedRows ?? [],
       removedRows = removedRows ?? {};

  /// 新增行里"未设置"的哨兵值(区别于显式 NULL)
  static const Object unsetValue = Object();

  final Map<int, Map<int, Object?>> editedCells;
  final List<List<Object?>> addedRows;
  final Set<int> removedRows;

  bool get isDirty =>
      editedCells.isNotEmpty || addedRows.isNotEmpty || removedRows.isNotEmpty;

  int get changeCount {
    var count = addedRows.length + removedRows.length;
    for (final cols in editedCells.values) {
      count += cols.length;
    }
    return count;
  }

  bool isRowRemoved(int rowIndex) => removedRows.contains(rowIndex);

  bool isCellEdited(int rowIndex, int colIndex) =>
      editedCells[rowIndex]?.containsKey(colIndex) ?? false;

  /// 单元格的展示值:优先取编辑后的值,否则原值
  Object? displayValue(int rowIndex, int colIndex, Object? original) {
    final edited = editedCells[rowIndex];
    if (edited != null && edited.containsKey(colIndex)) {
      return edited[colIndex];
    }
    return original;
  }

  DbEditSession clone() => DbEditSession(
    editedCells: {
      for (final e in editedCells.entries) e.key: Map.of(e.value),
    },
    addedRows: [for (final r in addedRows) List.of(r)],
    removedRows: Set.of(removedRows),
  );
}

/// 一次查询的结果(表数据浏览与 SQL 编辑器共用)
class DbQueryOutput {
  const DbQueryOutput({
    this.columns = const [],
    this.rows = const [],
    this.affectedRows = 0,
    this.elapsed = Duration.zero,
  });

  final List<String> columns;
  final List<List<Object?>> rows;
  final int affectedRows;
  final Duration elapsed;

  bool get hasRows => columns.isNotEmpty;

  /// 返回替换了指定单元格的新结果(单元格编辑后就地回填用)
  DbQueryOutput withCell(int rowIndex, int columnIndex, Object? value) {
    return DbQueryOutput(
      columns: columns,
      rows: [
        for (var r = 0; r < rows.length; r++)
          r == rowIndex
              ? [
                  for (var c = 0; c < rows[r].length; c++)
                    c == columnIndex ? value : rows[r][c],
                ]
              : rows[r],
      ],
      affectedRows: affectedRows,
      elapsed: elapsed,
    );
  }

  /// 导出为 CSV 文本(RFC 4180:含逗号/引号/换行的字段用双引号包裹)
  String toCsv() {
    String escape(Object? value) {
      if (value == null) return '';
      final text = value is DateTime ? value.toIso8601String() : '$value';
      if (text.contains(',') ||
          text.contains('"') ||
          text.contains('\n') ||
          text.contains('\r')) {
        return '"${text.replaceAll('"', '""')}"';
      }
      return text;
    }

    final buffer = StringBuffer()..writeln(columns.map(escape).join(','));
    for (final row in rows) {
      buffer.writeln(row.map(escape).join(','));
    }
    return buffer.toString();
  }
}
