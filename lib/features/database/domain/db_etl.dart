import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:termora/core/l10n/app_l10n.dart';
import 'package:termora/features/database/domain/db_migration.dart';
import 'package:termora/features/database/domain/db_models.dart';

/// ETL 值转换(在 Dart 层逐批应用,与引擎无关)
enum DbEtlTransform {
  none('原样'),
  trim('去空白'),
  upper('转大写'),
  lower('转小写'),
  mask('打码脱敏'),
  hash('哈希脱敏 (SHA-256)'),
  fixed('固定值'),
  nullify('置空');

  const DbEtlTransform(this.labelZh);

  final String labelZh;

  String get label => AppL10n.tr(labelZh);

  /// 输出恒为文本 → 目标列类型需要改成 text
  bool get forcesText =>
      this == mask || this == hash || this == fixed;

  /// 是否需要参数(mask: "头,尾" 保留位数;fixed: 常量)
  bool get needsParam => this == mask || this == fixed;
}

/// 单列的 ETL 规则
class DbEtlColumnRule {
  const DbEtlColumnRule({
    required this.column,
    this.include = true,
    this.rename,
    this.transform = DbEtlTransform.none,
    this.param = '',
  });

  /// 源列名
  final String column;

  /// false = 该列不迁移/不导出
  final bool include;

  /// 目标列名(空 = 不改名)
  final String? rename;

  final DbEtlTransform transform;

  /// mask: "保留头,保留尾"(默认 1,1);fixed: 常量值
  final String param;

  String get targetName =>
      (rename == null || rename!.trim().isEmpty) ? column : rename!.trim();

  bool get isPassthrough =>
      include && targetName == column && transform == DbEtlTransform.none;

  DbEtlColumnRule copyWith({
    bool? include,
    String? rename,
    DbEtlTransform? transform,
    String? param,
  }) {
    return DbEtlColumnRule(
      column: column,
      include: include ?? this.include,
      rename: rename ?? this.rename,
      transform: transform ?? this.transform,
      param: param ?? this.param,
    );
  }

  /// 对单个值应用转换
  Object? apply(Object? value) {
    switch (transform) {
      case DbEtlTransform.none:
        return value;
      case DbEtlTransform.trim:
        return value is String ? value.trim() : value;
      case DbEtlTransform.upper:
        return value is String ? value.toUpperCase() : value;
      case DbEtlTransform.lower:
        return value is String ? value.toLowerCase() : value;
      case DbEtlTransform.nullify:
        return null;
      case DbEtlTransform.fixed:
        return param;
      case DbEtlTransform.hash:
        if (value == null) return null;
        return sha256.convert(utf8.encode('$value')).toString();
      case DbEtlTransform.mask:
        if (value == null) return null;
        return _mask('$value');
    }
  }

  Map<String, dynamic> toJson() => {
    'column': column,
    if (!include) 'include': false,
    if (rename != null && rename!.isNotEmpty) 'rename': rename,
    if (transform != DbEtlTransform.none) 'transform': transform.name,
    if (param.isNotEmpty) 'param': param,
  };

  factory DbEtlColumnRule.fromJson(Map<String, dynamic> json) =>
      DbEtlColumnRule(
        column: json['column'] as String? ?? '',
        include: json['include'] as bool? ?? true,
        rename: json['rename'] as String?,
        transform: DbEtlTransform.values.firstWhere(
          (e) => e.name == json['transform'],
          orElse: () => DbEtlTransform.none,
        ),
        param: json['param'] as String? ?? '',
      );

  /// 打码:保留头尾各 N 位(param "头,尾",默认 1,1),中间全部替换为 *
  String _mask(String text) {
    var keepStart = 1;
    var keepEnd = 1;
    final parts = param.split(',');
    if (parts.isNotEmpty) {
      keepStart = int.tryParse(parts[0].trim()) ?? 1;
    }
    if (parts.length > 1) {
      keepEnd = int.tryParse(parts[1].trim()) ?? 1;
    }
    final chars = text.runes.toList();
    if (chars.length <= keepStart + keepEnd) {
      return '*' * chars.length;
    }
    final head = String.fromCharCodes(chars.take(keepStart));
    final tail = String.fromCharCodes(chars.skip(chars.length - keepEnd));
    return '$head${'*' * (chars.length - keepStart - keepEnd)}$tail';
  }
}

/// 单表的 ETL 规则:行过滤(推给源库执行)+ 目标表改名 + 列级规则
class DbEtlTableRule {
  const DbEtlTableRule({
    required this.table,
    this.targetTable,
    this.rowFilters = const [],
    this.columns = const {},
  });

  /// 源表名
  final String table;

  /// 目标表名(空 = 同名)
  final String? targetTable;

  /// 行过滤条件(复用列过滤,由各引擎 service 转成对应 WHERE)
  final List<DbColumnFilter> rowFilters;

  /// 源列名 → 列规则(未列出的列原样通过)
  final Map<String, DbEtlColumnRule> columns;

  String get targetTableName =>
      (targetTable == null || targetTable!.trim().isEmpty)
      ? table
      : targetTable!.trim();

  /// 规则是否等价于"什么都不做"(UI 用来决定是否显示 ETL 徽标/丢弃空规则)
  bool get isPassthrough =>
      targetTableName == table &&
      rowFilters.isEmpty &&
      columns.values.every((c) => c.isPassthrough);

  Map<String, dynamic> toJson() => {
    'table': table,
    if (targetTable != null && targetTable!.isNotEmpty)
      'targetTable': targetTable,
    if (rowFilters.isNotEmpty)
      'rowFilters': [for (final f in rowFilters) f.toJson()],
    if (columns.isNotEmpty)
      'columns': {
        for (final e in columns.entries) e.key: e.value.toJson(),
      },
  };

  factory DbEtlTableRule.fromJson(Map<String, dynamic> json) => DbEtlTableRule(
    table: json['table'] as String? ?? '',
    targetTable: json['targetTable'] as String?,
    rowFilters: [
      for (final f in (json['rowFilters'] as List<dynamic>? ?? []))
        DbColumnFilter.fromJson(f as Map<String, dynamic>),
    ],
    columns: {
      for (final e in (json['columns'] as Map<String, dynamic>? ?? {}).entries)
        e.key: DbEtlColumnRule.fromJson(e.value as Map<String, dynamic>),
    },
  );

  DbEtlColumnRule _ruleFor(String column) =>
      columns[column] ?? DbEtlColumnRule(column: column);

  /// 应用到迁移列(DDL):剔除排除列、改名、转换后强制文本的列改 text 类型
  List<DbMigrationColumn> applyToColumns(
    DbEngine source,
    List<DbMigrationColumn> sourceColumns,
  ) {
    final result = <DbMigrationColumn>[];
    for (final c in sourceColumns) {
      final rule = _ruleFor(c.name);
      if (!rule.include) continue;
      if (rule.transform.forcesText) {
        result.add(
          DbMigrationColumn(
            name: rule.targetName,
            // 同引擎迁移沿用 sourceType,这里一并换成源引擎的文本类型
            sourceType: source == DbEngine.clickhouse ? 'String' : 'text',
            generic: DbGenericType.text,
            nullable:
                c.nullable || rule.transform == DbEtlTransform.nullify,
            isPrimaryKey: c.isPrimaryKey,
          ),
        );
      } else {
        result.add(
          DbMigrationColumn(
            name: rule.targetName,
            sourceType: c.sourceType,
            generic: c.generic,
            nullable:
                c.nullable || rule.transform == DbEtlTransform.nullify,
            isPrimaryKey: c.isPrimaryKey,
          ),
        );
      }
    }
    return result;
  }

  /// 应用到一批数据:返回(目标列名, 转换后的行)
  (List<String>, List<List<Object?>>) applyToBatch(
    List<String> sourceColumns,
    List<List<Object?>> rows,
  ) {
    // 先算一次列映射,避免每行查表
    final keptIndexes = <int>[];
    final rules = <DbEtlColumnRule>[];
    final outColumns = <String>[];
    for (var i = 0; i < sourceColumns.length; i++) {
      final rule = _ruleFor(sourceColumns[i]);
      if (!rule.include) continue;
      keptIndexes.add(i);
      rules.add(rule);
      outColumns.add(rule.targetName);
    }

    final outRows = <List<Object?>>[
      for (final row in rows)
        [
          for (var k = 0; k < keptIndexes.length; k++)
            rules[k].apply(row[keptIndexes[k]]),
        ],
    ];
    return (outColumns, outRows);
  }
}
