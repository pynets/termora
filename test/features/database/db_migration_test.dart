// DbMigration 纯逻辑测试:类型映射 / 字面量转义 / DDL / INSERT 生成
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:termora/features/database/domain/db_migration.dart';
import 'package:termora/features/database/domain/db_models.dart';

void main() {
  group('mapToGeneric', () {
    test('postgres 类型归一', () {
      expect(
        DbMigration.mapToGeneric(DbEngine.postgres, 'integer'),
        DbGenericType.integer,
      );
      expect(
        DbMigration.mapToGeneric(DbEngine.postgres, 'bigint'),
        DbGenericType.bigint,
      );
      expect(
        DbMigration.mapToGeneric(DbEngine.postgres, 'character varying(255)'),
        DbGenericType.text,
      );
      expect(
        DbMigration.mapToGeneric(
          DbEngine.postgres,
          'timestamp with time zone',
        ),
        DbGenericType.datetime,
      );
      expect(
        DbMigration.mapToGeneric(DbEngine.postgres, 'numeric(10,2)'),
        DbGenericType.decimal,
      );
      expect(
        DbMigration.mapToGeneric(DbEngine.postgres, 'jsonb'),
        DbGenericType.json,
      );
      expect(
        DbMigration.mapToGeneric(DbEngine.postgres, 'uuid'),
        DbGenericType.uuid,
      );
      expect(
        DbMigration.mapToGeneric(DbEngine.postgres, 'bytea'),
        DbGenericType.blob,
      );
    });

    test('clickhouse 类型归一(剥 Nullable/LowCardinality 壳)', () {
      expect(
        DbMigration.mapToGeneric(DbEngine.clickhouse, 'Nullable(Int64)'),
        DbGenericType.bigint,
      );
      expect(
        DbMigration.mapToGeneric(
          DbEngine.clickhouse,
          'LowCardinality(Nullable(String))',
        ),
        DbGenericType.text,
      );
      expect(
        DbMigration.mapToGeneric(DbEngine.clickhouse, 'UInt8'),
        DbGenericType.integer,
      );
      expect(
        DbMigration.mapToGeneric(DbEngine.clickhouse, 'DateTime64(3)'),
        DbGenericType.datetime,
      );
      expect(
        DbMigration.mapToGeneric(DbEngine.clickhouse, 'Array(String)'),
        DbGenericType.json,
      );
    });

    test('sqlite 亲和性归一', () {
      expect(
        DbMigration.mapToGeneric(DbEngine.sqlite, 'INTEGER'),
        DbGenericType.bigint,
      );
      expect(
        DbMigration.mapToGeneric(DbEngine.sqlite, 'VARCHAR(80)'),
        DbGenericType.text,
      );
      expect(
        DbMigration.mapToGeneric(DbEngine.sqlite, 'REAL'),
        DbGenericType.double_,
      );
      expect(
        DbMigration.mapToGeneric(DbEngine.sqlite, 'BLOB'),
        DbGenericType.blob,
      );
    });
  });

  group('literal', () {
    test('基础值', () {
      expect(DbMigration.literal(DbEngine.postgres, null), 'NULL');
      expect(DbMigration.literal(DbEngine.postgres, 42), '42');
      expect(DbMigration.literal(DbEngine.postgres, true), 'TRUE');
      expect(DbMigration.literal(DbEngine.sqlite, true), '1');
      expect(DbMigration.literal(DbEngine.clickhouse, false), '0');
    });

    test('字符串转义:单引号双写,CH 反斜杠双写', () {
      expect(DbMigration.literal(DbEngine.postgres, "it's"), "'it''s'");
      expect(DbMigration.literal(DbEngine.postgres, r'a\b'), r"'a\b'");
      expect(DbMigration.literal(DbEngine.clickhouse, r'a\b'), r"'a\\b'");
    });

    test('时间:CH 去掉 T 分隔', () {
      final dt = DateTime.utc(2026, 7, 11, 8, 30, 5);
      expect(
        DbMigration.literal(DbEngine.postgres, dt),
        "'2026-07-11T08:30:05.000Z'",
      );
      expect(
        DbMigration.literal(DbEngine.clickhouse, dt),
        "'2026-07-11 08:30:05.000'",
      );
    });

    test('二进制:各引擎 hex 形态', () {
      final bytes = Uint8List.fromList([0xde, 0xad]);
      expect(DbMigration.literal(DbEngine.postgres, bytes), r"'\xdead'");
      expect(DbMigration.literal(DbEngine.sqlite, bytes), "X'dead'");
      expect(
        DbMigration.literal(DbEngine.clickhouse, bytes),
        "unhex('dead')",
      );
    });

    test('json 对象序列化为文本', () {
      expect(
        DbMigration.literal(DbEngine.postgres, {'a': 1}),
        '\'{"a":1}\'',
      );
    });

    test('pg 数组列:List → {…} 数组字面量(修 22P02)', () {
      // 空数组:JSON 的 '[]' 会报 malformed array literal,必须是 '{}'
      expect(
        DbMigration.literal(DbEngine.postgres, [], columnType: 'text[]'),
        "'{}'",
      );
      expect(
        DbMigration.literal(
          DbEngine.postgres,
          ['a', 'b'],
          columnType: 'text[]',
        ),
        '\'{"a","b"}\'',
      );
      // 元素转义:双引号/反斜杠;单引号按 SQL 规则双写;NULL 元素
      expect(
        DbMigration.literal(
          DbEngine.postgres,
          ['x "q"', r'a\b', "it's", null],
          columnType: 'text[]',
        ),
        '\'{"x \\"q\\"","a\\\\b","it\'\'s",NULL}\'',
      );
      // 数字数组 + 多维
      expect(
        DbMigration.literal(DbEngine.postgres, [1, 2], columnType: 'integer[]'),
        '\'{"1","2"}\'',
      );
      expect(
        DbMigration.literal(
          DbEngine.postgres,
          [
            [1, 2],
            [3, 4],
          ],
          columnType: 'integer[]',
        ),
        '\'{{"1","2"},{"3","4"}}\'',
      );
      // 没有列类型 / jsonb 列:保持 JSON 文本
      expect(DbMigration.literal(DbEngine.postgres, ['a']), '\'["a"]\'');
      expect(
        DbMigration.literal(DbEngine.postgres, ['a'], columnType: 'jsonb'),
        '\'["a"]\'',
      );
      // 非 pg 目标不受影响
      expect(
        DbMigration.literal(DbEngine.sqlite, ['a'], columnType: 'TEXT'),
        '\'["a"]\'',
      );
    });

    test('PostGIS geometry:字节值 → 无前缀 hex EWKB(修 invalid geometry hint)', () {
      final wkb = [0x01, 0x01, 0x00, 0x00, 0x20, 0xe6, 0x10];
      // geometry/geography 列:hex 无 \x 前缀
      expect(
        DbMigration.literal(
          DbEngine.postgres,
          wkb,
          columnType: 'geometry(Point,4326)',
        ),
        "'01010000%s'".replaceAll('%s', '20e610'),
      );
      expect(
        DbMigration.literal(DbEngine.postgres, wkb, columnType: 'geography'),
        "'0101000020e610'",
      );
      // bytea 列不受影响,仍是 \x 前缀
      expect(
        DbMigration.literal(DbEngine.postgres, wkb, columnType: 'bytea'),
        r"'\x0101000020e610'",
      );
      expect(DbMigration.isGeoType('geometry(Point,4326)'), isTrue);
      expect(DbMigration.isGeoType('geography(Point,4326)'), isTrue);
      expect(DbMigration.isGeoType('bytea'), isFalse);
      expect(DbMigration.isGeoType(null), isFalse);
    });

    test('pg 数组类型跨引擎归一为 json', () {
      expect(
        DbMigration.mapToGeneric(DbEngine.postgres, 'text[]'),
        DbGenericType.json,
      );
      expect(
        DbMigration.mapToGeneric(DbEngine.postgres, 'integer[]'),
        DbGenericType.json,
      );
    });
  });

  group('buildCreateTable', () {
    const columns = [
      DbMigrationColumn(
        name: 'id',
        sourceType: 'bigint',
        generic: DbGenericType.bigint,
        nullable: false,
        isPrimaryKey: true,
      ),
      DbMigrationColumn(
        name: 'note',
        sourceType: 'text',
        generic: DbGenericType.text,
        nullable: true,
        isPrimaryKey: false,
      ),
    ];

    test('pg → sqlite:类型映射 + 主键 + DROP', () {
      final statements = DbMigration.buildCreateTable(
        DbEngine.postgres,
        DbEngine.sqlite,
        'events',
        columns,
      );
      expect(statements.first, 'DROP TABLE IF EXISTS "events"');
      expect(statements[1], contains('"id" INTEGER NOT NULL'));
      expect(statements[1], contains('"note" TEXT'));
      expect(statements[1], contains('PRIMARY KEY ("id")'));
    });

    test('同引擎沿用原始类型', () {
      final statements = DbMigration.buildCreateTable(
        DbEngine.postgres,
        DbEngine.postgres,
        'events',
        columns,
        drop: false,
      );
      expect(statements, hasLength(1));
      expect(statements.first, contains('"id" bigint NOT NULL'));
    });

    test('→ clickhouse:Nullable 包装 + MergeTree 排序键', () {
      final statements = DbMigration.buildCreateTable(
        DbEngine.postgres,
        DbEngine.clickhouse,
        'events',
        columns,
      );
      final create = statements[1];
      expect(create, contains('`id` Int64'));
      expect(create, isNot(contains('`id` Nullable')));
      expect(create, contains('`note` Nullable(String)'));
      expect(create, contains('ENGINE = MergeTree ORDER BY (`id`)'));
    });

    test('ch → ch:已是 Nullable 的原始类型不再包一层', () {
      final statements = DbMigration.buildCreateTable(
        DbEngine.clickhouse,
        DbEngine.clickhouse,
        't',
        [
          const DbMigrationColumn(
            name: 'tag',
            sourceType: 'Nullable(String)',
            generic: DbGenericType.text,
            nullable: true,
            isPrimaryKey: false,
          ),
        ],
      );
      expect(statements[1], contains('`tag` Nullable(String)'));
      expect(statements[1], isNot(contains('Nullable(Nullable')));
    });

    test('→ clickhouse 无主键:ORDER BY tuple()', () {
      final statements = DbMigration.buildCreateTable(
        DbEngine.sqlite,
        DbEngine.clickhouse,
        't',
        [
          const DbMigrationColumn(
            name: 'v',
            sourceType: 'TEXT',
            generic: DbGenericType.text,
            nullable: true,
            isPrimaryKey: false,
          ),
        ],
      );
      expect(statements[1], contains('ORDER BY tuple()'));
    });
  });

  group('整库 · schema 限定', () {
    test('buildCreateSchema:各引擎', () {
      expect(
        DbMigration.buildCreateSchema(DbEngine.postgres, 'app'),
        'CREATE SCHEMA IF NOT EXISTS "app"',
      );
      expect(
        DbMigration.buildCreateSchema(DbEngine.clickhouse, 'app'),
        'CREATE DATABASE IF NOT EXISTS `app`',
      );
      expect(DbMigration.buildCreateSchema(DbEngine.sqlite, 'app'), isNull);
    });

    test('qualified:带/不带 schema', () {
      expect(DbMigration.qualified(DbEngine.postgres, null, 't'), '"t"');
      expect(
        DbMigration.qualified(DbEngine.postgres, 'app', 't'),
        '"app"."t"',
      );
      expect(
        DbMigration.qualified(DbEngine.clickhouse, 'app', 't'),
        '`app`.`t`',
      );
    });

    test('buildCreateTable / buildInsert 带 schema 前缀', () {
      const cols = [
        DbMigrationColumn(
          name: 'id',
          sourceType: 'bigint',
          generic: DbGenericType.bigint,
          nullable: false,
          isPrimaryKey: true,
        ),
      ];
      final ddl = DbMigration.buildCreateTable(
        DbEngine.postgres,
        DbEngine.postgres,
        'events',
        cols,
        schema: 'app',
      );
      expect(ddl.first, 'DROP TABLE IF EXISTS "app"."events"');
      expect(ddl[1], contains('CREATE TABLE "app"."events"'));

      final insert = DbMigration.buildInsert(
        DbEngine.postgres,
        'events',
        ['id'],
        [
          [1],
        ],
        schema: 'app',
      );
      expect(insert, contains('INSERT INTO "app"."events"'));
    });
  });

  test('buildInsert:多行 + 转义', () {
    final sql = DbMigration.buildInsert(
      DbEngine.postgres,
      'users',
      ['id', 'name'],
      [
        [1, "o'neil"],
        [2, null],
      ],
    );
    expect(sql, contains('INSERT INTO "users" ("id", "name") VALUES'));
    expect(sql, contains("(1, 'o''neil')"));
    expect(sql, contains('(2, NULL)'));
  });
}
