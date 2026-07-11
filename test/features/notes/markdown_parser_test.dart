import 'package:flutter_test/flutter_test.dart';
import 'package:termora/features/notes/domain/markdown_parser.dart';
import 'package:termora/features/notes/domain/note.dart';

void main() {
  group('块级解析', () {
    test('标题 1-6 级,7 个 # 不算标题', () {
      final blocks = MarkdownParser.parse('# 一\n###### 六\n####### 七');
      expect(blocks, hasLength(3));
      expect((blocks[0] as MdHeading).level, 1);
      expect(((blocks[0] as MdHeading).spans.single).text, '一');
      expect((blocks[1] as MdHeading).level, 6);
      expect(blocks[2], isA<MdParagraph>());
    });

    test('连续行合并为一个段落,空行分段', () {
      final blocks = MarkdownParser.parse('第一行\n第二行\n\n第二段');
      expect(blocks, hasLength(2));
      expect(
        ((blocks[0] as MdParagraph).spans.single).text,
        '第一行\n第二行',
      );
      expect(((blocks[1] as MdParagraph).spans.single).text, '第二段');
    });

    test('围栏代码块保留原文与语言,内部标记不解析', () {
      final blocks = MarkdownParser.parse(
        '```dart\nfinal a = 1; // **不加粗**\n\n# 不是标题\n```\n后面',
      );
      final code = blocks[0] as MdCodeBlock;
      expect(code.language, 'dart');
      expect(code.code, 'final a = 1; // **不加粗**\n\n# 不是标题');
      expect(blocks[1], isA<MdParagraph>());
    });

    test('未闭合围栏吃到文末', () {
      final blocks = MarkdownParser.parse('```\nabc\ndef');
      expect((blocks.single as MdCodeBlock).code, 'abc\ndef');
    });

    test('无序/有序/任务列表与缩进嵌套', () {
      final blocks = MarkdownParser.parse(
        '- 甲\n  - 子项\n- [x] 已完成\n- [ ] 待办\n\n1. 一\n2. 二',
      );
      final ul = blocks[0] as MdList;
      expect(ul.ordered, isFalse);
      expect(ul.items, hasLength(4));
      expect(ul.items[1].indent, 1);
      expect(ul.items[2].checked, isTrue);
      expect(ul.items[3].checked, isFalse);

      final ol = blocks[1] as MdList;
      expect(ol.ordered, isTrue);
      expect(ol.items.map((i) => i.number), [1, 2]);
    });

    test('列表项悬挂缩进续行并入同一项;空行后接列表项则同表继续', () {
      final blocks = MarkdownParser.parse(
        '- 第一项\n  续行文字\n\n- 第二项\n结束段落',
      );
      final list = blocks[0] as MdList;
      expect(list.items, hasLength(2));
      expect(list.items[0].spans.single.text, '第一项\n续行文字');
      expect(list.items[1].spans.single.text, '第二项');
      expect(blocks[1], isA<MdParagraph>());
    });

    test('引用支持嵌套块', () {
      final blocks = MarkdownParser.parse('> # 标题\n> 正文\n> > 二层');
      final quote = blocks.single as MdQuote;
      expect(quote.children[0], isA<MdHeading>());
      expect(quote.children[1], isA<MdParagraph>());
      expect(quote.children[2], isA<MdQuote>());
    });

    test('水平线三种写法;列表项 "- x" 不误判', () {
      final blocks = MarkdownParser.parse('---\n***\n_ _ _\n- 项');
      expect(blocks[0], isA<MdDivider>());
      expect(blocks[1], isA<MdDivider>());
      expect(blocks[2], isA<MdDivider>());
      expect(blocks[3], isA<MdList>());
    });

    test('管道表格:表头/分隔/数据行,列数以表头为准', () {
      final blocks = MarkdownParser.parse(
        '| 名称 | 年龄 |\n|---|---:|\n| 张三 | 3 |\n| 李四 | 4 |',
      );
      final table = blocks.single as MdTable;
      expect(table.header, hasLength(2));
      expect(table.header[0].single.text, '名称');
      expect(table.rows, hasLength(2));
      expect(table.rows[1][0].single.text, '李四');
    });

    test('表格列对齐::--- 左 :---: 中 ---: 右,缺省左', () {
      final blocks = MarkdownParser.parse(
        '| a | b | c | d |\n|:---|:---:|---:|---|\n| 1 | 2 | 3 | 4 |',
      );
      final table = blocks.single as MdTable;
      expect(table.alignAt(0), MdTableAlign.left);
      expect(table.alignAt(1), MdTableAlign.center);
      expect(table.alignAt(2), MdTableAlign.right);
      expect(table.alignAt(3), MdTableAlign.left);
      expect(table.alignAt(9), MdTableAlign.left); // 越界回落
    });

    test(r'块级公式:单行 $$...$$ 与多行围栏', () {
      final blocks = MarkdownParser.parse(
        '\$\$E=mc^2\$\$\n\n\$\$\n\\int_0^\\infty f x dx\n\$\$\n正文',
      );
      expect((blocks[0] as MdMathBlock).tex, 'E=mc^2');
      expect((blocks[1] as MdMathBlock).tex, r'\int_0^\infty f x dx');
      expect(blocks[2], isA<MdParagraph>());
    });

    test(r'未闭合 $$ 围栏吃到文末;正文里的美元金额不受影响', () {
      final blocks = MarkdownParser.parse('\$\$\na+b');
      expect((blocks.single as MdMathBlock).tex, 'a+b');

      final money = MarkdownParser.parse(r'价格 $100 和 $200');
      expect(money.single, isA<MdParagraph>());
    });

    test('任务项按全文行序编号(含引用内),普通项无编号', () {
      final blocks = MarkdownParser.parse(
        '- [ ] 一\n- 普通\n\n> - [x] 二\n\n- [ ] 三',
      );
      final first = (blocks[0] as MdList).items;
      expect(first[0].taskIndex, 0);
      expect(first[1].taskIndex, isNull);
      final quoted = ((blocks[1] as MdQuote).children.single as MdList).items;
      expect(quoted.single.taskIndex, 1);
      expect((blocks[2] as MdList).items.single.taskIndex, 2);
    });

    test('含 | 的普通行(下一行非分隔行)按段落处理', () {
      final blocks = MarkdownParser.parse('a | b\n普通行');
      expect(blocks.single, isA<MdParagraph>());
    });
  });

  group('行内解析', () {
    List<MdInline> inline(String s) => MarkdownParser.parseInline(s);

    test('粗体/斜体/粗斜体/删除线基础样式', () {
      final spans = inline('**粗** *斜* ***粗斜*** ~~删~~');
      expect(spans, hasLength(7));
      expect((spans[0].bold, spans[0].italic), (true, false));
      expect(spans[0].text, '粗');
      expect((spans[2].bold, spans[2].italic), (false, true));
      expect((spans[4].bold, spans[4].italic), (true, true));
      expect(spans[4].text, '粗斜');
      expect(spans[6].strikethrough, isTrue);
    });

    test('嵌套组合:粗体内斜体、删除线内粗体', () {
      final spans = inline('**外*内*层** ~~没 **有** 了~~');
      // 粗体拆成三段:外(b) 内(b+i) 层(b)
      expect(spans[0].text, '外');
      expect((spans[0].bold, spans[0].italic), (true, false));
      expect(spans[1].text, '内');
      expect((spans[1].bold, spans[1].italic), (true, true));
      expect(spans[2].text, '层');
      // 删除线内的粗体两个标志同时为真
      final boldStrike = spans.firstWhere((s) => s.text == '有');
      expect((boldStrike.bold, boldStrike.strikethrough), (true, true));
    });

    test('行内代码优先,内部星号不解析;双反引号可包单反引号', () {
      final spans = inline('看 `a ** b` 和 ``x ` y``');
      final codes = spans.where((s) => s.code).toList();
      expect(codes, hasLength(2));
      expect(codes[0].text, 'a ** b');
      expect(codes[1].text, 'x ` y');
    });

    test('链接与图片;链接文本内可嵌样式', () {
      final spans = inline('[官网](https://a.io) ![截图](/tmp/x.png)');
      expect(spans[0].url, 'https://a.io');
      expect(spans[0].text, '官网');
      expect(spans[2].imageUrl, '/tmp/x.png');

      final styled = inline('[点 **这里** 看](https://b.io)');
      expect(styled.every((s) => s.url == 'https://b.io'), isTrue);
      expect(styled.firstWhere((s) => s.text == '这里').bold, isTrue);
    });

    test('裸 URL 自动成链,结尾标点不吞', () {
      final spans = inline('见 https://a.io/x?q=1, 然后');
      final link = spans.firstWhere((s) => s.url != null);
      expect(link.url, 'https://a.io/x?q=1');
      expect(spans.last.text, ', 然后');
    });

    test(r'反斜杠转义输出字面字符', () {
      final spans = inline(r'\*不是斜体\* 和 \`不是代码\`');
      expect(spans.single.isPlain, isTrue);
      expect(spans.single.text, '*不是斜体* 和 `不是代码`');
    });

    test('下划线斜体要求词边界,snake_case 不误判', () {
      expect(
        inline('my_var_name').single.isPlain,
        isTrue,
      );
      final spans = inline('这是 _斜体_ 词');
      expect(spans.firstWhere((s) => s.text == '斜体').italic, isTrue);
    });

    test('纯文本原样单 span;"3 * 4 = 12" 不误判斜体', () {
      expect(inline('你好').single.isPlain, isTrue);
      final spans = inline('3 * 4 = 12');
      expect(spans.every((s) => s.isPlain), isTrue);
    });
  });

  group('Note 标题/摘要推导', () {
    Note note(String content) => Note(
      id: 'x',
      content: content,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

    test('取第一个非空行并剥掉 markdown 标记', () {
      expect(note('\n\n## 会议 **纪要**\n正文').title, '会议 纪要');
      expect(note('- [ ] 买菜\n- 做饭').title, '买菜');
    });

    test('围栏与水平线不算标题;空内容回退占位', () {
      expect(note('```\ncode\n```').title, 'code');
      expect(note('---\n正文').title, '正文');
      expect(note('').title, '无标题笔记');
      expect(note('   \n\n').title, '无标题笔记');
    });

    test('摘要取标题后的下一个有效行', () {
      final n = note('# 标题\n\n> 引用的 `内容`\n其他');
      expect(n.title, '标题');
      expect(n.summary, '引用的 内容');
      expect(note('只有标题').summary, '');
    });

    test('naturalCompare:数字按数值、字母不分大小写、前缀短者在前', () {
      expect(Note.naturalCompare('第2章', '第10章'), lessThan(0));
      expect(Note.naturalCompare('v1.9', 'v1.10'), lessThan(0));
      expect(Note.naturalCompare('Abc', 'abd'), lessThan(0)); // 忽略大小写
      expect(Note.naturalCompare('笔记', '笔记2'), lessThan(0)); // 前缀在前
      expect(Note.naturalCompare('a10', 'a10'), 0);
    });

    test('字数统计:中文按字,英文数字按词', () {
      expect(Note.wordCount('你好世界'), 4);
      expect(Note.wordCount('hello world_2 再见'), 4);
      expect(Note.wordCount('# 标题 **加粗**'), 4); // 标记符号不计
      expect(Note.wordCount(''), 0);
    });

    test('JSON 往返(含置顶/笔记本字段;旧数据缺字段有默认值)', () {
      final n = Note(
        id: 'a1',
        content: '# hi',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(2000),
        pinned: true,
        notebookId: 'nb1',
      );
      final back = Note.fromJson(n.toJson());
      expect(back.id, 'a1');
      expect(back.content, '# hi');
      expect(back.createdAt, n.createdAt);
      expect(back.updatedAt, n.updatedAt);
      expect(back.pinned, isTrue);
      expect(back.notebookId, 'nb1');

      // 旧版本存的 JSON 没有新字段
      final legacy = Note.fromJson({'id': 'x', 'content': 'y'});
      expect(legacy.pinned, isFalse);
      expect(legacy.notebookId, isNull);
    });
  });
}
