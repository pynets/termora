import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termora/core/widgets/slide_select.dart';

Widget _harness(SlideSelectController<String> c, List<String> items) {
  return MaterialApp(
    home: Scaffold(
      body: SlideSelectArea<String>(
        controller: c,
        items: () => items,
        child: ListView.builder(
          itemCount: items.length,
          itemBuilder: (context, i) => SlideSelectItem<String>(
            controller: c,
            index: i,
            child: SizedBox(height: 30, child: Text(items[i])),
          ),
        ),
      ),
    ),
  );
}

void main() {
  final items = [for (var i = 0; i < 10; i++) 'item$i'];

  testWidgets('鼠标垂直拖动 = 区间多选', (tester) async {
    final c = SlideSelectController<String>();
    await tester.pumpWidget(_harness(c, items));

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('item2')),
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
    );
    await gesture.moveTo(tester.getCenter(find.text('item6')));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(c.selected, {'item2', 'item3', 'item4', 'item5', 'item6'});
  });

  testWidgets('原地单击 = 替换选中单项;⌘+单击 = toggle', (tester) async {
    final c = SlideSelectController<String>();
    await tester.pumpWidget(_harness(c, items));

    await tester.tapAt(
      tester.getCenter(find.text('item3')),
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
    );
    await tester.pump();
    expect(c.selected, {'item3'});

    // 点另一行:替换而非累加
    await tester.tapAt(
      tester.getCenter(find.text('item5')),
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
    );
    await tester.pump();
    expect(c.selected, {'item5'});

    // ⌘+单击:追加/移除
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.tapAt(
      tester.getCenter(find.text('item3')),
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
    );
    await tester.pump();
    expect(c.selected, {'item5', 'item3'});
    await tester.tapAt(
      tester.getCenter(find.text('item3')),
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
    );
    await tester.pump();
    expect(c.selected, {'item5'});
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  });

  testWidgets('二次框选 = 替换而非累加', (tester) async {
    final c = SlideSelectController<String>();
    await tester.pumpWidget(_harness(c, items));

    Future<void> drag(String from, String to) async {
      final g = await tester.startGesture(
        tester.getCenter(find.text(from)),
        kind: PointerDeviceKind.mouse,
        buttons: kPrimaryMouseButton,
      );
      await g.moveTo(tester.getCenter(find.text(to)));
      await tester.pump();
      await g.up();
      await tester.pump();
    }

    await drag('item1', 'item3');
    expect(c.selected, {'item1', 'item2', 'item3'});
    await drag('item6', 'item7');
    expect(c.selected, {'item6', 'item7'});
  });

  testWidgets('横向为主的拖动不触发多选', (tester) async {
    final c = SlideSelectController<String>();
    await tester.pumpWidget(_harness(c, items));

    final start = tester.getCenter(find.text('item2'));
    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
    );
    await gesture.moveTo(start + const Offset(60, 4));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(c.hasSelection, isFalse);
  });
}
