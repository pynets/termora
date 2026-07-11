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
      (await _query(
        _pgTarget,
        'SELECT count(*) FROM wdb_b.items',
      )).first.first,
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
      _runAll(_pgTarget, ['INSERT INTO wdb_a.orders (id, amount) VALUES (1, 0)']),
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
        db
            .select('SELECT age FROM tx_users WHERE id = 3')
            .first
            .values
            .first,
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
    final row = (await _query(_pgTarget, """
SELECT name, meta ->> 'i', encode(raw, 'hex') FROM tx_users WHERE id = 7""")).first;
    expect(row[0], "user'7");
    expect(row[1], '7');
    expect(row[2], 'deadbeef');
  });
}
