import 'package:flutter_test/flutter_test.dart';
import 'package:termora/features/notes/domain/markdown_parser.dart';
import 'package:termora/features/notes/domain/markdown_table_edit.dart';

void main() {
  const src = '| 名 | 龄 |\n|:--|--:|\n| 甲 | 1 |\n| 乙 | 2 |';

  test('读:列数/数据行数/单元格/对齐', () {
    expect(MarkdownTableEdit.columnCount(src), 2);
    expect(MarkdownTableEdit.dataRowCount(src), 2);
    expect(MarkdownTableEdit.cellAt(src, -1, 0), '名');
    expect(MarkdownTableEdit.cellAt(src, 1, 1), '2');
    expect(MarkdownTableEdit.cellAt(src, 9, 0), ''); // 越界
    expect(MarkdownTableEdit.alignments(src), [
      MdTableAlign.left,
      MdTableAlign.right,
    ]);
  });

  test('写单元格:表头与数据行;竖线转全角防破格', () {
    final next = MarkdownTableEdit.setCell(src, 0, 1, '99');
    expect(next.split('\n')[2], '| 甲 | 99 |');
    final header = MarkdownTableEdit.setCell(src, -1, 0, '名|字');
    expect(header.split('\n')[0], '| 名｜字 | 龄 |');
    // 分隔行原样保留
    expect(header.split('\n')[1], src.split('\n')[1]);
  });

  test('短行写格自动补齐列', () {
    const ragged = '| a | b |\n|---|---|\n| 1 |';
    final next = MarkdownTableEdit.setCell(ragged, 0, 1, 'x');
    expect(next.split('\n')[2], '| 1 | x |');
  });

  test('加行/加列', () {
    final withRow = MarkdownTableEdit.addRow(src);
    expect(withRow.split('\n'), hasLength(5));
    expect(withRow.split('\n').last, '|  |  |');

    final withCol = MarkdownTableEdit.addColumn(src);
    expect(MarkdownTableEdit.columnCount(withCol), 3);
    expect(withCol.split('\n')[1], '| :-- | --: | --- |');
  });
}
