import 'dart:convert';
import 'dart:typed_data';

import 'package:termora/features/database/domain/db_models.dart';

/// 跨引擎迁移的通用列类型 — 源引擎类型先归一到这里,再落成目标引擎类型。
/// 同引擎迁移不走归一,直接沿用源类型字符串,保真度最高。
enum DbGenericType {
  integer,
  bigint,
  double_,
  decimal,
  boolean,
  text,
  datetime,
  date,
  blob,
  json,
  uuid,
}

/// 迁移/导出用的列描述(结构 + 归一类型)
class DbMigrationColumn {
  const DbMigrationColumn({
    required this.name,
    required this.sourceType,
    required this.generic,
    required this.nullable,
    required this.isPrimaryKey,
  });

  final String name;

  /// 源引擎的原始类型字符串(同引擎迁移时直接使用)
  final String sourceType;
  final DbGenericType generic;
  final bool nullable;
  final bool isPrimaryKey;

  factory DbMigrationColumn.from(DbEngine source, DbColumnInfo info) {
    return DbMigrationColumn(
      name: info.name,
      sourceType: info.dataType,
      generic: DbMigration.mapToGeneric(source, info.dataType),
      nullable: info.nullable,
      isPrimaryKey: info.isPrimaryKey,
    );
  }
}

/// SQL 脚本/DDL/INSERT 生成(纯逻辑,便于测试)
class DbMigration {
  DbMigration._();

  // ══════════════ 类型映射 ══════════════

  /// 源引擎类型字符串 → 通用类型(尽力而为,未识别的落 text)
  static DbGenericType mapToGeneric(DbEngine source, String dataType) {
    var t = dataType.trim();
    // ClickHouse 包装类型剥壳:Nullable(...) / LowCardinality(...)
    for (;;) {
      final match = RegExp(
        r'^(Nullable|LowCardinality)\((.*)\)$',
      ).firstMatch(t);
      if (match == null) break;
      t = match.group(2)!.trim();
    }
    final lower = t.toLowerCase();

    switch (source) {
      case DbEngine.postgres:
        // 数组类型(text[] 等)跨引擎按 JSON 文本落地
        if (lower.endsWith('[]')) return DbGenericType.json;
        if (RegExp(r'^(smallint|int2|integer|int4|serial)').hasMatch(lower)) {
          return DbGenericType.integer;
        }
        if (RegExp(r'^(bigint|int8|bigserial)').hasMatch(lower)) {
          return DbGenericType.bigint;
        }
        if (RegExp(r'^(numeric|decimal|money)').hasMatch(lower)) {
          return DbGenericType.decimal;
        }
        if (RegExp(r'^(real|float4|double precision|float8)')
            .hasMatch(lower)) {
          return DbGenericType.double_;
        }
        if (lower.startsWith('bool')) return DbGenericType.boolean;
        if (lower.startsWith('timestamp')) return DbGenericType.datetime;
        if (lower == 'date') return DbGenericType.date;
        if (lower == 'bytea') return DbGenericType.blob;
        if (lower.startsWith('json')) return DbGenericType.json;
        if (lower == 'uuid') return DbGenericType.uuid;
        return DbGenericType.text;

      case DbEngine.clickhouse:
        if (RegExp(r'^(u?int(8|16|32))$', caseSensitive: false)
            .hasMatch(lower)) {
          return DbGenericType.integer;
        }
        if (RegExp(r'^(u?int(64|128|256))$', caseSensitive: false)
            .hasMatch(lower)) {
          return DbGenericType.bigint;
        }
        if (lower.startsWith('float')) return DbGenericType.double_;
        if (lower.startsWith('decimal')) return DbGenericType.decimal;
        if (lower == 'bool' || lower == 'boolean') {
          return DbGenericType.boolean;
        }
        if (lower.startsWith('datetime')) return DbGenericType.datetime;
        if (lower.startsWith('date')) return DbGenericType.date;
        if (lower == 'uuid') return DbGenericType.uuid;
        if (RegExp(r'^(array|map|tuple|json)').hasMatch(lower)) {
          return DbGenericType.json;
        }
        return DbGenericType.text; // String / FixedString / Enum / IP…

      case DbEngine.sqlite:
        // SQLite 类型亲和性规则(简化)
        if (lower.contains('int')) return DbGenericType.bigint;
        if (lower.contains('char') ||
            lower.contains('clob') ||
            lower.contains('text')) {
          return DbGenericType.text;
        }
        if (lower.contains('blob')) return DbGenericType.blob;
        if (lower.contains('real') ||
            lower.contains('floa') ||
            lower.contains('doub')) {
          return DbGenericType.double_;
        }
        if (lower.contains('bool')) return DbGenericType.boolean;
        if (lower.contains('date') || lower.contains('time')) {
          return DbGenericType.datetime;
        }
        if (lower.contains('num') || lower.contains('dec')) {
          return DbGenericType.decimal;
        }
        return DbGenericType.text;
    }
  }

  /// 通用类型 → 目标引擎类型字符串
  static String typeFor(DbEngine target, DbGenericType type) {
    switch (target) {
      case DbEngine.postgres:
        return switch (type) {
          DbGenericType.integer => 'integer',
          DbGenericType.bigint => 'bigint',
          DbGenericType.double_ => 'double precision',
          DbGenericType.decimal => 'numeric',
          DbGenericType.boolean => 'boolean',
          DbGenericType.text => 'text',
          DbGenericType.datetime => 'timestamp',
          DbGenericType.date => 'date',
          DbGenericType.blob => 'bytea',
          DbGenericType.json => 'jsonb',
          DbGenericType.uuid => 'uuid',
        };
      case DbEngine.clickhouse:
        return switch (type) {
          DbGenericType.integer => 'Int32',
          DbGenericType.bigint => 'Int64',
          DbGenericType.double_ => 'Float64',
          DbGenericType.decimal => 'Decimal(38, 10)',
          DbGenericType.boolean => 'Bool',
          DbGenericType.text => 'String',
          DbGenericType.datetime => 'DateTime64(3)',
          DbGenericType.date => 'Date32',
          DbGenericType.blob => 'String',
          DbGenericType.json => 'String',
          DbGenericType.uuid => 'UUID',
        };
      case DbEngine.sqlite:
        return switch (type) {
          DbGenericType.integer || DbGenericType.bigint => 'INTEGER',
          DbGenericType.double_ => 'REAL',
          DbGenericType.decimal => 'NUMERIC',
          DbGenericType.boolean => 'INTEGER',
          DbGenericType.blob => 'BLOB',
          _ => 'TEXT',
        };
    }
  }

  /// 目标列类型:同引擎沿用原始类型,跨引擎走通用类型映射
  static String targetColumnType(
    DbEngine source,
    DbEngine target,
    DbMigrationColumn column,
  ) {
    if (source == target) return column.sourceType;
    return typeFor(target, column.generic);
  }

  // ══════════════ 标识符 / 字面量 ══════════════

  /// 目标引擎的标识符引用
  static String ident(DbEngine target, String name) => switch (target) {
    DbEngine.clickhouse => '`${name.replaceAll('`', r'\`')}`',
    _ => '"${name.replaceAll('"', '""')}"',
  };

  /// 表名(可选 schema 前缀)。[schema] 为 null → 落到目标默认库/schema。
  static String qualified(DbEngine target, String? schema, String table) =>
      schema == null
      ? ident(target, table)
      : '${ident(target, schema)}.${ident(target, table)}';

  /// 建 schema/库 语句(整库迁移保留源 schema 时用);
  /// 目标为 SQLite 无 schema 概念 → 返回 null。
  static String? buildCreateSchema(DbEngine target, String schema) =>
      switch (target) {
        DbEngine.postgres => 'CREATE SCHEMA IF NOT EXISTS ${ident(target, schema)}',
        DbEngine.clickhouse =>
          'CREATE DATABASE IF NOT EXISTS ${ident(target, schema)}',
        DbEngine.sqlite => null,
      };

  /// 值 → 目标引擎的 SQL 字面量。
  /// [columnType] 为目标列类型(可空):pg 数组列(`…[]`)的 List 值
  /// 需要生成 `'{…}'` 数组字面量而不是 JSON 文本。
  static String literal(
    DbEngine target,
    Object? value, {
    String? columnType,
  }) {
    // pg 数组列:List → '{…}' 数组字面量(空数组 '{}';JSON 的 '[]' 会报 22P02)
    if (value is List &&
        value is! Uint8List &&
        target == DbEngine.postgres &&
        (columnType?.trimRight().endsWith('[]') ?? false)) {
      final body = _pgArrayBody(value);
      return "'${body.replaceAll("'", "''")}'";
    }
    return _literal(target, value);
  }

  /// pg 数组字面量主体(递归支持多维):元素双引号包裹,转义 \ 和 "
  static String _pgArrayBody(List<dynamic> values) {
    String elem(Object? e) {
      if (e == null) return 'NULL';
      if (e is List) return _pgArrayBody(e);
      final text = e is DateTime ? e.toIso8601String() : '$e';
      return '"${text.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
    }

    return '{${values.map(elem).join(',')}}';
  }

  static String _literal(DbEngine target, Object? value) {
    if (value == null) return 'NULL';
    if (value is bool) {
      return target == DbEngine.postgres
          ? (value ? 'TRUE' : 'FALSE')
          : (value ? '1' : '0');
    }
    if (value is num) {
      if (value is double && (value.isNaN || value.isInfinite)) {
        return _string(target, '$value'); // pg 接受 'NaN'::float 语义的字符串
      }
      return '$value';
    }
    if (value is DateTime) {
      final iso = value.toIso8601String();
      // ClickHouse 的 DateTime 字面量不吃 'T' 分隔与时区后缀
      if (target == DbEngine.clickhouse) {
        final text = iso.replaceFirst('T', ' ').replaceFirst('Z', '');
        return _string(target, text);
      }
      return _string(target, iso);
    }
    if (value is Uint8List || value is List<int>) {
      final hex = [
        for (final b in (value as List).cast<int>())
          b.toRadixString(16).padLeft(2, '0'),
      ].join();
      return switch (target) {
        DbEngine.postgres => "'\\x$hex'",
        DbEngine.sqlite => "X'$hex'",
        DbEngine.clickhouse => "unhex('$hex')",
      };
    }
    // pg 的 json/jsonb 会解码成 Map/List,序列化回 JSON 文本
    if (value is Map || value is List) {
      return _string(target, jsonEncode(value));
    }
    return _string(target, '$value');
  }

  /// 字符串字面量(ClickHouse 里反斜杠是转义字符,需双写)
  static String _string(DbEngine target, String text) {
    var escaped = text;
    if (target == DbEngine.clickhouse) {
      escaped = escaped.replaceAll(r'\', r'\\');
    }
    return "'${escaped.replaceAll("'", "''")}'";
  }

  // ══════════════ DDL / INSERT 生成 ══════════════

  /// 建表语句。[schema] 为 null → 落到目标默认库/schema(单 schema 迁移);
  /// 非 null → 生成带 schema 前缀的限定名(整库迁移保留源 schema)。
  /// [drop] 为 true 时先输出 DROP TABLE IF EXISTS(覆盖式迁移)。
  static List<String> buildCreateTable(
    DbEngine source,
    DbEngine target,
    String table,
    List<DbMigrationColumn> columns, {
    bool drop = true,
    String? schema,
  }) {
    final t = qualified(target, schema, table);
    final pk = [
      for (final c in columns)
        if (c.isPrimaryKey) c,
    ];

    final defs = <String>[];
    for (final c in columns) {
      final type = targetColumnType(source, target, c);
      if (target == DbEngine.clickhouse) {
        // CH 用 Nullable() 包装表达可空;主键列(排序键)不允许 Nullable。
        // 同引擎迁移时原始类型可能已带 Nullable(...),不能再包一层。
        final wrapped =
            (c.nullable &&
                !c.isPrimaryKey &&
                !type.startsWith('Nullable('))
            ? 'Nullable($type)'
            : type;
        defs.add('  ${ident(target, c.name)} $wrapped');
      } else {
        final notNull = (!c.nullable || c.isPrimaryKey) ? ' NOT NULL' : '';
        defs.add('  ${ident(target, c.name)} $type$notNull');
      }
    }

    String tail;
    if (target == DbEngine.clickhouse) {
      final orderBy = pk.isEmpty
          ? 'tuple()'
          : '(${pk.map((c) => ident(target, c.name)).join(', ')})';
      tail = ') ENGINE = MergeTree ORDER BY $orderBy';
    } else {
      if (pk.isNotEmpty) {
        defs.add(
          '  PRIMARY KEY (${pk.map((c) => ident(target, c.name)).join(', ')})',
        );
      }
      tail = ')';
    }

    return [
      if (drop) 'DROP TABLE IF EXISTS $t',
      'CREATE TABLE $t (\n${defs.join(',\n')}\n$tail',
    ];
  }

  /// 一批行 → 一条多行 INSERT。[schema] 非 null 时用限定名;
  /// [columnTypes] 与 [columns] 一一对应(可空),数组列等需要类型感知的字面量。
  static String buildInsert(
    DbEngine target,
    String table,
    List<String> columns,
    List<List<Object?>> rows, {
    String? schema,
    List<String>? columnTypes,
  }) {
    final cols = columns.map((c) => ident(target, c)).join(', ');
    String? typeAt(int i) =>
        (columnTypes != null && i < columnTypes.length) ? columnTypes[i] : null;
    final values = [
      for (final row in rows)
        '(${[
          for (var i = 0; i < row.length; i++)
            literal(target, row[i], columnType: typeAt(i)),
        ].join(', ')})',
    ].join(',\n');
    return 'INSERT INTO ${qualified(target, schema, table)} ($cols) VALUES\n$values';
  }
}
