import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termora/core/widgets/slide_select.dart';

/// 复刻 SFTP 结构:pane DragTarget > GestureDetector > SlideSelectArea >
/// ListView > SlideSelectItem > (目录行)DragTarget > Draggable(h) > InkWell
Widget _row(String label, {bool isDir = false}) {
  final core = Draggable<String>(
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
  if (!isDir) return core;
  return DragTarget<String>(
    onWillAcceptWithDetails: (_) => true,
    builder: (c, a, b) => core,
  );
}

void main() {
  final items = [for (var i = 0; i < 5; i++) 'item$i'];

  testWidgets('真实结构:空白按下往上拖 = 框选', (tester) async {
    final c = SlideSelectController<String>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const SizedBox(height: 40), // header 占位
              Expanded(
                child: DragTarget<String>(
                  onWillAcceptWithDetails: (_) => true,
                  builder: (context, cand, rej) => DecoratedBox(
                    decoration: const BoxDecoration(),
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onSecondaryTapUp: (_) {},
                      child: SlideSelectArea<String>(
                        controller: c,
                        items: () => items,
                        child: ListView.builder(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          itemCount: items.length,
                          itemBuilder: (context, i) => SlideSelectItem<String>(
                            controller: c,
                            index: i,
                            child: _row(items[i], isDir: i == 0),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      const Offset(200, 400), // 行(共 ~150+44px)下方空白
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
    );
    await gesture.moveTo(const Offset(200, 300));
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.text('item2')));
    await tester.pump();
    await gesture.up();
    await tester.pump(const Duration(seconds: 1));

    expect(c.selected, {'item2', 'item3', 'item4'});
  });
}
