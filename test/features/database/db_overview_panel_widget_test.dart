// 概览面板渲染冒烟:真实 sqlite 库 + 渲染面板,守住布局约束类回归
// (横滑 KPI 行曾因 stretch + 无界高度炸出 BoxConstraints forces infinite height)
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:termora/features/database/domain/db_models.dart';
import 'package:termora/features/database/view/widgets/db_overview_panel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('DbOverviewPanel 渲染无布局异常', (tester) async {
    final dir = Directory.systemTemp.createTempSync('termora_panel');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/x.db';
    final db = sqlite3.open(path);
    db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
    db.execute("INSERT INTO t VALUES (1, 'a'), (2, 'b')");
    db.close();

    final config = DbConnectionConfig(
      id: 'panel-test',
      name: 'panel-test',
      engine: DbEngine.sqlite,
      database: path,
    );
    SharedPreferences.setMockInitialValues({
      'database.connections.v1': '[${_json(config)}]',
    });

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 900,
              height: 700,
              child: DbOverviewPanel(connectionId: 'panel-test'),
            ),
          ),
        ),
      ),
    );

    // 让连接加载 + 指标采集(真实文件 IO)有机会完成
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 600)),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pump();

    // 渲染过程中不允许有布局/绘制异常(如 stretch 在无界高度下炸约束)
    expect(tester.takeException(), isNull);
    expect(find.byType(DbOverviewPanel), findsOneWidget);

    // 卸载面板,停掉采样定时器,避免 pending timer 报错
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
  });
}

String _json(DbConnectionConfig c) =>
    '{"id":"${c.id}","name":"${c.name}","engine":"${c.engine.name}",'
    '"host":"","port":0,"database":"${c.database}","username":"",'
    '"password":"","useSsl":false}';
