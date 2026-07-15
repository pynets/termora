import 'dart:convert';
import 'dart:typed_data';

import 'package:termora/features/database/domain/db_models.dart';

/// Termora 便携归档(.tdump)的纯编解码逻辑。
///
/// 归档 = gzip 压缩的「一行一条 JSON」(JSONL),由 [DbTransferService] 负责
/// 落盘/读盘,本类只管 record ⇄ JSON 的结构与「非 JSON 原生值」的标记编码。
///
/// 记录种类:
/// - 第一行 manifest:`{format,version,createdAt,source,schemas,tableCount}`
/// - 每张表一条 table 头:结构(列/索引/约束/注释)+ 源引擎
/// - 若干条 rows 批:该表的一批行(列名 + 值矩阵),值经 [encodeValue] 标记
///
/// 设计要点:归档「引擎中立」——只存源结构与原始规范化值,类型映射/生成列剔除/
/// 序列复位等目标相关处理留到导入时(目标引擎此刻才确定),从而一份归档可导入任意引擎。
class DbDumpCodec {
  DbDumpCodec._();

  static const String format = 'termora-dump';
  static const int version = 1;

  /// 非 JSON 原生值的标记键(取足够罕见的名字,避免与 jsonb 键冲突)
  static const String _tagKey = '__td_t';
  static const String _tagVal = '__td_v';

  // ── manifest ──

  static Map<String, Object?> manifest({
    required String createdAtIso,
    required String sourceEngineName,
    required String sourceName,
    required String sourceDatabase,
    required List<String> schemas,
    required int tableCount,
  }) => {
    'format': format,
    'version': version,
    'createdAt': createdAtIso,
    'source': {
      'engine': sourceEngineName,
      'name': sourceName,
      'database': sourceDatabase,
    },
    'schemas': schemas,
    'tableCount': tableCount,
  };

  /// 校验 manifest 是否为可识别的归档;不是则抛 [FormatException]
  static void validateManifest(Map<String, dynamic> m) {
    if (m['format'] != format) {
      throw const FormatException('不是 Termora 归档文件(format 不匹配)');
    }
    final v = (m['version'] as num?)?.toInt() ?? 0;
    if (v > version) {
      throw FormatException('归档版本 $v 高于当前支持的 $version,请升级 Termora');
    }
  }

  static List<String> manifestSchemas(Map<String, dynamic> m) => [
    for (final s in (m['schemas'] as List<dynamic>? ?? const [])) s as String,
  ];

  static String manifestSourceEngine(Map<String, dynamic> m) =>
      (m['source'] as Map<String, dynamic>?)?['engine'] as String? ??
      'postgres';

  // ── table 头 ──

  static Map<String, Object?> tableHeader({
    required int index,
    required String sourceEngineName,
    required String schema,
    required String table,
    required DbTableStructure structure,
  }) => {
    'kind': 'table',
    'index': index,
    'engine': sourceEngineName,
    'schema': schema,
    'table': table,
    if (structure.comment != null) 'comment': structure.comment,
    'approxRows': structure.approxRows,
    'totalBytes': structure.totalBytes,
    'columns': [for (final c in structure.columns) _columnToJson(c)],
    'indexes': [
      for (final i in structure.indexes) {'name': i.name, 'def': i.definition},
    ],
    'constraints': [
      for (final c in structure.constraints) _constraintToJson(c),
    ],
  };

  /// 从 table 头还原结构(导入时喂给迁移管线)
  static DbTableStructure structureFromJson(Map<String, dynamic> j) {
    return DbTableStructure(
      comment: j['comment'] as String?,
      approxRows: (j['approxRows'] as num?)?.toInt() ?? 0,
      totalBytes: (j['totalBytes'] as num?)?.toInt() ?? 0,
      columns: [
        for (final c in (j['columns'] as List<dynamic>? ?? const []))
          _columnFromJson(c as Map<String, dynamic>),
      ],
      indexes: [
        for (final i in (j['indexes'] as List<dynamic>? ?? const []))
          DbIndexInfo(
            name: (i as Map<String, dynamic>)['name'] as String? ?? '',
            definition: i['def'] as String? ?? '',
          ),
      ],
      constraints: [
        for (final c in (j['constraints'] as List<dynamic>? ?? const []))
          _constraintFromJson(c as Map<String, dynamic>),
      ],
    );
  }

  static Map<String, Object?> _columnToJson(DbColumnInfo c) => {
    'name': c.name,
    'type': c.dataType,
    'nullable': c.nullable,
    if (c.defaultValue != null) 'default': c.defaultValue,
    if (c.isPrimaryKey) 'pk': true,
    if (c.comment != null) 'comment': c.comment,
    if (c.isGenerated) 'generated': true,
    if (c.isIdentity) 'identity': true,
  };

  static DbColumnInfo _columnFromJson(Map<String, dynamic> j) => DbColumnInfo(
    name: j['name'] as String? ?? '',
    dataType: j['type'] as String? ?? 'text',
    nullable: j['nullable'] as bool? ?? true,
    defaultValue: j['default'] as String?,
    isPrimaryKey: j['pk'] as bool? ?? false,
    comment: j['comment'] as String?,
    isGenerated: j['generated'] as bool? ?? false,
    isIdentity: j['identity'] as bool? ?? false,
  );

  static Map<String, Object?> _constraintToJson(DbConstraintInfo c) => {
    'name': c.name,
    'type': c.type.name,
    'def': c.definition,
    if (c.refSchema != null) 'refSchema': c.refSchema,
    if (c.refTable != null) 'refTable': c.refTable,
  };

  static DbConstraintInfo _constraintFromJson(Map<String, dynamic> j) =>
      DbConstraintInfo(
        name: j['name'] as String? ?? '',
        type: DbConstraintType.values.firstWhere(
          (e) => e.name == j['type'],
          orElse: () => DbConstraintType.check,
        ),
        definition: j['def'] as String? ?? '',
        refSchema: j['refSchema'] as String?,
        refTable: j['refTable'] as String?,
      );

  // ── rows 批 ──

  static Map<String, Object?> rowsBatch({
    required int index,
    required List<String> columns,
    required List<List<Object?>> rows,
  }) => {
    'kind': 'rows',
    'index': index,
    'cols': columns,
    'rows': [
      for (final row in rows) [for (final v in row) encodeValue(v)],
    ],
  };

  static List<String> rowsColumns(Map<String, dynamic> j) => [
    for (final c in (j['cols'] as List<dynamic>? ?? const [])) c as String,
  ];

  static List<List<Object?>> rowsValues(Map<String, dynamic> j) => [
    for (final row in (j['rows'] as List<dynamic>? ?? const []))
      [for (final v in (row as List<dynamic>)) decodeValue(v)],
  ];

  // ── 值编码(JSON 安全 + 类型标记)──

  /// 把一个单元格值编码成 JSON 安全形态。
  /// null/num/bool/String 原样;DateTime/字节串加标记;List/Map 递归。
  static Object? encodeValue(Object? v) {
    if (v == null || v is num || v is bool || v is String) return v;
    if (v is DateTime) {
      return {_tagKey: 'd', _tagVal: v.toIso8601String()};
    }
    if (v is Uint8List) {
      return {_tagKey: 'b', _tagVal: base64Encode(v)};
    }
    if (v is Map) {
      return {for (final e in v.entries) '${e.key}': encodeValue(e.value)};
    }
    if (v is List) {
      // Uint8List 已在上面拦截;此处是真正的数组(如 pg int[]/text[])
      return [for (final e in v) encodeValue(e)];
    }
    // 其它驱动类型(理论上读取层已规范化):退化为字符串
    return v.toString();
  }

  static Object? decodeValue(Object? v) {
    if (v is Map) {
      final tag = v[_tagKey];
      if (tag is String) {
        final raw = v[_tagVal];
        switch (tag) {
          case 'd':
            return DateTime.parse(raw as String);
          case 'b':
            return base64Decode(raw as String);
        }
      }
      return {for (final e in v.entries) '${e.key}': decodeValue(e.value)};
    }
    if (v is List) return [for (final e in v) decodeValue(e)];
    return v;
  }
}
