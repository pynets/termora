// DbMetricsService(SQLite)端到端:计数 / 行数 / topTables 排序 / 文件大小
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:termora/features/database/data/db_metrics_service.dart';
import 'package:termora/features/database/domain/db_metrics.dart';
import 'package:termora/features/database/domain/db_models.dart';

void main() {
  late Directory tempDir;
  late String dbPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('termora_metrics');
    dbPath = '${tempDir.path}/demo.db';
    final db = sqlite3.open(dbPath);
    db.execute('''
CREATE TABLE big (id INTEGER PRIMARY KEY, v TEXT);
CREATE TABLE small (id INTEGER PRIMARY KEY);
CREATE VIEW big_v AS SELECT * FROM big;
''');
    final ins = db.prepare('INSERT INTO big (v) VALUES (?)');
    for (var i = 0; i < 300; i++) {
      ins.execute(['row$i']);
    }
    ins.close();
    final ins2 = db.prepare('INSERT INTO small DEFAULT VALUES');
    for (var i = 0; i < 5; i++) {
      ins2.execute([]);
    }
    ins2.close();
    db.close();
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  test('sqlite 指标:计数/行数/排序/文件大小', () async {
    final config = DbConnectionConfig(
      id: 'm',
      name: 'm',
      engine: DbEngine.sqlite,
      database: dbPath,
    );
    final m = await DbMetricsService.load(config);

    expect(m.engine, DbEngine.sqlite);
    expect(m.version, isNotEmpty);
    expect(m.databaseBytes, greaterThan(0));
    expect(m.tableCount, 2); // big + small(视图不计)
    expect(m.viewCount, 1);
    expect(m.approxRows, 305); // 300 + 5
    expect(m.schemaCount, 1);

    // topTables 按行数降序:big(300) 在 small(5) 前
    expect(m.topTables.first.table, 'big');
    expect(m.topTables.first.rows, 300);
    expect(m.topTables.map((t) => t.table), ['big', 'small']);
    // sqlite 无逐表体量 → bytes 为 0(视图会走行数图)
    expect(m.topTables.every((t) => t.bytes == 0), isTrue);
  });

  test('prettyBytes / prettyCount / prettyDuration', () {
    expect(prettyBytes(0), '—');
    expect(prettyBytes(512), '512 B');
    expect(prettyBytes(1536), '1.5 KB');
    expect(prettyBytes(5 * 1024 * 1024), '5.0 MB');
    expect(prettyCount(999), '999');
    expect(prettyCount(1500), '1.5k');
    expect(prettyCount(2500000), '2.5M');
    expect(prettyDuration(const Duration(minutes: 8)), '8m');
    expect(prettyDuration(const Duration(hours: 5, minutes: 12)), '5h 12m');
    expect(prettyDuration(const Duration(days: 3, hours: 4)), '3d 4h');
  });
}
