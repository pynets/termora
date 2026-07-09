import 'package:flutter_test/flutter_test.dart';
import 'package:termora/features/notes/domain/markdown_source_highlighter.dart';

void main() {
  List<MdSourceToken> tokenize(String s) =>
      MarkdownSourceHighlighter.tokenize(s);

  /// token 区间必须按起点升序且互不重叠(buildTextSpan 的前提)
  void expectWellFormed(String source) {
    final tokens = tokenize(source);
    var last = 0;
    for (final t in tokens) {
      expect(t.start, greaterThanOrEqualTo(last),
          reason: '$t 与前一区间重叠 (source: $source)');
      expect(t.end, greaterThan(t.start));
      expect(t.end, lessThanOrEqualTo(source.length));
      last = t.end;
    }
  }

  test('标题:# 前缀淡化,正文按级别着色', () {
    final tokens = tokenize('## 标题文字');
    expect(tokens, hasLength(2));
    expect(tokens[0].kind, MdSourceKind.syntax);
    expect((tokens[0].start, tokens[0].end), (0, 3)); // "## "
    expect(tokens[1].kind, MdSourceKind.heading);
    expect(tokens[1].level, 2);
    expect((tokens[1].start, tokens[1].end), (3, 7));
  });

  test('粗体:两侧 ** 淡化,内容加粗,偏移精确', () {
    const src = '前**粗体**后';
    final tokens = tokenize(src);
    expect(tokens.map((t) => t.kind), [
      MdSourceKind.syntax,
      MdSourceKind.bold,
      MdSourceKind.syntax,
    ]);
    expect(src.substring(tokens[1].start, tokens[1].end), '粗体');
  });

  test('代码围栏:围栏行淡化,内容整行等宽,内部 ** 不解析', () {
    final tokens = tokenize('```dart\nfinal a = "**x**";\n```');
    expect(tokens.map((t) => t.kind), [
      MdSourceKind.syntax,
      MdSourceKind.codeBlock,
      MdSourceKind.syntax,
    ]);
  });

  test('公式围栏与单行公式', () {
    final tokens = tokenize('\$\$\na+b\n\$\$\n\$\$E=mc^2\$\$');
    expect(tokens.map((t) => t.kind), [
      MdSourceKind.syntax,
      MdSourceKind.math,
      MdSourceKind.syntax,
      MdSourceKind.math,
    ]);
  });

  test('列表记号与任务框着色,内容里的行内标记继续解析', () {
    const src = '- [x] 做完 `代码` 了';
    final tokens = tokenize(src);
    expect(tokens.first.kind, MdSourceKind.listMarker);
    expect(src.substring(tokens.first.start, tokens.first.end), '- [x] ');
    expect(tokens.where((t) => t.kind == MdSourceKind.codeSpan), hasLength(1));
  });

  test('链接:文字着色,url 与括号淡化', () {
    const src = '[官网](https://a.io)';
    final tokens = tokenize(src);
    final link = tokens.singleWhere((t) => t.kind == MdSourceKind.link);
    expect(src.substring(link.start, link.end), '官网');
    final url = tokens.singleWhere((t) => t.kind == MdSourceKind.url);
    expect(src.substring(url.start, url.end), 'https://a.io');
  });

  test('引用前缀与表格竖线淡化', () {
    expect(tokenize('> 引用').first.kind, MdSourceKind.quote);
    final pipes = tokenize('| a | b |')
        .where((t) => t.kind == MdSourceKind.syntax)
        .length;
    expect(pipes, 3);
  });

  test('代码段里的竖线不重复着色', () {
    const src = '`a | b` | c';
    expectWellFormed(src);
    final tokens = tokenize(src);
    // 代码段外只有一个竖线 token
    final pipes = tokens.where(
      (t) => t.kind == MdSourceKind.syntax && src.substring(t.start, t.end) == '|',
    );
    expect(pipes, hasLength(1));
  });

  test('混合文档 token 有序且不重叠', () {
    expectWellFormed(
      '# 标题 \n\n'
      '正文 **粗** *斜* ~~删~~ `码` [链](https://a.io) https://b.io\n'
      '- [ ] 任务 ***粗斜***\n'
      '1. 有序 \\* 转义\n'
      '> 引用 **粗**\n\n'
      '| 表 | 头 |\n|---|---|\n| `x|y` | 乙 |\n\n'
      '```js\nconst x = 1;\n```\n'
      '\$\$\nE=mc^2\n\$\$\n---',
    );
  });

  test('围栏未闭合时后续内容都算代码', () {
    final tokens = tokenize('```\ncode\n# 不是标题');
    expect(tokens[1].kind, MdSourceKind.codeBlock);
    expect(tokens[2].kind, MdSourceKind.codeBlock);
  });

  group('动态显隐标记(concealable)', () {
    test('行内记号与标题前缀可隐藏,内容不可', () {
      final tokens = tokenize('# 标题\n**粗**');
      final prefix = tokens[0];
      expect((prefix.kind, prefix.concealable), (MdSourceKind.syntax, true));
      expect(tokens[1].concealable, isFalse); // 标题正文
      final markers =
          tokens.where((t) => t.kind == MdSourceKind.syntax).skip(1);
      expect(markers.every((t) => t.concealable), isTrue); // 两个 **
      expect(
        tokens.singleWhere((t) => t.kind == MdSourceKind.bold).concealable,
        isFalse,
      );
    });

    test('链接括号和地址可隐藏,文字常显;裸链接常显', () {
      final tokens = tokenize('[官网](https://a.io) https://b.io');
      expect(
        tokens.singleWhere((t) => t.kind == MdSourceKind.link).concealable,
        isFalse,
      );
      final urls = tokens.where((t) => t.kind == MdSourceKind.url).toList();
      expect(urls[0].concealable, isTrue); // 链接地址
      expect(urls[1].concealable, isFalse); // 裸链接
    });

    test('代码/公式围栏行可隐藏;竖线/列表符/引用/分隔线常显', () {
      final tokens = tokenize(
        '```\nx\n```\n\$\$\na+b\n\$\$\n| a | b |\n- 项\n> 引\n---',
      );
      // 四条围栏行(``` ``` $$ $$)都可隐藏
      final concealed = tokens.where((t) => t.concealable).toList();
      expect(concealed, hasLength(4));
      expect(
        concealed.every((t) => t.kind == MdSourceKind.syntax),
        isTrue,
      );
      // 代码/公式内容与结构记号常显
      for (final t in tokens.where((t) => !t.concealable)) {
        expect(
          t.kind,
          isIn([
            MdSourceKind.codeBlock,
            MdSourceKind.math,
            MdSourceKind.syntax, // 表格竖线
            MdSourceKind.listMarker,
            MdSourceKind.quote,
            MdSourceKind.divider,
          ]),
        );
      }
    });

    test('空标题(# 后无字)前缀不隐藏,防整行塌陷', () {
      // "# " 后跟内容才隐藏;此处标题正文为空格后无字符
      final tokens = tokenize('# x\n## ');
      expect(tokens.first.concealable, isTrue);
      // "## " 行:heading 正文为空 → 前缀常显
      final lastSyntax =
          tokens.lastWhere((t) => t.kind == MdSourceKind.syntax);
      expect(lastSyntax.concealable, isFalse);
    });
  });

  group('focusBlockRange(聚焦段落)', () {
    test('扩展到空行边界;文档首尾安全', () {
      const text = '第一段甲\n第一段乙\n\n第二段\n\n第三段';
      // 光标在"第一段乙"里 → 覆盖第一段两行
      final (s1, e1) = MarkdownSourceHighlighter.focusBlockRange(text, 6, 6);
      expect(text.substring(s1, e1), '第一段甲\n第一段乙');
      // 光标在"第三段" → 到文末
      final (s3, e3) =
          MarkdownSourceHighlighter.focusBlockRange(text, text.length, text.length);
      expect(text.substring(s3, e3), '第三段');
    });

    test('选区跨段时两侧都扩到各自边界', () {
      const text = '甲\n\n乙\n\n丙';
      final (s, e) = MarkdownSourceHighlighter.focusBlockRange(text, 0, 4);
      expect(text.substring(s, e), '甲\n\n乙');
    });
  });

  group('activeLineRange', () {
    test('光标行的起止;文档边界安全', () {
      const text = '第一行\n第二行\n第三行';
      expect(MarkdownSourceHighlighter.activeLineRange(text, 5, 5), (4, 7));
      expect(MarkdownSourceHighlighter.activeLineRange(text, 0, 0), (0, 3));
      expect(
        MarkdownSourceHighlighter.activeLineRange(text, text.length, text.length),
        (8, 11),
      );
    });

    test('跨行选区覆盖首尾整行', () {
      const text = '一\n二\n三';
      expect(MarkdownSourceHighlighter.activeLineRange(text, 1, 3), (0, 3));
    });
  });
}
