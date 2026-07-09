import 'package:flutter_test/flutter_test.dart';
import 'package:termora/features/notes/data/note_pdf_exporter.dart';
import 'package:termora/features/notes/domain/markdown_html_export.dart';

void main() {
  group('HTML 导出', () {
    test('块级结构:标题/段落/代码块/引用/列表/表格/分隔线', () {
      final body = MarkdownHtmlExport.renderBody(
        '# 标题\n\n正文 **粗** `码` [链](https://a.io)\n\n'
        '```dart\nfinal a = 1;\n```\n\n'
        '> 引用\n\n'
        '- [x] 完成\n- 普通\n\n'
        '| A | B |\n|---|--:|\n| 1 | 2 |\n\n---',
      );
      expect(body, contains('<h1>标题</h1>'));
      expect(body, contains('<strong>粗</strong>'));
      expect(body, contains('<code>码</code>'));
      expect(body, contains('<a href="https://a.io">链</a>'));
      expect(
        body,
        contains('<pre><code class="language-dart">final a = 1;'),
      );
      expect(body, contains('<blockquote>'));
      expect(body, contains('<input type="checkbox" disabled checked>'));
      expect(body, contains('<th>A</th>'));
      expect(body, contains('<td style="text-align:right">2</td>'));
      expect(body, contains('<hr>'));
    });

    test('HTML 特殊字符转义(正文与代码)', () {
      final body = MarkdownHtmlExport.renderBody(
        'a < b & c\n\n```\n<script>alert(1)</script>\n```',
      );
      expect(body, contains('a &lt; b &amp; c'));
      expect(body, contains('&lt;script&gt;'));
      expect(body, isNot(contains('<script>')));
    });

    test('嵌套列表按缩进生成多层 ul', () {
      final body = MarkdownHtmlExport.renderBody('- 甲\n  - 子\n- 乙');
      // 出现两层 <ul>
      expect('<ul>'.allMatches(body).length, 2);
      expect(body, contains('<li>子</li>'));
    });

    test('含公式才引入 KaTeX;文档头尾完整', () {
      final withMath = MarkdownHtmlExport.exportDocument('t', '\$\$E=mc^2\$\$');
      expect(withMath, contains('katex'));
      expect(withMath, contains('<div class="math">\$\$E=mc^2\$\$</div>'));

      final plain = MarkdownHtmlExport.exportDocument('标题<>', '正文');
      expect(plain, isNot(contains('katex')));
      expect(plain, contains('<title>标题&lt;&gt;</title>'));
      expect(plain, startsWith('<!DOCTYPE html>'));
      expect(plain.trim(), endsWith('</html>'));
    });
  });

  group('PDF 导出', () {
    test('生成合法 PDF 字节流(含中文/表格/代码块)', () async {
      final bytes = await NotePdfExporter.export(
        '# 中文标题\n\n正文 **加粗** 与 `代码`\n\n'
        '```\nadb devices\n```\n\n'
        '| 名 | 值 |\n|---|---|\n| 甲 | 1 |\n\n'
        '- [x] 任务\n\n> 引用',
      );
      expect(bytes, isNotEmpty);
      // PDF 魔数
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      expect(bytes.length, greaterThan(1000));
    });
  });
}
