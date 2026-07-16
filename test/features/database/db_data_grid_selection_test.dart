// DbDataGrid 多行选择 + 拷贝的 widget 测试
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termora/features/database/domain/db_models.dart';
import 'package:termora/features/database/view/widgets/db_data_grid.dart';

void main() {
  const output = DbQueryOutput(
    columns: ['id', 'name'],
    rows: [
      [1, 'alice'],
      [2, 'bob'],
      [3, 'carol'],
    ],
  );

  Future<void> pumpGrid(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: DbDataGrid(output: output)),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 捕获写入剪贴板的文本
  List<String> mockClipboard(WidgetTester tester) {
    final captured = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          captured.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    return captured;
  }

  Future<void> ctrl(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }

  testWidgets('单击选中某行,Ctrl+C 复制该行(TSV)', (tester) async {
    final clip = mockClipboard(tester);
    await pumpGrid(tester);

    await tester.tap(find.text('bob'));
    await tester.pump();
    await ctrl(tester, LogicalKeyboardKey.keyC);

    expect(clip, isNotEmpty);
    expect(clip.last, '2\tbob');
  });

  testWidgets('Ctrl+A 全选后 Ctrl+C 复制所有行(TSV,每列 Tab 分隔)', (tester) async {
    final clip = mockClipboard(tester);
    await pumpGrid(tester);

    // 先点一格让网格拿到焦点
    await tester.tap(find.text('alice'));
    await tester.pump();
    await ctrl(tester, LogicalKeyboardKey.keyA);
    await ctrl(tester, LogicalKeyboardKey.keyC);

    expect(clip.last, '1\talice\n2\tbob\n3\tcarol');
  });

  testWidgets('Shift 连选:选头尾之间的所有行', (tester) async {
    final clip = mockClipboard(tester);
    await pumpGrid(tester);

    await tester.tap(find.text('alice')); // 锚点 = 第 1 行
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(find.text('carol')); // 连选到第 3 行
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    await ctrl(tester, LogicalKeyboardKey.keyC);

    expect(clip.last, '1\talice\n2\tbob\n3\tcarol');
  });

  testWidgets('Ctrl 加选:挑不连续的两行', (tester) async {
    final clip = mockClipboard(tester);
    await pumpGrid(tester);

    await tester.tap(find.text('alice'));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(find.text('carol'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await ctrl(tester, LogicalKeyboardKey.keyC);

    expect(clip.last, '1\talice\n3\tcarol');
  });

  testWidgets('无选择时 Ctrl+C 不写剪贴板', (tester) async {
    final clip = mockClipboard(tester);
    await pumpGrid(tester);

    // 不点任何行,直接尝试复制(网格未必有焦点,也不应崩)
    await ctrl(tester, LogicalKeyboardKey.keyC);
    expect(clip, isEmpty);
  });
}
