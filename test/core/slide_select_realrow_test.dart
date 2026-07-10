import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termora/core/widgets/slide_select.dart';

/// 复刻 SFTP _EntryRow 的手势栈:Draggable(horizontal) > MouseRegion >
/// GestureDetector(secondaryTap) > Material > InkWell(tap+doubleTap)
Widget _row(String label) {
  return Draggable<String>(
    data: label,
    affinity: Axis.horizontal,
    dragAnchorStrategy: pointerDragAnchorStrategy,
    feedback: const SizedBox(width: 60, height: 20),
    child: MouseRegion(
      child: GestureDetector(
        onSecondaryTapUp: (_) {},
        child: Material(
          child: InkWell(
            onDoubleTap: () {},
            onTap: () {},
            child: SizedBox(height: 30, child: Text(label)),
          ),
        ),
      ),
    ),
  );
}

void main() {
  final items = [for (var i = 0; i < 10; i++) 'item$i'];

  testWidgets('真实行结构下垂直拖动多选', (tester) async {
    final c = SlideSelectController<String>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SlideSelectArea<String>(
            controller: c,
            items: () => items,
            child: ListView.builder(
              itemCount: items.length,
              itemBuilder: (context, i) => SlideSelectItem<String>(
                controller: c,
                index: i,
                child: _row(items[i]),
              ),
            ),
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('item2')),
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
    );
    await gesture.moveTo(tester.getCenter(find.text('item6')));
    await tester.pump();
    await gesture.up();
    await tester.pump(const Duration(seconds: 1));

    expect(c.selected, {'item2', 'item3', 'item4', 'item5', 'item6'});
  });

  testWidgets('真实行结构下单击 toggle', (tester) async {
    final c = SlideSelectController<String>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SlideSelectArea<String>(
            controller: c,
            items: () => items,
            child: ListView.builder(
              itemCount: items.length,
              itemBuilder: (context, i) => SlideSelectItem<String>(
                controller: c,
                index: i,
                child: _row(items[i]),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tapAt(
      tester.getCenter(find.text('item3')),
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
    );
    await tester.pump(const Duration(seconds: 1));
    expect(c.selected, {'item3'});
  });
}
