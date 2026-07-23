// 单元格详情弹窗:JSON 美化 / 编辑保存 / 只读 / 设为 NULL
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termora/features/database/view/widgets/cell_detail_dialog.dart';

void main() {
  Future<CellDetailResult?> open(
    WidgetTester tester, {
    required String value,
    required bool editable,
    bool isNull = false,
  }) async {
    CellDetailResult? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showCellDetailDialog(
                  context,
                  column: 'payload',
                  value: value,
                  editable: editable,
                  isNull: isNull,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('JSON 默认美化显示(带缩进换行)', (tester) async {
    await open(tester, value: '{"a":1,"b":[2,3]}', editable: false);
    // 美化后应有缩进换行
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, contains('\n'));
    expect(field.controller!.text, contains('"a": 1'));
    expect(field.readOnly, isTrue); // 只读
  });

  testWidgets('可编辑:改内容后保存,返回新值', (tester) async {
    CellDetailResult? captured;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                captured = await showCellDetailDialog(
                  context,
                  column: 'note',
                  value: 'hello',
                  editable: true,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'hello world');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(captured, isNotNull);
    expect(captured!.setNull, isFalse);
    expect(captured!.value, 'hello world');
  });

  testWidgets('可编辑:设为 NULL', (tester) async {
    CellDetailResult? captured;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                captured = await showCellDetailDialog(
                  context,
                  column: 'note',
                  value: 'x',
                  editable: true,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('设为 NULL'));
    await tester.pumpAndSettle();

    expect(captured, isNotNull);
    expect(captured!.setNull, isTrue);
  });

  testWidgets('复制按钮把内容写入剪贴板', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
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

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showCellDetailDialog(
                context,
                column: 'c',
                value: 'copy-me',
                editable: false,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制'));
    await tester.pump();
    expect(copied.last, 'copy-me');
  });
}
