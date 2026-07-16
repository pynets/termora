@Tags(['smoke'])
library;

// 传输功能(导出/导入/迁移)的 PostgreSQL 冒烟测试 — 需要本地 55432 临时 PG:
//   initdb -U postgres -A trust && pg_ctl -o "-p 55432" start
//   flutter test --run-skipped --tags smoke test/features/database/db_transfer_pg_smoke_test.dart
// 测试自建/自清理数据(tx_users 表 + transfer_target 库),不依赖预置种子。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:termora/features/database/data/db_service.dart';
import 'package:termora/features/database/data/db_transfer_service.dart';
import 'package:termora/features/database/domain/db_models.dart';

const _pgSource = DbConnectionConfig(
  id: 'pg-src',
  name: 'pg-src',
  host: 'localhost',
  port: 55432,
  database: 'postgres',
  username: 'postgres',
  password: '',
);

const _pgTarget = DbConnectionConfig(
  id: 'pg-dst',
  name: 'pg-dst',
  host: 'localhost',
  port: 55432,
  database: 'transfer_target',
  username: 'postgres',
  password: '',
);

Future<void> _run(DbConnectionConfig config, String sql) async {
  final conn = await DbService.open(config);
  try {
    await DbService.runSql(conn, sql);
  } finally {
    await conn.close();
  }
}

Future<void> _runAll(DbConnectionConfig config, List<String> statements) async {
  final conn = await DbService.open(config);
  try {
    for (final sql in statements) {
      await DbService.runSql(conn, sql);
    }
  } finally {
    await conn.close();
  }
}

Future<List<List<Object?>>> _query(
  DbConnectionConfig config,
  String sql,
) async {
  final conn = await DbService.open(config);
  try {
    final (output, _) = await DbService.runSql(conn, sql);
    return output.rows;
  } finally {
    await conn.close();
  }
}

void main() {
  late Directory tempDir;

  setUpAll(() async {
    try {
      await _run(_pgSource, 'CREATE DATABASE transfer_target');
    } catch (_) {} // 已存在
  });

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('termora_pg_transfer');
    // 源表:覆盖 pg 常用类型(含需要特殊转义/映射的)
    await _run(_pgSource, """
DROP TABLE IF EXISTS tx_users;
CREATE TABLE tx_users (
  id bigint PRIMARY KEY,
  name text NOT NULL,
  age integer,
  ratio double precision,
  price numeric(10,2),
  active boolean,
  meta jsonb,
  uid uuid,
  raw bytea,
  created_at timestamp
);
INSERT INTO tx_users
SELECT i,
       'user''' || i,
       CASE WHEN i % 3 = 0 THEN NULL ELSE i END,
       i * 0.5,
       i * 1.25,
       i % 2 = 0,
       jsonb_build_object('i', i),
       '00000000-0000-0000-0000-000000000001'::uuid,
       decode('deadbeef', 'hex'),
       timestamp '2026-01-01 00:00:00' + (i || ' hours')::interval
FROM generate_series(1, 450) i;
""");
    await _run(_pgTarget, 'DROP TABLE IF EXISTS tx_users');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('迁移整库 pg → pg:多 schema 保留 + 限定名', () async {
    // 源库建两个 schema,各一张表
    await _runAll(_pgSource, [
      'DROP SCHEMA IF EXISTS wdb_a CASCADE',
      'DROP SCHEMA IF EXISTS wdb_b CASCADE',
      'CREATE SCHEMA wdb_a',
      'CREATE SCHEMA wdb_b',
      'CREATE TABLE wdb_a.orders (id bigint PRIMARY KEY, amount numeric)',
      'CREATE TABLE wdb_b.items (id bigint PRIMARY KEY, name text)',
      'INSERT INTO wdb_a.orders SELECT i, i*1.5 FROM generate_series(1,30) i',
      "INSERT INTO wdb_b.items SELECT i, 'item'||i FROM generate_series(1,40) i",
    ]);
    await _runAll(_pgTarget, [
      'DROP SCHEMA IF EXISTS wdb_a CASCADE',
      'DROP SCHEMA IF EXISTS wdb_b CASCADE',
    ]);

    final summary = await DbTransferService.migrate(
      source: _pgSource,
      target: _pgTarget,
      wholeDatabase: true,
    );
    // 至少覆盖我们建的两张表 + public.tx_users
    expect(summary.tables, greaterThanOrEqualTo(3));

    // schema 保留(限定名建到目标对应 schema)+ 数据到位
    expect(
      (await _query(
        _pgTarget,
        'SELECT count(*) FROM wdb_a.orders',
      )).first.first,
      30,
    );
    expect(
      (await _query(_pgTarget, 'SELECT count(*) FROM wdb_b.items')).first.first,
      40,
    );
    expect(
      (await _query(
        _pgTarget,
        'SELECT name FROM wdb_b.items WHERE id = 1',
      )).first.first,
      'item1',
    );
    // 主键约束迁过来了
    await expectLater(
      _runAll(_pgTarget, [
        'INSERT INTO wdb_a.orders (id, amount) VALUES (1, 0)',
      ]),
      throwsA(anything),
    );

    await _runAll(_pgSource, [
      'DROP SCHEMA IF EXISTS wdb_a CASCADE',
      'DROP SCHEMA IF EXISTS wdb_b CASCADE',
    ]);
    await _runAll(_pgTarget, [
      'DROP SCHEMA IF EXISTS wdb_a CASCADE',
      'DROP SCHEMA IF EXISTS wdb_b CASCADE',
    ]);
  });

  test('迁移多选 schema(非整库):只迁选中的,保留 schema', () async {
    await _runAll(_pgSource, [
      'DROP SCHEMA IF EXISTS msel_a CASCADE',
      'DROP SCHEMA IF EXISTS msel_b CASCADE',
      'CREATE SCHEMA msel_a',
      'CREATE SCHEMA msel_b',
      'CREATE TABLE msel_a.t (id bigint PRIMARY KEY)',
      'CREATE TABLE msel_b.t (id bigint PRIMARY KEY)',
      'INSERT INTO msel_a.t SELECT generate_series(1,7)',
      'INSERT INTO msel_b.t SELECT generate_series(1,9)',
    ]);
    await _runAll(_pgTarget, [
      'DROP SCHEMA IF EXISTS msel_a CASCADE',
      'DROP SCHEMA IF EXISTS msel_b CASCADE',
      'DROP TABLE IF EXISTS public_marker',
      'CREATE TABLE public_marker (id int)', // public 里放个标记表
    ]);

    // 只选 msel_a + msel_b(不含 public)
    final summary = await DbTransferService.migrate(
      source: _pgSource,
      target: _pgTarget,
      schemaTables: const {'msel_a': [], 'msel_b': []},
    );
    expect(summary.tables, 2);
    expect(summary.rows, 16);

    // 两个 schema 都限定名建到位
    expect(
      (await _query(_pgTarget, 'SELECT count(*) FROM msel_a.t')).first.first,
      7,
    );
    expect(
      (await _query(_pgTarget, 'SELECT count(*) FROM msel_b.t')).first.first,
      9,
    );
    // public 没被动(标记表还在,没被覆盖式清空)
    expect(
      (await _query(
        _pgTarget,
        "SELECT count(*) FROM information_schema.tables WHERE table_name='public_marker'",
      )).first.first,
      1,
    );

    await _runAll(_pgSource, [
      'DROP SCHEMA IF EXISTS msel_a CASCADE',
      'DROP SCHEMA IF EXISTS msel_b CASCADE',
    ]);
    await _runAll(_pgTarget, [
      'DROP SCHEMA IF EXISTS msel_a CASCADE',
      'DROP SCHEMA IF EXISTS msel_b CASCADE',
      'DROP TABLE IF EXISTS public_marker',
    ]);
  });

  test('迁移 pg → pg:数组列(text[]/integer[],含空数组)', () async {
    await _runAll(_pgSource, [
      'DROP TABLE IF EXISTS arr_users',
      '''
CREATE TABLE arr_users (
  id bigint PRIMARY KEY,
  tags text[],
  nums integer[],
  meta jsonb
)''',
      r"""
INSERT INTO arr_users
SELECT i,
       CASE WHEN i % 5 = 0 THEN '{}'::text[]
            WHEN i % 7 = 0 THEN NULL
            ELSE ARRAY['x' || i, 'q "d" z', 'a\b', 'it''s'] END,
       CASE WHEN i % 3 = 0 THEN ARRAY[]::integer[] ELSE ARRAY[i, i * 2] END,
       jsonb_build_array(i, 'a')
FROM generate_series(1, 60) i""",
    ]);
    await _runAll(_pgTarget, ['DROP TABLE IF EXISTS arr_users']);

    final summary = await DbTransferService.migrate(
      source: _pgSource,
      target: _pgTarget,
      schema: 'public',
      tables: ['arr_users'],
    );
    expect(summary.rows, 60);

    // 类型保真
    final types = await _query(_pgTarget, """
SELECT column_name, data_type FROM information_schema.columns
WHERE table_name = 'arr_users' ORDER BY ordinal_position""");
    final byName = {for (final r in types) r[0]: r[1]};
    expect(byName['tags'], 'ARRAY');
    expect(byName['nums'], 'ARRAY');

    // 值保真:空数组 / NULL / 特殊字符元素 / 数字数组 / jsonb 数组
    final row1 = (await _query(_pgTarget, """
SELECT array_length(tags, 1), tags[1], tags[2], tags[3], tags[4],
       nums[2], meta ->> 1
FROM arr_users WHERE id = 1""")).first;
    expect(row1[0], 4);
    expect(row1[1], 'x1');
    expect(row1[2], 'q "d" z');
    expect(row1[3], r'a\b');
    expect(row1[4], "it's");
    expect(row1[5], 2);
    expect(row1[6], 'a');

    // 空数组(曾报 22P02 malformed array literal 的场景)
    final row5 = (await _query(_pgTarget, """
SELECT tags = '{}'::text[], array_length(tags, 1) IS NULL
FROM arr_users WHERE id = 5""")).first;
    expect(row5[0], true);
    expect(row5[1], true);
    // NULL 数组
    expect(
      (await _query(
        _pgTarget,
        'SELECT tags IS NULL FROM arr_users WHERE id = 7',
      )).first.first,
      true,
    );
    // 空 integer 数组
    expect(
      (await _query(
        _pgTarget,
        "SELECT nums = '{}'::integer[] FROM arr_users WHERE id = 3",
      )).first.first,
      true,
    );

    await _runAll(_pgSource, ['DROP TABLE IF EXISTS arr_users']);
    await _runAll(_pgTarget, ['DROP TABLE IF EXISTS arr_users']);
  });

  test('迁移 pg → pg:PostGIS geometry 列(需源库已装 postgis)', () async {
    // 源库没装 postgis 则跳过(macOS EDB 安装器带 postgis 3.6)
    try {
      await _run(_pgSource, 'CREATE EXTENSION IF NOT EXISTS postgis');
    } catch (_) {
      markTestSkipped('本地 PG 无 postgis,跳过');
      return;
    }

    await _runAll(_pgSource, [
      'DROP TABLE IF EXISTS geo_places',
      '''
CREATE TABLE geo_places (
  id bigint PRIMARY KEY,
  name text,
  loc geometry(Point, 4326),
  area geography(Polygon, 4326)
)''',
      """
INSERT INTO geo_places
SELECT i,
       'p' || i,
       CASE WHEN i % 5 = 0 THEN NULL
            ELSE ST_SetSRID(ST_MakePoint(i * 0.1, i * 0.2), 4326) END,
       CASE WHEN i % 3 = 0 THEN NULL
            ELSE ST_GeogFromText(
              'POLYGON((0 0, 0 ' || i || ', ' || i || ' 0, 0 0))') END
FROM generate_series(1, 40) i""",
    ]);
    await _runAll(_pgTarget, ['DROP TABLE IF EXISTS geo_places']);
    // 清掉可能残留的 spatial_ref_sys 孤儿副本(会挡住 CREATE EXTENSION);
    // 若已归 postgis 扩展管则删不掉,忽略即可
    try {
      await _run(_pgTarget, 'DROP TABLE IF EXISTS spatial_ref_sys');
    } catch (_) {}

    // 迁移会在目标端自动 CREATE EXTENSION IF NOT EXISTS postgis
    final summary = await DbTransferService.migrate(
      source: _pgSource,
      target: _pgTarget,
      schema: 'public',
      tables: ['geo_places'],
    );
    expect(summary.rows, 40);

    // 值保真:坐标 / SRID / NULL;geography 多边形面积一致
    final row = (await _query(
      _pgTarget,
      '''
SELECT ST_X(loc), ST_Y(loc), ST_SRID(loc) FROM geo_places WHERE id = 1''',
    )).first;
    expect((row[0] as num).toDouble(), closeTo(0.1, 1e-9));
    expect((row[1] as num).toDouble(), closeTo(0.2, 1e-9));
    expect(row[2], 4326);
    expect(
      (await _query(
        _pgTarget,
        'SELECT loc IS NULL FROM geo_places WHERE id = 5',
      )).first.first,
      true,
    );
    // 源和目标的同一 geography 面积应一致
    final srcArea = (await _query(
      _pgSource,
      'SELECT ST_Area(area) FROM geo_places WHERE id = 2',
    )).first.first;
    final dstArea = (await _query(
      _pgTarget,
      'SELECT ST_Area(area) FROM geo_places WHERE id = 2',
    )).first.first;
    expect(
      (dstArea as num).toDouble(),
      closeTo((srcArea as num).toDouble(), 1),
    );

    // 整库迁移必须跳过 postgis 系统表(spatial_ref_sys):
    // 若被当普通表处理,覆盖式 DROP 会撞上扩展依赖直接报错
    await DbTransferService.migrate(
      source: _pgSource,
      target: _pgTarget,
      wholeDatabase: true,
    );
    // 目标端 spatial_ref_sys 仍归 postgis 扩展管,没有被搬运/重建
    expect(
      (await _query(_pgTarget, """
SELECT count(*) FROM pg_depend d
JOIN pg_class c ON c.oid = d.objid
WHERE c.relname = 'spatial_ref_sys' AND d.deptype = 'e'""")).first.first,
      1,
    );

    await _runAll(_pgSource, ['DROP TABLE IF EXISTS geo_places']);
    await _runAll(_pgTarget, ['DROP TABLE IF EXISTS geo_places']);
  });

  test('迁移 pg → pg:pgvector 向量列(需源库已装 vector)', () async {
    try {
      await _run(_pgSource, 'CREATE EXTENSION IF NOT EXISTS vector');
    } catch (_) {
      markTestSkipped('本地 PG 无 pgvector,跳过');
      return;
    }

    await _runAll(_pgSource, [
      'DROP TABLE IF EXISTS vec_chunks',
      '''
CREATE TABLE vec_chunks (
  id bigint PRIMARY KEY,
  content text,
  embedding vector(1536)
)''',
      // 1536 维大向量(贴近真实 embedding 规模);每 7 行一个 NULL
      """
INSERT INTO vec_chunks
SELECT i,
       'chunk' || i,
       CASE WHEN i % 7 = 0 THEN NULL
            ELSE (SELECT ('[' || string_agg(
                    ((i * 1000 + d) % 997 * 0.001 - 0.4985)::float4::text, ',')
                  || ']')
                  FROM generate_series(1, 1536) d)::vector END
FROM generate_series(1, 30) i""",
    ]);
    await _runAll(_pgTarget, ['DROP TABLE IF EXISTS vec_chunks']);

    // 迁移会在目标端自动 CREATE EXTENSION IF NOT EXISTS vector
    final summary = await DbTransferService.migrate(
      source: _pgSource,
      target: _pgTarget,
      schema: 'public',
      tables: ['vec_chunks'],
    );
    expect(summary.rows, 30);

    // 类型保真 + 维度
    expect(
      (await _query(_pgTarget, """
SELECT format_type(atttypid, atttypmod) FROM pg_attribute a
JOIN pg_class c ON c.oid = a.attrelid
WHERE c.relname = 'vec_chunks' AND attname = 'embedding'""")).first.first,
      'vector(1536)',
    );

    // 值逐一对比:源和目标的向量文本完全一致(float32 最短往返无损)
    final srcVecs = await _query(
      _pgSource,
      'SELECT id, embedding::text FROM vec_chunks ORDER BY id',
    );
    final dstVecs = await _query(
      _pgTarget,
      'SELECT id, embedding::text FROM vec_chunks ORDER BY id',
    );
    expect(dstVecs.length, srcVecs.length);
    for (var i = 0; i < srcVecs.length; i++) {
      expect(dstVecs[i][0], srcVecs[i][0]);
      expect(dstVecs[i][1], srcVecs[i][1], reason: 'id=${srcVecs[i][0]} 向量不一致');
    }

    await _runAll(_pgSource, ['DROP TABLE IF EXISTS vec_chunks']);
    await _runAll(_pgTarget, ['DROP TABLE IF EXISTS vec_chunks']);
  });

  test('迁移 pg → pg:time/interval/point/range 等驱动特有类型', () async {
    await _runAll(_pgSource, [
      'DROP TABLE IF EXISTS typ_misc',
      '''
CREATE TABLE typ_misc (
  id bigint PRIMARY KEY,
  t time,
  iv interval,
  pt point,
  ir int4range,
  tr tstzrange
)''',
      """
INSERT INTO typ_misc VALUES
  (1, '14:00:00',        '2 days 03:04:05',  '(1.5,-2.5)', '[1,10)',
      '[2026-01-01 08:00+00, 2026-01-02 08:00+00)'),
  (2, '23:59:59.123456', '1 mon 15 days',    '(0,0)',      'empty',
      NULL),
  (3, NULL,              NULL,               NULL,         NULL,
      NULL)""",
    ]);
    await _runAll(_pgTarget, ['DROP TABLE IF EXISTS typ_misc']);

    final summary = await DbTransferService.migrate(
      source: _pgSource,
      target: _pgTarget,
      schema: 'public',
      tables: ['typ_misc'],
    );
    expect(summary.rows, 3);

    // 逐列以 ::text 对比源/目标(值语义一致)
    const probe = '''
SELECT id, t::text, iv::text, pt::text, ir::text, tr::text
FROM typ_misc ORDER BY id''';
    final src = await _query(_pgSource, probe);
    final dst = await _query(_pgTarget, probe);
    expect(dst.length, src.length);
    for (var i = 0; i < src.length; i++) {
      expect(dst[i], src[i], reason: 'id=${src[i][0]} 行不一致');
    }

    await _runAll(_pgSource, ['DROP TABLE IF EXISTS typ_misc']);
    await _runAll(_pgTarget, ['DROP TABLE IF EXISTS typ_misc']);
  });

  test('迁移 pg → pg:默认值(serial→IDENTITY)/ 注释 / 二级索引', () async {
    await _runAll(_pgSource, [
      'DROP TABLE IF EXISTS fid_users',
      '''
CREATE TABLE fid_users (
  id serial PRIMARY KEY,
  email text NOT NULL,
  status text DEFAULT 'active',
  score numeric DEFAULT 10.5,
  created_at timestamptz DEFAULT now()
)''',
      'CREATE UNIQUE INDEX fid_users_email_key ON fid_users (email)',
      'CREATE INDEX idx_fid_users_status ON fid_users (status)',
      "COMMENT ON TABLE fid_users IS '用户表'",
      "COMMENT ON COLUMN fid_users.email IS '邮箱,唯一'",
      "INSERT INTO fid_users (email) SELECT 'u' || i || '@x.com' "
          'FROM generate_series(1, 20) i',
    ]);
    await _runAll(_pgTarget, ['DROP TABLE IF EXISTS fid_users']);

    final summary = await DbTransferService.migrate(
      source: _pgSource,
      target: _pgTarget,
      schema: 'public',
      tables: ['fid_users'],
    );
    expect(summary.rows, 20);

    // 默认值:status/score/created_at 落到目标列定义
    final defs = await _query(_pgTarget, """
SELECT column_name, column_default FROM information_schema.columns
WHERE table_name = 'fid_users' ORDER BY ordinal_position""");
    final defByName = {for (final r in defs) r[0]: '${r[1]}'};
    expect(defByName['status'], contains("'active'"));
    expect(defByName['score'], contains('10.5'));
    expect(defByName['created_at'], contains('now()'));

    // serial → IDENTITY:迁移应已把序列拨到 max(id)=20,不带 id 直接插入
    // 就能自增到 21(不再手动 setval —— 这正是之前漏掉的一步)
    await _run(_pgTarget, "INSERT INTO fid_users (email) VALUES ('new@x.com')");
    expect(
      (await _query(
        _pgTarget,
        "SELECT id, status FROM fid_users WHERE email = 'new@x.com'",
      )).first,
      [21, 'active'], // 自增续在已迁数据之后 + 默认值生效
    );

    // 注释迁过来了
    expect(
      (await _query(
        _pgTarget,
        "SELECT obj_description('fid_users'::regclass)",
      )).first.first,
      '用户表',
    );
    expect(
      (await _query(
        _pgTarget,
        """
SELECT col_description('fid_users'::regclass,
  (SELECT attnum FROM pg_attribute
   WHERE attrelid = 'fid_users'::regclass AND attname = 'email'))""",
      )).first.first,
      '邮箱,唯一',
    );

    // 二级索引迁过来了(唯一索引约束生效)
    final idx = await _query(_pgTarget, """
SELECT indexname FROM pg_indexes
WHERE tablename = 'fid_users' ORDER BY indexname""");
    final names = [for (final r in idx) r[0]];
    expect(names, contains('fid_users_email_key'));
    expect(names, contains('idx_fid_users_status'));
    await expectLater(
      _run(
        _pgTarget,
        "INSERT INTO fid_users (email) VALUES ('u1@x.com')", // 撞唯一索引
      ),
      throwsA(anything),
    );

    await _runAll(_pgSource, ['DROP TABLE IF EXISTS fid_users']);
    await _runAll(_pgTarget, ['DROP TABLE IF EXISTS fid_users']);
  });

  test('迁移 pg → pg:旧语法现代化 char(n)→text / money→numeric + 值清洗', () async {
    await _runAll(_pgSource, [
      'DROP TABLE IF EXISTS mod_t',
      '''
CREATE TABLE mod_t (
  id bigint PRIMARY KEY,
  code char(6),
  price money,
  note character varying(20)
)''',
      "INSERT INTO mod_t VALUES "
          "(1, 'ab', 1234.56, 'hi'), "
          "(2, 'xyz', -0.99, 'yo'), "
          "(3, NULL, 1000000.00, NULL)",
    ]);
    await _runAll(_pgTarget, ['DROP TABLE IF EXISTS mod_t']);

    final summary = await DbTransferService.migrate(
      source: _pgSource,
      target: _pgTarget,
      schema: 'public',
      tables: ['mod_t'],
    );
    expect(summary.rows, 3);

    // 类型现代化:char→text、money→numeric、varchar 不动
    final types = await _query(_pgTarget, """
SELECT column_name, data_type FROM information_schema.columns
WHERE table_name = 'mod_t' ORDER BY ordinal_position""");
    final byName = {for (final r in types) r[0]: r[1]};
    expect(byName['code'], 'text');
    expect(byName['price'], 'numeric');
    expect(byName['note'], 'character varying');

    // 值清洗:money 去货币符/逗号、负数;char 去尾部填充空格
    final r1 = (await _query(
      _pgTarget,
      "SELECT code, price::text FROM mod_t WHERE id = 1",
    )).first;
    expect(r1[0], 'ab'); // char(6) 'ab    ' → 去填充
    expect(r1[1], '1234.56');
    final r2 = (await _query(
      _pgTarget,
      "SELECT code, price::text FROM mod_t WHERE id = 2",
    )).first;
    expect(r2[0], 'xyz');
    expect(r2[1], '-0.99'); // 负 money
    expect(
      (await _query(
        _pgTarget,
        "SELECT price::text FROM mod_t WHERE id = 3",
      )).first.first,
      '1000000.00',
    );

    await _runAll(_pgSource, ['DROP TABLE IF EXISTS mod_t']);
    await _runAll(_pgTarget, ['DROP TABLE IF EXISTS mod_t']);
  });

  test('迁移 pg → pg:现代 IDENTITY 主键(序列拨到 max,直接续增)', () async {
    await _runAll(_pgSource, [
      'DROP TABLE IF EXISTS idn_t',
      '''
CREATE TABLE idn_t (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name text
)''',
      "INSERT INTO idn_t (name) SELECT 'n' || i FROM generate_series(1, 50) i",
    ]);
    await _runAll(_pgTarget, ['DROP TABLE IF EXISTS idn_t']);

    final summary = await DbTransferService.migrate(
      source: _pgSource,
      target: _pgTarget,
      schema: 'public',
      tables: ['idn_t'],
    );
    expect(summary.rows, 50);

    // 目标端 id 仍是 IDENTITY 列
    expect(
      (await _query(_pgTarget, """
SELECT attidentity <> '' FROM pg_attribute
WHERE attrelid = 'idn_t'::regclass AND attname = 'id'""")).first.first,
      true,
    );
    // 数据保真 + max=50
    expect(
      (await _query(_pgTarget, 'SELECT max(id) FROM idn_t')).first.first,
      50,
    );
    // 直接插入(BY DEFAULT identity 允许省略 id)→ 自增 51,不撞主键
    await _run(_pgTarget, "INSERT INTO idn_t (name) VALUES ('new')");
    expect(
      (await _query(
        _pgTarget,
        "SELECT id FROM idn_t WHERE name = 'new'",
      )).first.first,
      51,
    );

    await _runAll(_pgSource, ['DROP TABLE IF EXISTS idn_t']);
    await _runAll(_pgTarget, ['DROP TABLE IF EXISTS idn_t']);
  });

  test('迁移 pg → pg:生成列(GENERATED STORED)重建并自动重算', () async {
    await _runAll(_pgSource, [
      'DROP TABLE IF EXISTS gen_items',
      '''
CREATE TABLE gen_items (
  id bigint PRIMARY KEY,
  price numeric NOT NULL,
  qty integer NOT NULL,
  total numeric GENERATED ALWAYS AS (price * qty) STORED
)''',
      'INSERT INTO gen_items (id, price, qty) '
          'SELECT i, i * 1.5, i FROM generate_series(1, 25) i',
    ]);
    await _runAll(_pgTarget, ['DROP TABLE IF EXISTS gen_items']);

    final summary = await DbTransferService.migrate(
      source: _pgSource,
      target: _pgTarget,
      schema: 'public',
      tables: ['gen_items'],
    );
    expect(summary.rows, 25);

    // 目标端列确实是生成列
    expect(
      (await _query(_pgTarget, """
SELECT attgenerated FROM pg_attribute
WHERE attrelid = 'gen_items'::regclass AND attname = 'total'""")).first.first,
      's',
    );
    // 已迁数据的生成值正确(目标端重算 = 源值)
    expect(
      (await _query(
        _pgTarget,
        'SELECT count(*) FROM gen_items WHERE total <> price * qty',
      )).first.first,
      0,
    );
    expect(
      (await _query(
        _pgTarget,
        'SELECT total FROM gen_items WHERE id = 4',
      )).first.first,
      isNotNull,
    );
    // 新插入自动计算
    await _run(
      _pgTarget,
      'INSERT INTO gen_items (id, price, qty) VALUES (99, 10, 3)',
    );
    expect(
      (await _query(
        _pgTarget,
        'SELECT total::text FROM gen_items WHERE id = 99',
      )).first.first,
      '30',
    );

    await _runAll(_pgSource, ['DROP TABLE IF EXISTS gen_items']);
    await _runAll(_pgTarget, ['DROP TABLE IF EXISTS gen_items']);
  });

  test('覆盖式重迁 pg → pg:被外键引用的表也能 DROP(修 2BP01)', () async {
    await _runAll(_pgSource, [
      'DROP TABLE IF EXISTS ref_child, ref_parent CASCADE',
      'CREATE TABLE ref_parent (id bigint PRIMARY KEY, name text)',
      '''
CREATE TABLE ref_child (
  id bigint PRIMARY KEY,
  pid bigint REFERENCES ref_parent(id)
)''',
      'INSERT INTO ref_parent SELECT i, \'p\' || i FROM generate_series(1, 5) i',
      'INSERT INTO ref_child SELECT i, (i % 5) + 1 FROM generate_series(1, 8) i',
    ]);
    await _runAll(_pgTarget, [
      'DROP TABLE IF EXISTS ref_child, ref_parent CASCADE',
    ]);

    Future<void> migrate() => DbTransferService.migrate(
      source: _pgSource,
      target: _pgTarget,
      schemaTables: const {
        'public': ['ref_parent', 'ref_child'],
      },
    );

    // 第一次迁移建好表+外键
    await migrate();
    // 第二次覆盖式重迁:目标端 ref_parent 已被 ref_child 的外键引用,
    // DROP 必须 CASCADE 才不报 2BP01
    await migrate();

    expect(
      (await _query(_pgTarget, 'SELECT count(*) FROM ref_child')).first.first,
      8,
    );
    // 外键仍在且生效
    expect(
      (await _query(_pgTarget, """
SELECT count(*) FROM pg_constraint
WHERE conrelid = 'ref_child'::regclass AND contype = 'f'""")).first.first,
      1,
    );
    await expectLater(
      _run(_pgTarget, 'INSERT INTO ref_child VALUES (99, 424242)'),
      throwsA(anything),
    );

    await _runAll(_pgSource, [
      'DROP TABLE IF EXISTS ref_child, ref_parent CASCADE',
    ]);
    await _runAll(_pgTarget, [
      'DROP TABLE IF EXISTS ref_child, ref_parent CASCADE',
    ]);
  });

  test('迁移 pg → pg:外键 + CHECK(子表排序在父表前也不怕)', () async {
    await _runAll(_pgSource, [
      'DROP TABLE IF EXISTS a_orders', // 名字排在父表前,考验建表顺序无关性
      'DROP TABLE IF EXISTS z_users',
      'CREATE TABLE z_users (id bigint PRIMARY KEY, name text)',
      '''
CREATE TABLE a_orders (
  id bigint PRIMARY KEY,
  uid bigint NOT NULL REFERENCES z_users(id) ON DELETE CASCADE,
  amount numeric CHECK (amount > 0)
)''',
      'INSERT INTO z_users SELECT i, \'u\' || i FROM generate_series(1, 10) i',
      'INSERT INTO a_orders SELECT i, (i % 10) + 1, i * 1.5 '
          'FROM generate_series(1, 30) i',
    ]);
    await _runAll(_pgTarget, [
      'DROP TABLE IF EXISTS a_orders',
      'DROP TABLE IF EXISTS z_users',
    ]);

    final summary = await DbTransferService.migrate(
      source: _pgSource,
      target: _pgTarget,
      schemaTables: const {
        'public': ['a_orders', 'z_users'],
      },
    );
    expect(summary.rows, 40);

    // 外键真实生效:引用不存在的 uid 报错;级联删除生效
    await expectLater(
      _run(_pgTarget, 'INSERT INTO a_orders VALUES (99, 424242, 1)'),
      throwsA(anything),
    );
    await _run(_pgTarget, 'DELETE FROM z_users WHERE id = 2');
    expect(
      (await _query(
        _pgTarget,
        'SELECT count(*) FROM a_orders WHERE uid = 2',
      )).first.first,
      0, // 级联删掉
    );
    // CHECK 生效
    await expectLater(
      _run(_pgTarget, 'INSERT INTO a_orders VALUES (98, 1, -5)'),
      throwsA(anything),
    );
    // 约束名保留
    expect(
      (await _query(
        _pgTarget,
        """
SELECT count(*) FROM pg_constraint
WHERE conrelid = 'a_orders'::regclass AND contype IN ('f', 'c')""",
      )).first.first,
      2,
    );

    await _runAll(_pgSource, [
      'DROP TABLE IF EXISTS a_orders',
      'DROP TABLE IF EXISTS z_users',
    ]);
    await _runAll(_pgTarget, [
      'DROP TABLE IF EXISTS a_orders',
      'DROP TABLE IF EXISTS z_users',
    ]);
  });

  test('迁移 pg → pg:同引擎类型保真 + 覆盖', () async {
    final summary = await DbTransferService.migrate(
      source: _pgSource,
      target: _pgTarget,
      schema: 'public',
      tables: ['tx_users'],
    );
    expect(summary.rows, 450);

    expect(
      (await _query(_pgTarget, 'SELECT count(*) FROM tx_users')).first.first,
      450,
    );
    // 同引擎沿用原始类型
    final types = await _query(_pgTarget, """
SELECT column_name, data_type FROM information_schema.columns
WHERE table_name = 'tx_users' ORDER BY ordinal_position""");
    final byName = {for (final r in types) r[0]: r[1]};
    expect(byName['id'], 'bigint');
    expect(byName['price'], 'numeric');
    expect(byName['meta'], 'jsonb');
    expect(byName['raw'], 'bytea');

    // 值保真:引号 / NULL / bool / jsonb / bytea / 时间
    final row = (await _query(_pgTarget, """
SELECT name, age, active, meta ->> 'i', encode(raw, 'hex'),
       to_char(created_at, 'YYYY-MM-DD HH24:MI')
FROM tx_users WHERE id = 1""")).first;
    expect(row[0], "user'1");
    expect(row[1], 1);
    expect(row[2], false);
    expect(row[3], '1');
    expect(row[4], 'deadbeef');
    expect(row[5], '2026-01-01 01:00');
    expect(
      (await _query(
        _pgTarget,
        'SELECT age FROM tx_users WHERE id = 3',
      )).first.first,
      isNull,
    );

    // 主键迁过来了
    await expectLater(
      _run(_pgTarget, "INSERT INTO tx_users (id, name) VALUES (1, 'dup')"),
      throwsA(anything),
    );

    // 再迁一次:覆盖不报错、不翻倍
    await DbTransferService.migrate(
      source: _pgSource,
      target: _pgTarget,
      schema: 'public',
      tables: ['tx_users'],
    );
    expect(
      (await _query(_pgTarget, 'SELECT count(*) FROM tx_users')).first.first,
      450,
    );
  });

  test('迁移 pg → sqlite:跨引擎类型映射', () async {
    final sqlitePath = '${tempDir.path}/target.db';
    sqlite3.open(sqlitePath).close(); // 建空库

    final summary = await DbTransferService.migrate(
      source: _pgSource,
      target: DbConnectionConfig(
        id: 'lite',
        name: 'lite',
        engine: DbEngine.sqlite,
        database: sqlitePath,
      ),
      schema: 'public',
      tables: ['tx_users'],
    );
    expect(summary.rows, 450);

    final db = sqlite3.open(sqlitePath);
    try {
      expect(
        db.select('SELECT count(*) FROM tx_users').first.values.first,
        450,
      );
      final row = db
          .select(
            'SELECT name, age, active, meta, raw, created_at '
            'FROM tx_users WHERE id = 1',
          )
          .first
          .values;
      expect(row[0], "user'1");
      expect(row[1], 1);
      expect(row[2], 0); // boolean → INTEGER
      expect(row[3], '{"i":1}'); // jsonb → JSON 文本
      expect(row[4], [0xde, 0xad, 0xbe, 0xef]); // bytea → BLOB
      expect('${row[5]}', startsWith('2026-01-01T01:00')); // timestamp → TEXT
      expect(
        db.select('SELECT age FROM tx_users WHERE id = 3').first.values.first,
        isNull,
      );
    } finally {
      db.close();
    }
  });

  test('迁移 sqlite → pg:亲和类型落成 pg 类型', () async {
    final sqlitePath = '${tempDir.path}/source.db';
    final seed = sqlite3.open(sqlitePath);
    seed.execute("""
CREATE TABLE gadgets (
  id INTEGER PRIMARY KEY,
  label TEXT NOT NULL,
  weight REAL,
  data BLOB
);
""");
    final insert = seed.prepare('INSERT INTO gadgets VALUES (?, ?, ?, ?)');
    for (var i = 1; i <= 120; i++) {
      insert.execute([
        i,
        "g'$i",
        i * 0.25,
        i == 1 ? [0xca, 0xfe] : null,
      ]);
    }
    insert.close();
    seed.close();

    await _run(_pgTarget, 'DROP TABLE IF EXISTS gadgets');
    final summary = await DbTransferService.migrate(
      source: DbConnectionConfig(
        id: 'lite-src',
        name: 'lite-src',
        engine: DbEngine.sqlite,
        database: sqlitePath,
      ),
      target: _pgTarget,
      schema: 'main',
      tables: ['gadgets'],
    );
    expect(summary.rows, 120);

    final types = await _query(_pgTarget, """
SELECT column_name, data_type FROM information_schema.columns
WHERE table_name = 'gadgets' ORDER BY ordinal_position""");
    final byName = {for (final r in types) r[0]: r[1]};
    expect(byName['id'], 'bigint');
    expect(byName['label'], 'text');
    expect(byName['weight'], 'double precision');
    expect(byName['data'], 'bytea');

    final row = (await _query(_pgTarget, """
SELECT label, weight, encode(data, 'hex') FROM gadgets WHERE id = 1""")).first;
    expect(row[0], "g'1");
    expect(row[1], 0.25);
    expect(row[2], 'cafe');
    expect(
      (await _query(_pgTarget, 'SELECT count(*) FROM gadgets')).first.first,
      120,
    );
  });

  test('导出 pg 脚本再导入 pg:等价回放', () async {
    final scriptPath = '${tempDir.path}/dump.sql';
    final exported = await DbTransferService.exportToScript(
      source: _pgSource,
      schema: 'public',
      tables: ['tx_users'],
      targetEngine: DbEngine.postgres,
      filePath: scriptPath,
    );
    expect(exported.rows, 450);

    final script = await File(scriptPath).readAsString();
    expect(script, contains('DROP TABLE IF EXISTS "tx_users"'));
    expect(script, contains('"id" bigint NOT NULL'));

    final imported = await DbTransferService.importScript(
      target: _pgTarget,
      script: script,
    );
    // DROP + CREATE + 3 批 INSERT
    expect(imported.statements, 5);
    expect(
      (await _query(_pgTarget, 'SELECT count(*) FROM tx_users')).first.first,
      450,
    );
    final row = (await _query(
      _pgTarget,
      """
SELECT name, meta ->> 'i', encode(raw, 'hex') FROM tx_users WHERE id = 7""",
    )).first;
    expect(row[0], "user'7");
    expect(row[1], '7');
    expect(row[2], 'deadbeef');
  });

  test('便携归档 dump→store pg → pg:类型保真 + 覆盖回放', () async {
    final dumpPath = '${tempDir.path}/backup.tdump';
    final exported = await DbTransferService.exportToDump(
      source: _pgSource,
      schemaTables: const {
        'public': ['tx_users'],
      },
      filePath: dumpPath,
    );
    expect(exported.tables, 1);
    expect(exported.rows, 450);

    // 归档是 gzip 压缩的:文件头两字节应为 gzip 魔数 0x1f 0x8b
    final bytes = await File(dumpPath).readAsBytes();
    expect(bytes.length, greaterThan(2));
    expect(bytes[0], 0x1f);
    expect(bytes[1], 0x8b);

    // 目标已有同名表(内容不同):store 覆盖式导入应先 DROP 再重建
    await _run(_pgTarget, 'CREATE TABLE tx_users (id bigint)');
    await _run(_pgTarget, 'INSERT INTO tx_users VALUES (999)');

    final imported = await DbTransferService.importDump(
      target: _pgTarget,
      filePath: dumpPath,
    );
    expect(imported.tables, 1);
    expect(imported.rows, 450);

    expect(
      (await _query(_pgTarget, 'SELECT count(*) FROM tx_users')).first.first,
      450,
    );
    final row = (await _query(
      _pgTarget,
      """
SELECT name, age, price, active, meta ->> 'i', uid::text,
       encode(raw, 'hex'), created_at
FROM tx_users WHERE id = 7""",
    )).first;
    expect(row[0], "user'7");
    expect(row[1], 7); // 7 % 3 != 0 → 非空
    expect('${row[2]}', '8.75'); // 7 * 1.25
    expect(row[3], false); // 7 % 2 != 0
    expect(row[4], '7');
    expect(row[5], '00000000-0000-0000-0000-000000000001');
    expect(row[6], 'deadbeef');
    expect(row[7], isNotNull);
    // NULL(9 % 3 == 0)也正确还原
    expect(
      (await _query(_pgTarget, 'SELECT age FROM tx_users WHERE id = 9'))
          .first
          .first,
      isNull,
    );
  });

  test('便携归档 dump→store pg → pg:整库多 schema + 自增续接', () async {
    // 源:两个 schema,一张 serial 自增表 + 一张普通表
    await _runAll(_pgSource, [
      'DROP SCHEMA IF EXISTS dmp_a CASCADE',
      'DROP SCHEMA IF EXISTS dmp_b CASCADE',
      'CREATE SCHEMA dmp_a',
      'CREATE SCHEMA dmp_b',
      'CREATE TABLE dmp_a.orders (id serial PRIMARY KEY, amount numeric)',
      'CREATE TABLE dmp_b.items (id bigint PRIMARY KEY, name text)',
      'INSERT INTO dmp_a.orders (amount) SELECT i*1.5 FROM generate_series(1,30) i',
      "INSERT INTO dmp_b.items SELECT i, 'item'||i FROM generate_series(1,40) i",
    ]);
    await _runAll(_pgTarget, [
      'DROP SCHEMA IF EXISTS dmp_a CASCADE',
      'DROP SCHEMA IF EXISTS dmp_b CASCADE',
    ]);

    final dumpPath = '${tempDir.path}/whole.tdump';
    // 整库导出会带上 public.tx_users 等,这里只关心 dmp_a/dmp_b 用多 schema 精确选择
    final exported = await DbTransferService.exportToDump(
      source: _pgSource,
      schemaTables: const {'dmp_a': [], 'dmp_b': []},
      filePath: dumpPath,
    );
    expect(exported.tables, 2);
    expect(exported.rows, 70);

    final imported = await DbTransferService.importDump(target: _pgTarget, filePath: dumpPath);
    expect(imported.tables, 2);
    expect(imported.rows, 70);

    // 多 schema → 保留限定名
    expect(
      (await _query(_pgTarget, 'SELECT count(*) FROM dmp_a.orders')).first.first,
      30,
    );
    expect(
      (await _query(_pgTarget, 'SELECT count(*) FROM dmp_b.items')).first.first,
      40,
    );
    // serial→IDENTITY 且序列拨到 max:新插入不指定 id 应续到 31
    await _run(_pgTarget, 'INSERT INTO dmp_a.orders (amount) VALUES (100)');
    expect(
      (await _query(_pgTarget, 'SELECT max(id) FROM dmp_a.orders')).first.first,
      31,
    );

    await _runAll(_pgSource, [
      'DROP SCHEMA IF EXISTS dmp_a CASCADE',
      'DROP SCHEMA IF EXISTS dmp_b CASCADE',
    ]);
  });
}
