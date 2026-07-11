@Tags(['smoke'])
library;

// 传输功能(导出/导入/迁移)的 ClickHouse 冒烟测试 — 需要本地 8124 端口临时 CH:
//   clickhouse server -- --http_port=8124 --tcp_port=19004 --listen_host=127.0.0.1
//   flutter test --run-skipped --tags smoke test/features/database/db_transfer_ch_smoke_test.dart
// 测试自建/自清理数据(transfer_demo / transfer_target 库),不依赖预置种子。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:termora/features/database/data/db_service.dart';
import 'package:termora/features/database/data/db_transfer_service.dart';
import 'package:termora/features/database/domain/db_models.dart';

DbConnectionConfig _ch(String id, String database) => DbConnectionConfig(
  id: id,
  name: id,
  engine: DbEngine.clickhouse,
  host: '127.0.0.1',
  port: 8124,
  database: database,
  username: 'default',
  password: '',
);

final _chSource = _ch('ch-src', 'transfer_demo');
final _chTarget = _ch('ch-dst', 'transfer_target');

/// CH HTTP 不支持多语句,逐条执行
Future<void> _run(DbConnectionConfig config, List<String> statements) async {
  final conn = await DbService.open(config);
  try {
    for (final statement in statements) {
      await DbService.runSql(conn, statement);
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
    await _run(_ch('ch-admin', 'default'), [
      'CREATE DATABASE IF NOT EXISTS transfer_demo',
      'CREATE DATABASE IF NOT EXISTS transfer_target',
    ]);
  });

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('termora_ch_transfer');
    // 源表:Int64(JSON 里以字符串回读)/ Nullable / Bool / DateTime / 引号文本
    await _run(_chSource, [
      'DROP TABLE IF EXISTS transfer_demo.events',
      '''
CREATE TABLE transfer_demo.events (
  id Int64,
  name String,
  score Float64,
  tag Nullable(String),
  flag Bool,
  ts DateTime
) ENGINE = MergeTree ORDER BY id''',
      """
INSERT INTO transfer_demo.events
SELECT number + 1,
       concat('user\\'', toString(number + 1)),
       (number + 1) * 0.5,
       if((number + 1) % 3 = 0, NULL, concat('tag', toString(number + 1))),
       (number + 1) % 2 = 0,
       toDateTime('2026-01-01 00:00:00') + toIntervalHour(number + 1)
FROM numbers(450)""",
      'DROP TABLE IF EXISTS transfer_target.events',
      'DROP TABLE IF EXISTS transfer_target.gadgets',
    ]);
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('迁移 ch → ch:同引擎类型保真(Nullable 不重复包装)+ 覆盖', () async {
    final summary = await DbTransferService.migrate(
      source: _chSource,
      target: _chTarget,
      schema: 'transfer_demo',
      tables: ['events'],
    );
    expect(summary.rows, 450);

    expect(
      (await _query(_chTarget, 'SELECT count() FROM events')).first.first,
      '450',
    );
    // 同引擎沿用原始类型;排序键(主键)保留
    final types = await _query(_chTarget, """
SELECT name, type, is_in_primary_key FROM system.columns
WHERE database = 'transfer_target' AND table = 'events' ORDER BY position""");
    final byName = {for (final r in types) r[0]: r[1]};
    expect(byName['id'], 'Int64');
    expect(byName['tag'], 'Nullable(String)');
    expect(byName['flag'], 'Bool');
    expect(
      types.firstWhere((r) => r[0] == 'id')[2],
      1, // is_in_primary_key
    );

    final row = (await _query(_chTarget, """
SELECT name, tag, flag, toString(ts) FROM events WHERE id = 1""")).first;
    expect(row[0], "user'1");
    expect(row[1], 'tag1');
    expect(row[2], false);
    expect(row[3], '2026-01-01 01:00:00');
    expect(
      (await _query(
        _chTarget,
        'SELECT tag FROM events WHERE id = 3',
      )).first.first,
      isNull,
    );

    // 再迁一次:覆盖不翻倍
    await DbTransferService.migrate(
      source: _chSource,
      target: _chTarget,
      schema: 'transfer_demo',
      tables: ['events'],
    );
    expect(
      (await _query(_chTarget, 'SELECT count() FROM events')).first.first,
      '450',
    );
  });

  test('迁移 ch → sqlite:跨引擎类型映射(Int64 字符串回读→整型)', () async {
    final sqlitePath = '${tempDir.path}/target.db';
    sqlite3.open(sqlitePath).close();

    final summary = await DbTransferService.migrate(
      source: _chSource,
      target: DbConnectionConfig(
        id: 'lite',
        name: 'lite',
        engine: DbEngine.sqlite,
        database: sqlitePath,
      ),
      schema: 'transfer_demo',
      tables: ['events'],
    );
    expect(summary.rows, 450);

    final db = sqlite3.open(sqlitePath);
    try {
      expect(
        db.select('SELECT count(*) FROM events').first.values.first,
        450,
      );
      // Int64 在 JSONCompact 里是字符串,落到 INTEGER 亲和列应转回整数
      final row = db
          .select(
            'SELECT id, name, tag, flag, ts FROM events WHERE id = 1',
          )
          .first
          .values;
      expect(row[0], 1);
      expect(row[1], "user'1");
      expect(row[2], 'tag1');
      expect(row[3], 0); // Bool → INTEGER
      expect('${row[4]}', startsWith('2026-01-01 01:00'));
      expect(
        db
            .select('SELECT tag FROM events WHERE id = 3')
            .first
            .values
            .first,
        isNull,
      );
    } finally {
      db.close();
    }
  });

  test('迁移 sqlite → ch:MergeTree 建表 + unhex 二进制', () async {
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

    final summary = await DbTransferService.migrate(
      source: DbConnectionConfig(
        id: 'lite-src',
        name: 'lite-src',
        engine: DbEngine.sqlite,
        database: sqlitePath,
      ),
      target: _chTarget,
      schema: 'main',
      tables: ['gadgets'],
    );
    expect(summary.rows, 120);

    final types = await _query(_chTarget, """
SELECT name, type FROM system.columns
WHERE database = 'transfer_target' AND table = 'gadgets' ORDER BY position""");
    final byName = {for (final r in types) r[0]: r[1]};
    expect(byName['id'], 'Int64');
    expect(byName['label'], 'String');
    expect(byName['weight'], 'Nullable(Float64)');
    expect(byName['data'], 'Nullable(String)'); // blob → String

    expect(
      (await _query(_chTarget, 'SELECT count() FROM gadgets')).first.first,
      '120',
    );
    final row = (await _query(_chTarget, """
SELECT label, weight, hex(data) FROM gadgets WHERE id = 1""")).first;
    expect(row[0], "g'1");
    expect(row[1], 0.25);
    expect(row[2], 'CAFE'); // unhex 写入的原始字节
  });

  test('导出 ch 脚本再导入 ch:等价回放', () async {
    final scriptPath = '${tempDir.path}/dump.sql';
    final exported = await DbTransferService.exportToScript(
      source: _chSource,
      schema: 'transfer_demo',
      tables: ['events'],
      targetEngine: DbEngine.clickhouse,
      filePath: scriptPath,
    );
    expect(exported.rows, 450);

    final script = await File(scriptPath).readAsString();
    expect(script, contains('DROP TABLE IF EXISTS `events`'));
    expect(script, contains('ENGINE = MergeTree ORDER BY (`id`)'));

    final imported = await DbTransferService.importScript(
      target: _chTarget,
      script: script,
    );
    // DROP + CREATE + 3 批 INSERT
    expect(imported.statements, 5);
    expect(
      (await _query(_chTarget, 'SELECT count() FROM events')).first.first,
      '450',
    );
    final row = (await _query(_chTarget, """
SELECT name, tag FROM events WHERE id = 7""")).first;
    expect(row[0], "user'7");
    expect(row[1], 'tag7');
  });
}
