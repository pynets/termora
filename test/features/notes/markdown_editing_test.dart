import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termora/features/notes/domain/markdown_editing.dart';

void main() {
  TextEditingValue value(String text, int start, [int? end]) => TextEditingValue(
    text: text,
    selection: TextSelection(baseOffset: start, extentOffset: end ?? start),
  );

  group('toggleInline', () {
    test('包裹选区并保持内容选中', () {
      final r = MarkdownEditing.toggleInline(value('你好世界', 0, 2), '**');
      expect(r.text, '**你好**世界');
      expect(r.text.substring(r.selection.start, r.selection.end), '你好');
    });

    test('再次触发解包(外侧紧贴标记)', () {
      final wrapped = MarkdownEditing.toggleInline(value('你好世界', 0, 2), '**');
      final r = MarkdownEditing.toggleInline(wrapped.text == '**你好**世界'
          ? value(wrapped.text, 2, 4)
          : wrapped, '**');
      expect(r.text, '你好世界');
      expect(r.text.substring(r.selection.start, r.selection.end), '你好');
    });

    test('选区自带标记也能解包', () {
      final r = MarkdownEditing.toggleInline(value('**加粗**后', 0, 6), '**');
      expect(r.text, '加粗后');
    });

    test('无选区插入一对标记,光标停中间', () {
      final r = MarkdownEditing.toggleInline(value('前后', 1), '~~');
      expect(r.text, '前~~~~后');
      expect(r.selection.baseOffset, 3);
    });
  });

  group('行级操作', () {
    test('toggleLinePrefix 全部加前缀,再触发全部去掉', () {
      final v = value('甲\n乙\n丙', 0, 5);
      final added = MarkdownEditing.toggleLinePrefix(v, '- ');
      expect(added.text, '- 甲\n- 乙\n- 丙');
      final removed = MarkdownEditing.toggleLinePrefix(added, '- ');
      expect(removed.text, '甲\n乙\n丙');
    });

    test('toggleLinePrefix 换类型时先剥旧列表前缀,不叠加', () {
      final v = value('- 甲\n- 乙', 0, 7);
      final r = MarkdownEditing.toggleLinePrefix(v, '- [ ] ');
      expect(r.text, '- [ ] 甲\n- [ ] 乙');
    });

    test('toggleOrderedList 顺序编号与去编号,空行跳过', () {
      final v = value('甲\n\n乙', 0, 4);
      final r = MarkdownEditing.toggleOrderedList(v);
      expect(r.text, '1. 甲\n\n2. 乙');
      final back = MarkdownEditing.toggleOrderedList(r);
      expect(back.text, '甲\n\n乙');
    });

    test('setHeading 设级/换级/同级取消', () {
      expect(MarkdownEditing.setHeading(value('标题', 0), 2).text, '## 标题');
      expect(
        MarkdownEditing.setHeading(value('## 标题', 0), 3).text,
        '### 标题',
      );
      expect(MarkdownEditing.setHeading(value('## 标题', 0), 2).text, '标题');
    });

    test('光标不在行首也作用于整行', () {
      final r = MarkdownEditing.toggleLinePrefix(value('这一行', 2), '> ');
      expect(r.text, '> 这一行');
    });
  });

  group('插入', () {
    test('insertLink 用选区当文字,选中 url 占位', () {
      final r = MarkdownEditing.insertLink(value('看官网这里', 1, 3));
      expect(r.text, '看[官网](url)这里');
      expect(r.text.substring(r.selection.start, r.selection.end), 'url');
    });

    test('insertLink 无选区给完整占位', () {
      final r = MarkdownEditing.insertLink(value('', 0));
      expect(r.text, '[链接文字](url)');
    });

    test('insertImage 选中地址占位', () {
      final r = MarkdownEditing.insertImage(value('图:', 2));
      expect(r.text, '图:![描述](图片地址)');
      expect(r.text.substring(r.selection.start, r.selection.end), '图片地址');
    });

    test('insertBlock 行中插入自动补空行,光标按偏移落位', () {
      final r = MarkdownEditing.insertBlock(
        value('正文', 2),
        '```\n\n```',
        caretOffset: 4,
      );
      expect(r.text, '正文\n\n```\n\n```');
      expect(r.selection.baseOffset, 8); // ``` 与 ``` 之间
    });

    test('insertBlock 在空文档直接插入', () {
      final r = MarkdownEditing.insertBlock(value('', 0), '---');
      expect(r.text, '---');
    });
  });

  group('autoContinueOnNewline(回车续行)', () {
    /// 模拟在 [old] 的光标 [at] 处敲回车
    TextEditingValue enter(String old, int at) {
      final oldValue = value(old, at);
      final newText = '${old.substring(0, at)}\n${old.substring(at)}';
      return MarkdownEditing.autoContinueOnNewline(
        oldValue,
        value(newText, at + 1),
      );
    }

    test('无序列表续 - 前缀', () {
      final r = enter('- 第一项', 5);
      expect(r.text, '- 第一项\n- ');
      expect(r.selection.baseOffset, r.text.length);
    });

    test('任务列表续未勾选框', () {
      final r = enter('- [x] 做完了', 9);
      expect(r.text, '- [x] 做完了\n- [ ] ');
    });

    test('有序列表编号递增,保留缩进', () {
      final r = enter('  2. 乙', 6);
      expect(r.text, '  2. 乙\n  3. ');
    });

    test('引用行续 > 前缀', () {
      final r = enter('> 一句', 4);
      expect(r.text, '> 一句\n> ');
    });

    test('空项回车退出列表(前缀连同换行一起删掉)', () {
      final r = enter('- 甲\n- ', 6);
      expect(r.text, '- 甲\n');
      expect(r.selection.baseOffset, 4);
    });

    test('普通行回车不干预;行中间回车不干预粘贴', () {
      expect(enter('普通段落', 4).text, '普通段落\n');
      // 多字符变化(粘贴)原样放行
      final pasted = MarkdownEditing.autoContinueOnNewline(
        value('- a', 3),
        value('- a\nxy', 6),
      );
      expect(pasted.text, '- a\nxy');
    });
  });

  group('Tab 缩进', () {
    test('光标在列表行:整行缩进,光标右移', () {
      final r = MarkdownEditing.indentLines(value('- 项目', 3));
      expect(r.text, '  - 项目');
      expect(r.selection.baseOffset, 5);
    });

    test('光标在普通行:光标处插两空格', () {
      final r = MarkdownEditing.indentLines(value('ab', 1));
      expect(r.text, 'a  b');
      expect(r.selection.baseOffset, 3);
    });

    test('多行选区:每个非空行缩进,选区跟随;Shift+Tab 还原', () {
      final v = value('- 甲\n\n- 乙', 0, 8);
      final indented = MarkdownEditing.indentLines(v);
      expect(indented.text, '  - 甲\n\n  - 乙');
      expect(indented.selection.start, 2);
      expect(indented.selection.end, 12);

      final back = MarkdownEditing.outdentLines(indented);
      expect(back.text, '- 甲\n\n- 乙');
    });

    test('反缩进最多去两空格,不足则去实际数量', () {
      final r = MarkdownEditing.outdentLines(value(' x', 2));
      expect(r.text, 'x');
      expect(r.selection.baseOffset, 1);
    });
  });

  group('toggleTaskAt', () {
    test('翻转第 n 个任务,支持引用内任务,越界原样返回', () {
      const text = '- [ ] 甲\n- 普通项\n> - [x] 乙\n- [ ] 丙';
      expect(
        MarkdownEditing.toggleTaskAt(text, 0),
        '- [x] 甲\n- 普通项\n> - [x] 乙\n- [ ] 丙',
      );
      expect(
        MarkdownEditing.toggleTaskAt(text, 1),
        '- [ ] 甲\n- 普通项\n> - [ ] 乙\n- [ ] 丙',
      );
      expect(
        MarkdownEditing.toggleTaskAt(text, 2),
        '- [ ] 甲\n- 普通项\n> - [x] 乙\n- [x] 丙',
      );
      expect(MarkdownEditing.toggleTaskAt(text, 9), text);
    });
  });

  group('insertDroppedPaths', () {
    test('图片扩展名生成图片语法,其余生成链接', () {
      final r = MarkdownEditing.insertDroppedPaths(
        value('正文', 2),
        ['/tmp/截图 1.PNG', '/tmp/报表.xlsx'],
      );
      expect(r.text, '正文\n\n![截图 1.PNG](/tmp/截图 1.PNG)\n[报表.xlsx](/tmp/报表.xlsx)');
    });

    test('空列表不动', () {
      final v = value('x', 1);
      expect(MarkdownEditing.insertDroppedPaths(v, []).text, 'x');
    });
  });

  group('clearInline', () {
    test('剥掉嵌套行内标记与链接语法', () {
      final r = MarkdownEditing.clearInline(
        value('**粗 *斜*** 与 [文](https://a.io) `码`', 0, 100),
      );
      expect(r.text, '粗 斜 与 文 码');
    });

    test('无选区不动', () {
      final v = value('**x**', 2);
      expect(MarkdownEditing.clearInline(v).text, '**x**');
    });
  });
}
