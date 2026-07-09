import 'dart:math' as math;

import 'package:flutter/painting.dart';

import 'package:termora/features/terminal/controller/terminal_image.dart';

/// The terminal buffer data model — lines, spans, ANSI style, and the
/// unicode cell-width helpers. Pure logic (no widgets), unit-testable.
class TerminalLine {
  final List<TerminalSpan> spans;
  final TerminalLineType type;
  bool isWrapped = false;

  /// 该行承载的内联图片(Sixel / iTerm2);非空时渲染为图片而非文本。
  TerminalImage? image;

  /// Shell 集成(OSC 133):该行是否为一次命令的提示符起点。
  bool isPromptStart = false;

  /// Shell 集成(OSC 133;C):该行是否为命令输出的起点(输入之后)。
  bool isCommandStart = false;

  /// 该命令块的退出码(OSC 133;D);null=未知/未结束。
  int? commandExitCode;

  TerminalLine(List<TerminalSpan> spans, this.type)
    : spans = List<TerminalSpan>.of(spans);

  factory TerminalLine.plain(String text, TerminalLineType type) {
    return TerminalLine([TerminalSpan(text, const AnsiStyle())], type);
  }

  String get text => spans.map((span) => span.text).join();

  int get length => spans.fold(0, (sum, span) => sum + span.cellWidth);

  void clear() {
    spans.clear();
    isWrapped = false;
    image = null;
    isPromptStart = false;
    isCommandStart = false;
    commandExitCode = null;
  }

  void fillBlank(int columns, AnsiStyle style) {
    spans.clear();
    isWrapped = false;
    image = null;
    isPromptStart = false;
    isCommandStart = false;
    commandExitCode = null;
    if (columns <= 0) return;
    final fillStyle = _eraseStyle(style);
    if (fillStyle.background == null) return;
    _appendSpan(TerminalSpan(' ' * columns, fillStyle));
  }

  void _appendSpan(TerminalSpan newSpan) {
    if (newSpan.text.isEmpty) return;
    if (spans.isNotEmpty &&
        spans.last.style == newSpan.style &&
        spans.last.linkUrl == newSpan.linkUrl) {
      final last = spans.removeLast();
      spans.add(
        TerminalSpan(
          last.text + newSpan.text,
          newSpan.style,
          linkUrl: newSpan.linkUrl,
        ),
      );
    } else {
      spans.add(newSpan);
    }
  }

  void writeAt(int column, String text, AnsiStyle style, {String? linkUrl}) {
    if (text.isEmpty) return;
    final currentLength = length;
    if (column >= currentLength) {
      if (column > currentLength) {
        // 光标寻址跳过的格子在 xterm 里保持"从未写过"= 默认背景;
        // 带上当前 SGR 背景会在制表/列寻址时拖出色带
        _appendSpan(
          TerminalSpan(' ' * (column - currentLength), const AnsiStyle()),
        );
      }
      _appendSpan(TerminalSpan(text, style, linkUrl: linkUrl));
      return;
    }

    final startCol = math.max(0, column);
    final endCol = startCol + terminalCellWidth(text);
    final oldSpans = List<TerminalSpan>.of(spans);
    spans.clear();

    var currentPos = 0;
    var inserted = false;

    for (final span in oldSpans) {
      final spanStart = currentPos;
      final spanEnd = currentPos + span.cellWidth;
      currentPos = spanEnd;

      if (spanStart < startCol) {
        final prefixEnd = math.min(spanEnd, startCol);
        final prefixText = terminalSubstringByCellRange(
          span.text,
          0,
          prefixEnd - spanStart,
        );
        _appendSpan(
          TerminalSpan(prefixText, span.style, linkUrl: span.linkUrl),
        );
      }

      if (!inserted && spanEnd >= startCol) {
        _appendSpan(TerminalSpan(text, style, linkUrl: linkUrl));
        inserted = true;
      }

      if (spanEnd > endCol) {
        final suffixStart = math.max(spanStart, endCol);
        final suffixText = terminalSubstringFromCell(
          span.text,
          suffixStart - spanStart,
        );
        _appendSpan(
          TerminalSpan(suffixText, span.style, linkUrl: span.linkUrl),
        );
      }
    }

    if (!inserted) {
      _appendSpan(TerminalSpan(text, style, linkUrl: linkUrl));
    }
  }

  void eraseFrom(int column, {AnsiStyle? style, int? maxCells}) {
    final eraseStyle = _eraseStyle(style);
    final fillEnd = maxCells ?? length;
    if (eraseStyle.background != null && column < fillEnd) {
      writeAt(
        math.max(0, column),
        ' ' * (fillEnd - math.max(0, column)),
        eraseStyle,
      );
      truncateTo(fillEnd);
      return;
    }
    if (column <= 0) {
      clear();
      return;
    }
    if (column >= length) return;

    final oldSpans = List<TerminalSpan>.of(spans);
    spans.clear();
    var currentPos = 0;
    for (final span in oldSpans) {
      final spanStart = currentPos;
      final spanEnd = currentPos + span.cellWidth;
      currentPos = spanEnd;

      if (spanStart >= column) break;
      if (spanEnd <= column) {
        _appendSpan(span);
      } else {
        final prefixText = terminalSubstringByCellRange(
          span.text,
          0,
          column - spanStart,
        );
        _appendSpan(
          TerminalSpan(prefixText, span.style, linkUrl: span.linkUrl),
        );
        break;
      }
    }
  }

  void eraseTo(int column, {AnsiStyle? style}) {
    final count = math.min(column + 1, math.max(column + 1, length));
    writeAt(0, ' ' * count, _eraseStyle(style));
  }

  void eraseChars(int column, int count, {AnsiStyle? style}) {
    if (column >= length || count <= 0) return;
    final actualCount = math.min(count, length - column);
    writeAt(column, ' ' * actualCount, _eraseStyle(style));
  }

  void insertChars(int column, int count, AnsiStyle style) {
    if (count <= 0) return;
    final curLength = length;
    if (column >= curLength) {
      writeAt(column, ' ' * count, style);
      return;
    }
    final rightText = terminalSubstringFromCell(text, column);
    writeAt(column, (' ' * count) + rightText, style);
  }

  void deleteChars(int column, int count, AnsiStyle style) {
    if (column >= length || count <= 0) return;
    final curText = text;
    final delEnd = math.min(column + count, length);
    final rightText = terminalSubstringFromCell(curText, delEnd);
    final padCount = delEnd - column;
    writeAt(column, rightText + (' ' * padCount), style);
  }

  void truncateTo(int maxCells) {
    if (maxCells <= 0) {
      clear();
      return;
    }
    if (length <= maxCells) return;

    final oldSpans = List<TerminalSpan>.of(spans);
    spans.clear();
    var currentPos = 0;
    for (final span in oldSpans) {
      if (currentPos >= maxCells) break;
      final spanEnd = currentPos + span.cellWidth;
      if (spanEnd <= maxCells) {
        _appendSpan(span);
        currentPos = spanEnd;
        continue;
      }
      final clippedText = terminalSubstringByCellRange(
        span.text,
        0,
        maxCells - currentPos,
      );
      _appendSpan(TerminalSpan(clippedText, span.style, linkUrl: span.linkUrl));
      break;
    }
  }

  AnsiStyle _eraseStyle(AnsiStyle? style) {
    return AnsiStyle(background: style?.background);
  }
}

class TerminalSpan {
  final String text;
  final AnsiStyle style;
  final String? linkUrl;

  const TerminalSpan(this.text, this.style, {this.linkUrl});

  int get cellWidth => terminalCellWidth(text);

  TerminalSpan copyWith({
    String? text,
    AnsiStyle? style,
    String? linkUrl,
    bool clearLinkUrl = false,
  }) {
    return TerminalSpan(
      text ?? this.text,
      style ?? this.style,
      linkUrl: clearLinkUrl ? null : linkUrl ?? this.linkUrl,
    );
  }
}

class AnsiStyle {
  const AnsiStyle({
    this.foreground,
    this.background,
    this.bold = false,
    this.dim = false,
    this.italic = false,
    this.underline = false,
    this.underlineStyle,
    this.decorationColor,
    this.overline = false,
    this.inverse = false,
    this.invisible = false,
    this.strikethrough = false,
    this.blink = false,
  });

  final Color? foreground;
  final Color? background;
  final bool bold;
  final bool dim;
  final bool italic;
  final bool underline;
  final TextDecorationStyle? underlineStyle;
  final Color? decorationColor;
  final bool overline;
  final bool inverse;
  final bool invisible;
  final bool strikethrough;

  /// SGR 5/6:闪烁(渲染层按闪烁相位调透明度实现)
  final bool blink;

  AnsiStyle copyWith({
    Color? foreground,
    Color? background,
    bool? bold,
    bool? dim,
    bool? italic,
    bool? underline,
    TextDecorationStyle? underlineStyle,
    Color? decorationColor,
    bool? overline,
    bool? inverse,
    bool? invisible,
    bool? strikethrough,
    bool? blink,
    bool clearForeground = false,
    bool clearBackground = false,
    bool clearUnderlineStyle = false,
    bool clearDecorationColor = false,
  }) {
    return AnsiStyle(
      foreground: clearForeground ? null : foreground ?? this.foreground,
      background: clearBackground ? null : background ?? this.background,
      bold: bold ?? this.bold,
      dim: dim ?? this.dim,
      italic: italic ?? this.italic,
      underline: underline ?? this.underline,
      underlineStyle: clearUnderlineStyle
          ? null
          : underlineStyle ?? this.underlineStyle,
      decorationColor: clearDecorationColor
          ? null
          : decorationColor ?? this.decorationColor,
      overline: overline ?? this.overline,
      inverse: inverse ?? this.inverse,
      invisible: invisible ?? this.invisible,
      strikethrough: strikethrough ?? this.strikethrough,
      blink: blink ?? this.blink,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is AnsiStyle &&
        other.foreground == foreground &&
        other.background == background &&
        other.bold == bold &&
        other.dim == dim &&
        other.italic == italic &&
        other.underline == underline &&
        other.underlineStyle == underlineStyle &&
        other.decorationColor == decorationColor &&
        other.overline == overline &&
        other.inverse == inverse &&
        other.invisible == invisible &&
        other.strikethrough == strikethrough &&
        other.blink == blink;
  }

  @override
  int get hashCode => Object.hash(
    foreground,
    background,
    bold,
    dim,
    italic,
    underline,
    underlineStyle,
    decorationColor,
    overline,
    inverse,
    invisible,
    strikethrough,
    blink,
  );
}

enum TerminalLineType { prompt, stdout, stderr, system }

enum TerminalCursorShape { block, underline, bar }

String padTerminalRight(String value, int width) {
  final padding = width - terminalCellWidth(value);
  if (padding <= 0) return value;
  return value + (' ' * padding);
}

String terminalSubstringFromCell(String value, int startCell) {
  return terminalSubstringByCellRange(
    value,
    startCell,
    terminalCellWidth(value),
  );
}

String terminalSubstringByCellRange(String value, int startCell, int endCell) {
  if (value.isEmpty || endCell <= startCell) return '';
  final buffer = StringBuffer();
  var cell = 0;
  for (final rune in value.runes) {
    final char = String.fromCharCode(rune);
    final width = terminalRuneCellWidth(rune);
    final nextCell = cell + width;
    if (nextCell <= startCell) {
      cell = nextCell;
      continue;
    }
    if (cell >= endCell) break;
    if (cell >= startCell && nextCell <= endCell) {
      buffer.write(char);
    }
    cell = nextCell;
  }
  return buffer.toString();
}

int terminalCellWidth(String value) {
  var width = 0;
  for (final rune in value.runes) {
    width += terminalRuneCellWidth(rune);
  }
  return width;
}

int terminalRuneCellWidth(int rune) {
  if (rune == 0) return 0;
  if (rune < 0x20 || (rune >= 0x7F && rune < 0xA0)) return 0;
  if (isCombiningRune(rune)) return 0;
  if (isWideRune(rune)) return 2;
  return 1;
}

bool isCombiningRune(int rune) {
  return (rune >= 0x0300 && rune <= 0x036F) ||
      (rune >= 0x0483 && rune <= 0x0489) ||
      (rune >= 0x0591 && rune <= 0x05BD) ||
      (rune >= 0x0610 && rune <= 0x061A) ||
      (rune >= 0x064B && rune <= 0x065F) ||
      rune == 0x0670 ||
      (rune >= 0x06D6 && rune <= 0x06DC) ||
      (rune >= 0x1160 && rune <= 0x11FF) || // 韩文连接 jamo(中/终声)
      (rune >= 0x1AB0 && rune <= 0x1AFF) ||
      (rune >= 0x1DC0 && rune <= 0x1DFF) ||
      (rune >= 0x20D0 && rune <= 0x20FF) ||
      isZeroWidthFormatRune(rune) ||
      (rune >= 0xFE20 && rune <= 0xFE2F);
}

/// 零宽格式/控制字符:ZWSP、ZWNJ、ZWJ、双向控制、变体选择符(VS1-16)、
/// BOM/ZWNBSP,以及 emoji 变体选择补充块。这些不占单元格 —— 之前 VS16
/// (U+FE0F)被算成 1 格,是 emoji 后错位一格的主因。
bool isZeroWidthFormatRune(int rune) {
  return rune == 0x00AD || // 软连字符
      (rune >= 0x200B && rune <= 0x200F) || // ZWSP/ZWNJ/ZWJ/LRM/RLM
      (rune >= 0x2028 && rune <= 0x202E) || // 行/段分隔 + 双向控制
      (rune >= 0x2060 && rune <= 0x2064) || // WORD JOINER 等
      (rune >= 0xFE00 && rune <= 0xFE0F) || // 变体选择符 VS1-16
      rune == 0xFEFF || // ZWNBSP / BOM
      (rune >= 0xE0100 && rune <= 0xE01EF); // 变体选择符补充
}

bool isWideRune(int rune) {
  return (rune >= 0x1100 && rune <= 0x115F) ||
      rune == 0x2329 ||
      rune == 0x232A ||
      (rune >= 0x2E80 && rune <= 0xA4CF && rune != 0x303F) ||
      (rune >= 0xAC00 && rune <= 0xD7A3) ||
      (rune >= 0xF900 && rune <= 0xFAFF) ||
      (rune >= 0xFE10 && rune <= 0xFE19) ||
      (rune >= 0xFE30 && rune <= 0xFE6F) ||
      (rune >= 0xFF00 && rune <= 0xFF60) ||
      (rune >= 0xFFE0 && rune <= 0xFFE6) ||
      // ── Unicode 15 补充的宽/emoji 区段 ──
      rune == 0x1F004 || // 麻将牌
      rune == 0x1F0CF || // 小丑牌
      rune == 0x1F18E || // 🆎
      (rune >= 0x1F191 && rune <= 0x1F19A) || // 🆑..🆚
      (rune >= 0x1F200 && rune <= 0x1F2FF) || // 封闭表意补充
      (rune >= 0x1F300 && rune <= 0x1FAFF) || // 主 emoji 区
      (rune >= 0x20000 && rune <= 0x3FFFD); // CJK 扩展 B+
}
