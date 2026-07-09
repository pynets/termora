import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termora/features/notes/domain/note_find.dart';

void main() {
  group('matches', () {
    test('大小写不敏感,非重叠,按起点升序', () {
      final m = NoteFind.matches('Abc abc ABC', 'abc');
      expect(m.map((r) => r.start), [0, 4, 8]);
      // "aa" 在 "aaa" 里只命中一次(非重叠)
      expect(NoteFind.matches('aaa', 'aa'), hasLength(1));
    });

    test('空查询/无命中返回空', () {
      expect(NoteFind.matches('abc', ''), isEmpty);
      expect(NoteFind.matches('abc', 'xyz'), isEmpty);
    });
  });

  group('activeIndexFor', () {
    final matches = NoteFind.matches('x一x一x一', '一');

    test('取光标之后的第一个命中,末尾回绕到 0', () {
      expect(NoteFind.activeIndexFor(matches, 0), 0);
      expect(NoteFind.activeIndexFor(matches, 2), 1);
      expect(NoteFind.activeIndexFor(matches, 6), 0); // 光标在最后命中之后
      expect(NoteFind.activeIndexFor(const [], 0), -1);
    });
  });

  group('替换', () {
    test('replaceMatch 替换单处,光标落在替换文本后', () {
      final v = NoteFind.replaceMatch(
        const TextEditingValue(text: '甲乙丙'),
        const TextRange(start: 1, end: 2),
        '(乙换成了这个)',
      );
      expect(v.text, '甲(乙换成了这个)丙');
      expect(v.selection.baseOffset, 1 + 8);
    });

    test('replaceAll 全部替换并返回数量;替换词含查询词不死循环', () {
      final (v, count) = NoteFind.replaceAll(
        const TextEditingValue(text: 'a b a'),
        'a',
        'aa',
      );
      expect(v.text, 'aa b aa');
      expect(count, 2);

      final (unchanged, zero) = NoteFind.replaceAll(
        const TextEditingValue(text: 'xyz'),
        'q',
        'r',
      );
      expect(unchanged.text, 'xyz');
      expect(zero, 0);
    });
  });
}
