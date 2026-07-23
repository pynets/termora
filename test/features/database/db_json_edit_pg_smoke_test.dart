@Tags(['smoke'])
library;

// JSON 单元格编辑的 PostgreSQL 冒烟测试 — 需要本地 55432 临时 PG:
//   flutter test --run-skipped --tags smoke test/features/database/db_json_edit_pg_smoke_test.dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:postgres/postgres.dart';
import 'package:termora/features/database/data/postgres_service.dart';

// 用独立数据库,避免与「整库迁移」等扫描 public 的并发测试互相踩到中间态
const _dbName = 'json_edit_probe';

Connection? _conn;

Future<Connection> _open([String db = _dbName]) async {
  return await Connection.open(
    Endpoint(
      host: 'localhost',
      port: 55432,
      database: db,
      username: 'postgres',
      password: '',
    ),
    settings: const ConnectionSettings(sslMode: SslMode.disable),
  );
}

Future<Connection> _probe() async => _conn ??= await _open();

void main() {
  setUpAll(() async {
    final admin = await _open('postgres');
    try {
      await admin.execute('CREATE DATABASE $_dbName');
    } catch (_) {} // 已存在
    await admin.close();
  });

  setUp(() async {
    final conn = await _probe();
    await conn.execute('DROP TABLE IF EXISTS je_docs');
    await conn.execute('''
CREATE TABLE je_docs (
  id int PRIMARY KEY,
  jb jsonb,
  js json,
  txt text
)''');
    await conn.execute('''
INSERT INTO je_docs VALUES
 (1, '{"a":1,"b":"x"}', '{"k":true}', 'plain'),
 (2, '[1,2,3]', 'null', null),
 (3, '"scalar"', '42', 'p3')''');
  });

  tearDownAll(() async {
    await _conn?.execute('DROP TABLE IF EXISTS je_docs');
    await _conn?.close();
    _conn = null;
  });

  test('读取:json/jsonb 显示为合法 JSON 文本(不是 Dart 的 {a: 1})', () async {
    final conn = await _probe();
    final (output, _, ctx) = await PostgresService.fetchTableData(
      conn,
      'public',
      'je_docs',
      orderBy: 'id',
    );
    expect(ctx?.editable, isTrue);

    final cols = output.columns;
    final jb = cols.indexOf('jb');
    final js = cols.indexOf('js');

    // 第 1 行:对象 → 合法 JSON,能被 jsonDecode 解回
    final r0 = output.rows[0];
    expect(r0[jb], isA<String>());
    expect(jsonDecode(r0[jb] as String), {'a': 1, 'b': 'x'});
    expect(jsonDecode(r0[js] as String), {'k': true});
    // 不能再是 Dart map 的 toString(缺引号)
    expect(r0[jb], isNot(contains('a: 1')));

    // 第 2 行:数组 / 标量也都是合法 JSON
    expect(jsonDecode(output.rows[1][jb] as String), [1, 2, 3]);
    expect(jsonDecode(output.rows[2][jb] as String), 'scalar');
    expect(jsonDecode(output.rows[2][js] as String), 42);
  });

  test('保存:改 jsonb 单元格为新 JSON,能落库并回读一致', () async {
    final conn = await _probe();
    const newJson = '{"a":2,"c":[10,20],"nested":{"ok":true}}';
    final saved = await PostgresService.updateCell(
      conn,
      schema: 'public',
      table: 'je_docs',
      column: 'jb',
      dataType: 'jsonb',
      pkValues: {'id': 1},
      newValue: newJson,
    );
    // 回读值仍是合法 JSON 且语义一致(jsonb 会重排键,故比对解码结果)
    expect(jsonDecode(saved as String), jsonDecode(newJson));

    // 直接查库确认真的写进去了
    final check = await conn.execute(
      r"SELECT jb->'nested'->>'ok', jb->>'a' FROM je_docs WHERE id = 1",
    );
    expect(check.first[0], 'true');
    expect(check.first[1], '2');
  });

  test('保存:非法 JSON 应报错(而不是静默写坏)', () async {
    final conn = await _probe();
    await expectLater(
      PostgresService.updateCell(
        conn,
        schema: 'public',
        table: 'je_docs',
        column: 'jb',
        dataType: 'jsonb',
        pkValues: {'id': 1},
        newValue: '{not valid json}',
      ),
      throwsA(anything),
    );
  });

  test('保存:json(非 jsonb)列同样可编辑保存', () async {
    final conn = await _probe();
    final saved = await PostgresService.updateCell(
      conn,
      schema: 'public',
      table: 'je_docs',
      column: 'js',
      dataType: 'json',
      pkValues: {'id': 2},
      newValue: '{"updated":true}',
    );
    expect(jsonDecode(saved as String), {'updated': true});
  });
}
