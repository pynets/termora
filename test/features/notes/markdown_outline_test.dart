import 'package:flutter_test/flutter_test.dart';
import 'package:termora/features/notes/domain/markdown_outline.dart';

void main() {
  test('提取各级标题:级别/纯文本标题/行首偏移', () {
    const text = '# 一 **粗**\n正文\n## 二 `码`\n### 三';
    final entries = MarkdownOutline.extract(text);
    expect(entries, hasLength(3));
    expect((entries[0].level, entries[0].title, entries[0].offset), (1, '一 粗', 0));
    expect((entries[1].level, entries[1].title), (2, '二 码'));
    expect(entries[1].offset, text.indexOf('## 二'));
    expect(entries[2].level, 3);
  });

  test('代码围栏与公式围栏里的 # 不算标题', () {
    final entries = MarkdownOutline.extract(
      '```\n# 注释\n```\n\$\$\n# x\n\$\$\n# 真标题',
    );
    expect(entries.single.title, '真标题');
  });

  test('空标题跳过;7 个 # 不算', () {
    expect(MarkdownOutline.extract('#  \n####### 七'), isEmpty);
  });

  test('activeEntry:光标落在最近的上方标题;首标题之前为 null', () {
    const text = '前言\n# 甲\n内容\n# 乙\n尾';
    final entries = MarkdownOutline.extract(text);
    expect(MarkdownOutline.activeEntry(entries, 0), isNull);
    expect(
      MarkdownOutline.activeEntry(entries, text.indexOf('内容'))!.title,
      '甲',
    );
    expect(
      MarkdownOutline.activeEntry(entries, text.length)!.title,
      '乙',
    );
  });
}
