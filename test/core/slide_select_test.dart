import 'package:flutter_test/flutter_test.dart';
import 'package:termora/core/widgets/slide_select.dart';

void main() {
  group('SlideSelectController', () {
    test('toggle 单选/取消', () {
      final c = SlideSelectController<String>();
      c.toggle('a');
      expect(c.selected, {'a'});
      c.toggle('a');
      expect(c.hasSelection, isFalse);
    });

    test('selectAll / clear', () {
      final c = SlideSelectController<String>();
      c.selectAll(['a', 'b', 'c']);
      expect(c.selected, {'a', 'b', 'c'});
      c.clear();
      expect(c.hasSelection, isFalse);
    });

    test('retainWhere 只留仍存在的条目', () {
      final c = SlideSelectController<String>();
      c.selectAll(['a', 'b', 'c']);
      c.retainWhere({'b'}.contains);
      expect(c.selected, {'b'});
    });

    test('通知次数:无变化的 retainWhere/clear 不通知', () {
      final c = SlideSelectController<String>();
      var notified = 0;
      c.addListener(() => notified++);
      c.clear();
      c.retainWhere((_) => true);
      expect(notified, 0);
      c.toggle('a');
      expect(notified, 1);
    });
  });
}
