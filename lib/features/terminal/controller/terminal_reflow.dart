import 'package:termora/features/terminal/controller/terminal_model.dart';

/// 回流(reflow)结果:重排后的物理行 + 映射后的光标位置。
class ReflowResult {
  const ReflowResult(this.lines, this.cursorRow, this.cursorCol);

  final List<TerminalLine> lines;
  final int cursorRow;
  final int cursorCol;
}

/// 单个单元格(一个可见字形 + 其样式);宽字符 width=2,组合符并入上一格。
class _Cell {
  _Cell(this.text, this.style, this.linkUrl, this.width);
  String text;
  final AnsiStyle style;
  final String? linkUrl;
  final int width;
}

/// 按新列宽 [newColumns] 重新折行(对标 xterm.js 的 reflow):
///
/// 把被软折行(`isWrapped`)连成一体的「逻辑行」重新按新宽度切分 —— 变宽时
/// 断开的长行合并回去,变窄时重新拆分。每个逻辑行保留每格的样式与超链接,
/// 宽字符不被拦腰截断。同时把光标 (cursorRow,cursorCol) 映射到新缓冲区。
///
/// 纯函数、不改入参;[lines] 为空或列宽非法时原样返回。
ReflowResult reflowTerminalLines(
  List<TerminalLine> lines,
  int newColumns, {
  int cursorRow = 0,
  int cursorCol = 0,
}) {
  if (newColumns < 1 || lines.isEmpty) {
    return ReflowResult(lines, cursorRow, cursorCol);
  }

  final result = <TerminalLine>[];
  var newCursorRow = cursorRow;
  var newCursorCol = cursorCol;

  var i = 0;
  while (i < lines.length) {
    final start = i;
    final type = lines[start].type;

    // 图片行原样保留(不参与文本回流,避免图片被丢弃或错位)
    if (lines[start].image != null) {
      if (cursorRow == start) {
        newCursorRow = result.length;
        newCursorCol = cursorCol;
      }
      result.add(lines[start]);
      i = start + 1;
      continue;
    }

    // 1) 收集逻辑行的所有单元格,并记录每条物理行在逻辑行内的起始列偏移
    final cells = <_Cell>[];
    final physStartWidth = <int>[];
    var cum = 0;
    var j = start;
    while (true) {
      physStartWidth.add(cum);
      for (final span in lines[j].spans) {
        for (final rune in span.text.runes) {
          final ch = String.fromCharCode(rune);
          final w = terminalRuneCellWidth(rune);
          if (w == 0) {
            if (cells.isNotEmpty) cells.last.text += ch;
            continue;
          }
          cells.add(_Cell(ch, span.style, span.linkUrl, w));
          cum += w;
        }
      }
      // 下一条物理行若是软折行续接,则并入同一逻辑行
      if (j + 1 < lines.length && lines[j + 1].isWrapped) {
        j++;
      } else {
        break;
      }
    }
    final groupEnd = j;

    // 光标若落在本逻辑行,算出它在逻辑行内的绝对列偏移
    int? cursorLogical;
    if (cursorRow >= start && cursorRow <= groupEnd) {
      cursorLogical = physStartWidth[cursorRow - start] + cursorCol;
    }

    // 2) 把单元格按 newColumns 重新切成若干物理行
    final rows = <List<_Cell>>[];
    var row = <_Cell>[];
    var rowWidth = 0;
    for (final cell in cells) {
      if (rowWidth + cell.width > newColumns && row.isNotEmpty) {
        rows.add(row);
        row = <_Cell>[];
        rowWidth = 0;
      }
      row.add(cell);
      rowWidth += cell.width;
    }
    rows.add(row); // 逻辑行无内容时也留一条空行,保持行数语义

    final firstNewIndex = result.length;
    for (var r = 0; r < rows.length; r++) {
      final tl = TerminalLine(_cellsToSpans(rows[r]), type);
      // 首行沿用原逻辑行的 isWrapped(缓冲区顶部可能本就是续接);其余为续接
      tl.isWrapped = r == 0 ? lines[start].isWrapped : true;
      // Shell 集成标记(OSC 133)只落在逻辑行首行
      if (r == 0) {
        tl.isPromptStart = lines[start].isPromptStart;
        tl.isCommandStart = lines[start].isCommandStart;
        tl.commandExitCode = lines[start].commandExitCode;
      }
      result.add(tl);
    }

    // 3) 映射光标:按行宽逐行消耗逻辑偏移
    if (cursorLogical != null) {
      var remaining = cursorLogical;
      var rr = rows.length - 1;
      var col = remaining;
      for (var r = 0; r < rows.length; r++) {
        final w = rows[r].fold<int>(0, (s, c) => s + c.width);
        if (remaining < w || r == rows.length - 1) {
          rr = r;
          col = remaining;
          break;
        }
        remaining -= w;
      }
      newCursorRow = firstNewIndex + rr;
      newCursorCol = col.clamp(0, newColumns);
    }

    i = groupEnd + 1;
  }

  return ReflowResult(result, newCursorRow, newCursorCol);
}

/// 合并相邻同样式同链接的单元格,组回 span 列表。
List<TerminalSpan> _cellsToSpans(List<_Cell> cells) {
  if (cells.isEmpty) return const [];
  final spans = <TerminalSpan>[];
  var buffer = StringBuffer();
  AnsiStyle? style;
  String? link;

  void flush() {
    if (buffer.isNotEmpty) {
      spans.add(TerminalSpan(buffer.toString(), style!, linkUrl: link));
      buffer = StringBuffer();
    }
  }

  for (final cell in cells) {
    if (style == null || cell.style != style || cell.linkUrl != link) {
      flush();
      style = cell.style;
      link = cell.linkUrl;
    }
    buffer.write(cell.text);
  }
  flush();
  return spans;
}
