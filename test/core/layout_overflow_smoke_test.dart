import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:termora/core/data/app_database.dart';
import 'package:termora/features/database/view/database_page.dart';
import 'package:termora/features/notes/data/note_store.dart';
import 'package:termora/features/notes/view/notes_page.dart';
import 'package:termora/features/remote/view/remote_page.dart';
import 'package:termora/features/remote/view/widgets/transfer_log_dialog.dart';
import 'package:termora/features/settings/view/settings_dialog.dart';

/// 全页面多尺寸溢出体检(flutter-fix-layout-issues /
/// flutter-build-responsive-layout 官方 skill 方法论的自动化):
/// 在大/中/窄/极窄窗口下 build 各页面,任何 RenderFlex overflow、
/// unbounded viewport 等布局异常都会作为测试失败暴露出来。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const sizes = <Size>[
    Size(1440, 900), // 大屏
    Size(1024, 700), // 中屏
    Size(800, 560), // 窄窗口
    Size(560, 440), // 极窄(分屏/角落小窗)
  ];

  late Directory tempDir;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppDatabase.debugUseDatabase(sqlite3.openInMemory());
    tempDir = Directory.systemTemp.createTempSync('termora_layout_smoke');
    NoteStore.debugDirectoryOverride = tempDir;
  });

  tearDown(() {
    AppDatabase.debugUseDatabase(null);
    NoteStore.debugDirectoryOverride = null;
    tempDir.deleteSync(recursive: true);
  });

  Future<void> pumpAt(
    WidgetTester tester,
    Size size,
    Widget child,
  ) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(child: MaterialApp(home: Scaffold(body: child))),
    );
    // 页面里普遍有异步加载(prefs/磁盘/DB),多 pump 几拍让其收敛;
    // 不用 pumpAndSettle:终端类页面存在常驻定时器会settle不完
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  for (final size in sizes) {
    group('${size.width.toInt()}x${size.height.toInt()}', () {
      testWidgets('远程主机页', (tester) async {
        await pumpAt(tester, size, const RemotePage());
        expect(tester.takeException(), isNull);
      });

      testWidgets('数据库页', (tester) async {
        await pumpAt(tester, size, const DatabasePage());
        expect(tester.takeException(), isNull);
      });

      testWidgets('笔记页', (tester) async {
        await pumpAt(tester, size, const NotesPage());
        expect(tester.takeException(), isNull);
      });

      testWidgets('设置对话框', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              home: Scaffold(
                body: Builder(
                  builder: (context) => Center(
                    child: ElevatedButton(
                      onPressed: () => showSettingsDialog(context),
                      child: const Text('open'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 120));
        }
        expect(tester.takeException(), isNull);
      });

      testWidgets('传输记录页', (tester) async {
        await pumpAt(
          tester,
          size,
          const Center(child: TransferLogDialog(hostNames: {})),
        );
        expect(tester.takeException(), isNull);
      });
    });
  }
}
