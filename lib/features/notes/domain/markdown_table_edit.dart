/// 表格块源码的单元格级读写 — 供块式编辑器就地编辑单元格。
/// 行号约定:-1 = 表头,0.. = 数据行(分隔行不可编辑,原样保留)。
library;

import 'package:termora/features/notes/domain/markdown_parser.dart';

class MarkdownTableEdit {
  MarkdownTableEdit._();

  static List<String> _lines(String source) => source.split('\n');

  static List<String> splitRow(String line) {
    var s = line.trim();
    if (s.startsWith('|')) s = s.substring(1);
    if (s.endsWith('|')) s = s.substring(0, s.length - 1);
    return [for (final c in s.split('|')) c.trim()];
  }

  static String _joinRow(List<String> cells) => '| ${cells.join(' | ')} |';

  /// 至少要有表头 + 分隔行才算表格
  static bool isTable(String source) => _lines(source).length >= 2;

  static int columnCount(String source) => splitRow(_lines(source)[0]).length;

  static int dataRowCount(String source) =>
      (_lines(source).length - 2).clamp(0, 1 << 30);

  /// 各列对齐(来自分隔行声明)
  static List<MdTableAlign> alignments(String source) {
    final lines = _lines(source);
    if (lines.length < 2) return const [];
    return [
      for (final cell in splitRow(lines[1]))
        switch ((cell.startsWith(':'), cell.endsWith(':'))) {
          (true, true) => MdTableAlign.center,
          (false, true) => MdTableAlign.right,
          _ => MdTableAlign.left,
        },
    ];
  }

  /// 读单元格;越界返回空串
  static String cellAt(String source, int row, int col) {
    final lines = _lines(source);
    final lineIndex = row < 0 ? 0 : row + 2;
    if (lineIndex >= lines.length) return '';
    final cells = splitRow(lines[lineIndex]);
    return col < cells.length ? cells[col] : '';
  }

  /// 写单元格(短行自动补齐到列数)。
  /// 竖线会破坏表格语法 → 全角;换行会把一格劈成两行 → 空格。
  static String setCell(String source, int row, int col, String value) {
    final lines = _lines(source);
    final lineIndex = row < 0 ? 0 : row + 2;
    if (lineIndex >= lines.length || col < 0) return source;
    final columns = columnCount(source);
    final cells = splitRow(lines[lineIndex]);
    while (cells.length < columns || cells.length <= col) {
      cells.add('');
    }
    cells[col] = value
        .trim()
        .replaceAll('|', '｜')
        .replaceAll(RegExp(r'\s*[\r\n]+\s*'), ' ');
    lines[lineIndex] = _joinRow(cells);
    return lines.join('\n');
  }

  /// 末尾加一空行
  static String addRow(String source) {
    final columns = columnCount(source);
    return '$source\n${_joinRow(List.filled(columns, ''))}';
  }

  /// 右侧加一列(分隔行按左对齐补 ---)
  static String addColumn(String source) {
    final lines = _lines(source);
    for (var i = 0; i < lines.length; i++) {
      final cells = splitRow(lines[i]);
      cells.add(i == 1 ? '---' : '');
      lines[i] = _joinRow(cells);
    }
    return lines.join('\n');
  }
}
