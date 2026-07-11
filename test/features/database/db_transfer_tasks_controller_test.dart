// DbTransferTasksController 集成:保存任务 → 解析连接 → 执行 → 回写 lastRun。
// 用 mock SharedPreferences + 本地 SQLite,跑通 provider→service 全链路。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:termora/features/database/controller/database_providers.dart';
import 'package:termora/features/database/domain/db_models.dart';
import 'package:termora/features/database/domain/db_transfer_task.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late String sourcePath;
  late String targetPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('termora_task_ctl');
    sourcePath = '${tempDir.path}/source.db';
    targetPath = '${tempDir.path}/target.db';
    final seed = sqlite3.open(sourcePath);
    seed.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
    final ins = seed.prepare('INSERT INTO t VALUES (?, ?)');
    for (var i = 1; i <= 20; i++) {
      ins.execute([i, 'v$i']);
    }
    ins.close();
    seed.close();
    sqlite3.open(targetPath).close(); // 目标空库
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  Future<ProviderContainer> containerWithConns() async {
    final src = DbConnectionConfig(
      id: 'src',
      name: 'src',
      engine: DbEngine.sqlite,
      database: sourcePath,
    );
    final dst = DbConnectionConfig(
      id: 'dst',
      name: 'dst',
      engine: DbEngine.sqlite,
      database: targetPath,
    );
    // 预置连接到 mock prefs,让 connections provider 的 _load 直接读到
    SharedPreferences.setMockInitialValues({
      'database.connections.v1': jsonEncode([src.toJson(), dst.toJson()]),
    });
    final container = ProviderContainer();
    // 等异步 _load 完成(连接非空)
    for (var i = 0; i < 100; i++) {
      if (container.read(dbConnectionsProvider).isNotEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(container.read(dbConnectionsProvider), hasLength(2));
    return container;
  }

  test('保存迁移任务 → run 执行并回写 lastRun', () async {
    final container = await containerWithConns();
    addTearDown(container.dispose);
    final ctl = container.read(dbTransferTasksProvider.notifier);
    // 等任务 provider 初次 _load
    await Future<void>.delayed(const Duration(milliseconds: 20));

    const task = DbTransferTask(
      id: 'task1',
      name: '同步 t',
      mode: DbTransferMode.migrate,
      sourceConnId: 'src',
      targetConnId: 'dst',
      wholeDatabase: true,
    );
    await ctl.upsert(task);
    expect(container.read(dbTransferTasksProvider), hasLength(1));

    final summary = await ctl.run(task);
    expect(summary.tables, 1);
    expect(summary.rows, 20);

    // 目标库真的有数据
    final db = sqlite3.open(targetPath);
    expect(db.select('SELECT count(*) FROM t').first.values.first, 20);
    db.close();

    // lastRun 已回写并持久化
    final stored = container.read(dbTransferTasksProvider).single;
    expect(stored.lastRunOk, isTrue);
    expect(stored.lastRunAtMs, isNotNull);
    expect(stored.lastRunMessage, contains('1 张表'));

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('database.transfer_tasks.v1');
    expect(raw, isNotNull);
    expect(raw, contains('lastRunOk'));
  });

  test('run:目标连接不存在 → 失败并记录', () async {
    final container = await containerWithConns();
    addTearDown(container.dispose);
    final ctl = container.read(dbTransferTasksProvider.notifier);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    const task = DbTransferTask(
      id: 'bad',
      name: '坏任务',
      mode: DbTransferMode.migrate,
      sourceConnId: 'src',
      targetConnId: 'ghost', // 不存在
      wholeDatabase: true,
    );
    await ctl.upsert(task);
    await expectLater(ctl.run(task), throwsA(anything));

    final stored = container.read(dbTransferTasksProvider).single;
    expect(stored.lastRunOk, isFalse);
    expect(stored.lastRunMessage, contains('目标连接不存在'));
  });
}
