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

    test('pgvector:二进制 → [f1,f2,…] 文本(修 invalid input syntax)', () {
      // 二进制格式:uint16 维度(大端)+ uint16 保留 + dim × float32(大端)
      List<int> vec(List<double> values) {
        final data = ByteData(4 + values.length * 4)
          ..setUint16(0, values.length)
          ..setUint16(2, 0);
        for (var i = 0; i < values.length; i++) {
          data.setFloat32(4 + i * 4, values[i]);
        }
        return data.buffer.asUint8List();
      }

      expect(
        DbMigration.literal(
          DbEngine.postgres,
          vec([0.25, -1.5, 3.0]),
          columnType: 'vector(3)',
        ),
        "'[0.25,-1.5,3]'",
      );
      // float32 最短往返(不会打成 double 的 15+ 位)
      final one = DbMigration.literal(
        DbEngine.postgres,
        vec([0.1]),
        columnType: 'vector(1)',
      );
      expect(one, "'[0.1]'");

      // 长度对不上 → 回落默认 bytea 路径(不崩)
      expect(
        DbMigration.literal(
          DbEngine.postgres,
          [0x00, 0x03, 0x00, 0x00, 0x01],
          columnType: 'vector(3)',
        ),
        startsWith(r"'\x"),
      );
      // 无类型信息不受影响
      expect(
        DbMigration.literal(DbEngine.postgres, [0x00, 0x01]),
        startsWith(r"'\x"),
      );
      expect(DbMigration.isVectorType('vector(1024)'), isTrue);
      expect(DbMigration.isVectorType('halfvec(768)'), isTrue);
      expect(DbMigration.isVectorType('bytea'), isFalse);

      // halfvec:float16 解码(1.0 = 0x3C00,-2.0 = 0xC000)
      final halfData = ByteData(8)
        ..setUint16(0, 2)
        ..setUint16(2, 0)
        ..setUint16(4, 0x3C00)
        ..setUint16(6, 0xC000);
      expect(
        DbMigration.literal(
          DbEngine.postgres,
          halfData.buffer.asUint8List(),
          columnType: 'halfvec(2)',
        ),
        "'[1,-2]'",
      );

      // 扩展需求映射
      expect(DbMigration.requiredExtension('vector(1024)'), 'vector');
      expect(DbMigration.requiredExtension('geometry(Point,4326)'), 'postgis');
      expect(DbMigration.requiredExtension('text'), isNull);
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

  group('迁移保真:默认值 / 注释 / 索引', () {
    test('同引擎默认值原样;pg serial → IDENTITY(不带 nextval)', () {
      final ddl = DbMigration.buildCreateTable(
        DbEngine.postgres,
        DbEngine.postgres,
        't',
        const [
          DbMigrationColumn(
            name: 'id',
            sourceType: 'integer',
            generic: DbGenericType.integer,
            nullable: false,
            isPrimaryKey: true,
            defaultValue: "nextval('t_id_seq'::regclass)",
          ),
          DbMigrationColumn(
            name: 'created_at',
            sourceType: 'timestamp with time zone',
            generic: DbGenericType.datetime,
            nullable: true,
            isPrimaryKey: false,
            defaultValue: 'now()',
          ),
          DbMigrationColumn(
            name: 'status',
            sourceType: 'text',
            generic: DbGenericType.text,
            nullable: false,
            isPrimaryKey: false,
            defaultValue: "'active'::text",
          ),
        ],
        drop: false,
      );
      final create = ddl.first;
      expect(create, contains('GENERATED BY DEFAULT AS IDENTITY'));
      expect(create, isNot(contains('nextval')));
      expect(create, contains('DEFAULT now()'));
      expect(create, contains("DEFAULT 'active'::text"));
    });

    test('跨引擎默认值:字面量/时间函数可移植,复杂表达式丢弃', () {
      String create(String? def) => DbMigration.buildCreateTable(
        DbEngine.postgres,
        DbEngine.sqlite,
        't',
        [
          DbMigrationColumn(
            name: 'c',
            sourceType: 'text',
            generic: DbGenericType.text,
            nullable: true,
            isPrimaryKey: false,
            defaultValue: def,
          ),
        ],
        drop: false,
      ).first;

      expect(create('42'), contains('DEFAULT 42'));
      expect(create("'x'::text"), contains("DEFAULT 'x'"));
      expect(create("'x'::text"), isNot(contains('::')));
      expect(create('now()'), contains('DEFAULT CURRENT_TIMESTAMP'));
      expect(create("upper(name)"), isNot(contains('DEFAULT')));
      // 布尔跨到 sqlite → 1/0
      final b = DbMigration.buildCreateTable(
        DbEngine.postgres,
        DbEngine.sqlite,
        't',
        const [
          DbMigrationColumn(
            name: 'f',
            sourceType: 'boolean',
            generic: DbGenericType.boolean,
            nullable: true,
            isPrimaryKey: false,
            defaultValue: 'true',
          ),
        ],
        drop: false,
      ).first;
      expect(b, contains('DEFAULT 1'));
    });

    test('注释:pg 用 COMMENT ON,ch 内联,sqlite 丢弃', () {
      const cols = [
        DbMigrationColumn(
          name: 'id',
          sourceType: 'bigint',
          generic: DbGenericType.bigint,
          nullable: false,
          isPrimaryKey: true,
          comment: "用户 id,别删'谨慎'",
        ),
      ];
      final pg = DbMigration.buildCreateTable(
        DbEngine.postgres,
        DbEngine.postgres,
        'users',
        cols,
        drop: false,
        tableComment: '用户表',
      );
      expect(pg, hasLength(3));
      expect(pg[1], "COMMENT ON TABLE \"users\" IS '用户表'");
      expect(pg[2], contains('COMMENT ON COLUMN "users"."id" IS'));
      expect(pg[2], contains("别删''谨慎''")); // 单引号双写

      final ch = DbMigration.buildCreateTable(
        DbEngine.clickhouse,
        DbEngine.clickhouse,
        'users',
        const [
          DbMigrationColumn(
            name: 'id',
            sourceType: 'Int64',
            generic: DbGenericType.bigint,
            nullable: false,
            isPrimaryKey: true,
            comment: '主键',
          ),
        ],
        drop: false,
        tableComment: '用户表',
      );
      expect(ch.single, contains("`id` Int64 COMMENT '主键'"));
      expect(ch.single, contains("COMMENT '用户表'"));

      final lite = DbMigration.buildCreateTable(
        DbEngine.sqlite,
        DbEngine.sqlite,
        'users',
        cols,
        drop: false,
        tableComment: '用户表',
      );
      expect(lite, hasLength(1)); // 无注释语句
      expect(lite.single, isNot(contains('COMMENT')));
    });

    test('索引重放:pg 换 ON 目标/跳过主键/加 IF NOT EXISTS;跨引擎不迁', () {
      const indexes = [
        DbIndexInfo(name: 'users_pkey', definition: 'CREATE UNIQUE INDEX …'),
        DbIndexInfo(
          name: 'users_email_key',
          definition:
              'CREATE UNIQUE INDEX users_email_key ON public.users '
              'USING btree (email)',
        ),
        DbIndexInfo(
          name: 'idx_users_age',
          definition:
              'CREATE INDEX idx_users_age ON public.users USING btree (age)',
        ),
      ];
      final pg = DbMigration.buildIndexStatements(
        DbEngine.postgres,
        DbEngine.postgres,
        indexes,
        sourceTable: 'users',
        targetTable: 'users',
        targetSchema: 'app',
      );
      expect(pg, hasLength(2)); // _pkey 跳过
      expect(
        pg[0],
        'CREATE UNIQUE INDEX IF NOT EXISTS users_email_key '
        'ON "app"."users" USING btree (email)',
      );
      expect(pg[1], contains('CREATE INDEX IF NOT EXISTS idx_users_age'));
      expect(pg[1], contains('ON "app"."users" USING'));

      // 跨引擎不迁
      expect(
        DbMigration.buildIndexStatements(
          DbEngine.postgres,
          DbEngine.sqlite,
          indexes,
          sourceTable: 'users',
          targetTable: 'users',
        ),
        isEmpty,
      );

      // sqlite 同引擎:重放 + IF NOT EXISTS
      final lite = DbMigration.buildIndexStatements(
        DbEngine.sqlite,
        DbEngine.sqlite,
        const [
          DbIndexInfo(
            name: 'idx_n',
            definition: 'CREATE INDEX idx_n ON users (name)',
          ),
        ],
        sourceTable: 'users',
        targetTable: 'users',
      );
      expect(lite.single, 'CREATE INDEX IF NOT EXISTS idx_n ON users (name)');
    });
  });

  group('生成列(GENERATED ALWAYS AS … STORED)', () {
    const gen = DbMigrationColumn(
      name: 'total',
      sourceType: 'numeric',
      generic: DbGenericType.decimal,
      nullable: true,
      isPrimaryKey: false,
      defaultValue: '(price * qty)',
      isGenerated: true,
    );

    test('pg→pg:重建生成性,不出 DEFAULT(修 0A000)', () {
      final ddl = DbMigration.buildCreateTable(
        DbEngine.postgres,
        DbEngine.postgres,
        't',
        const [gen],
        drop: false,
      ).first;
      expect(ddl, contains('GENERATED ALWAYS AS ((price * qty)) STORED'));
      expect(ddl, isNot(contains('DEFAULT')));
    });

    test('跨引擎:降级为普通列,生成表达式不出 DEFAULT', () {
      final ddl = DbMigration.buildCreateTable(
        DbEngine.postgres,
        DbEngine.sqlite,
        't',
        const [gen],
        drop: false,
      ).first;
      expect(ddl, isNot(contains('GENERATED')));
      expect(ddl, isNot(contains('DEFAULT')));
      expect(ddl, contains('"total" NUMERIC'));
    });
  });

  group('外键 / CHECK 约束', () {
    const fk = DbConstraintInfo(
      name: 'orders_uid_fkey',
      type: DbConstraintType.foreignKey,
      definition:
          'FOREIGN KEY (uid) REFERENCES app.users(id) ON DELETE CASCADE',
      refSchema: 'app',
      refTable: 'users',
    );
    const check = DbConstraintInfo(
      name: 'orders_amount_check',
      type: DbConstraintType.check,
      definition: 'CHECK ((amount > 0))',
    );

    test('pg:ALTER TABLE 追加;REFERENCES 按目标重写', () {
      // 落默认 schema:剥掉源 schema 前缀
      final flat = DbMigration.buildConstraintStatements(
        DbEngine.postgres,
        DbEngine.postgres,
        const [fk, check],
        targetTable: 'orders',
      );
      expect(flat, hasLength(2));
      expect(
        flat[0],
        'ALTER TABLE "orders" ADD CONSTRAINT "orders_uid_fkey" '
        'FOREIGN KEY (uid) REFERENCES "users"(id) ON DELETE CASCADE',
      );
      expect(
        flat[1],
        'ALTER TABLE "orders" ADD CONSTRAINT "orders_amount_check" '
        'CHECK ((amount > 0))',
      );

      // 保留 schema:限定到源 schema
      final kept = DbMigration.buildConstraintStatements(
        DbEngine.postgres,
        DbEngine.postgres,
        const [fk],
        targetTable: 'orders',
        targetSchema: 'app',
        preserveSchema: true,
      );
      expect(kept.single, contains('ALTER TABLE "app"."orders"'));
      expect(kept.single, contains('REFERENCES "app"."users"(id)'));
    });

    test('跨引擎 / CH:不迁', () {
      expect(
        DbMigration.buildConstraintStatements(
          DbEngine.postgres,
          DbEngine.sqlite,
          const [fk],
          targetTable: 'orders',
        ),
        isEmpty,
      );
      expect(
        DbMigration.buildConstraintStatements(
          DbEngine.sqlite,
          DbEngine.sqlite,
          const [fk],
          targetTable: 'orders',
        ),
        isEmpty, // sqlite 走建表内联,不出 ALTER
      );
    });

    test('sqlite 同引擎:外键内联进 CREATE TABLE', () {
      const liteFk = DbConstraintInfo(
        name: 'fk_orders_0',
        type: DbConstraintType.foreignKey,
        definition:
            'FOREIGN KEY ("uid") REFERENCES "users" ("id") ON DELETE CASCADE',
        refTable: 'users',
      );
      final ddl = DbMigration.buildCreateTable(
        DbEngine.sqlite,
        DbEngine.sqlite,
        'orders',
        const [
          DbMigrationColumn(
            name: 'id',
            sourceType: 'INTEGER',
            generic: DbGenericType.bigint,
            nullable: false,
            isPrimaryKey: true,
          ),
          DbMigrationColumn(
            name: 'uid',
            sourceType: 'INTEGER',
            generic: DbGenericType.bigint,
            nullable: true,
            isPrimaryKey: false,
          ),
        ],
        drop: false,
        constraints: const [liteFk],
      ).single;
      expect(ddl, contains('FOREIGN KEY ("uid") REFERENCES "users" ("id")'));
      expect(ddl, contains('ON DELETE CASCADE'));
      // pg 目标不内联(走 ALTER)
      final pgDdl = DbMigration.buildCreateTable(
        DbEngine.postgres,
        DbEngine.postgres,
        'orders',
        const [
          DbMigrationColumn(
            name: 'id',
            sourceType: 'bigint',
            generic: DbGenericType.bigint,
            nullable: false,
            isPrimaryKey: true,
          ),
        ],
        drop: false,
        constraints: const [fk],
      ).single;
      expect(pgDdl, isNot(contains('FOREIGN KEY')));
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
