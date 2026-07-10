import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termora/core/widgets/slide_select.dart';

void main() {
  final items = [for (var i = 0; i < 5; i++) 'item$i'];

  testWidgets('空白处按下往上拖 = 框选', (tester) async {
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
                child: SizedBox(height: 30, child: Text(items[i])),
              ),
            ),
          ),
        ),
      ),
    );

    // 5 行共 150px;在下方空白(y=300)按下,往上拖到 item2
    final blank = const Offset(200, 300);
    final gesture = await tester.startGesture(
      blank,
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
    );
    // 分几步向上移,确保跨过 slop 与多行
    await gesture.moveTo(const Offset(200, 200));
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.text('item4')));
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.text('item2')));
    await tester.pump();

    // 选框应该在画(marquee 激活)
    expect(c.verticalIntent, isTrue);

    await gesture.up();
    await tester.pump();
    expect(c.selected, {'item2', 'item3', 'item4'});
  });
}
