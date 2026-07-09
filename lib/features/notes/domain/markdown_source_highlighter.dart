import 'package:termora/features/notes/domain/markdown_parser.dart';

/// 源码实时着色的语义种类(所见即所得编辑器用)
enum MdSourceKind {
  /// 语法记号(# ** ` 围栏等),编辑器里淡化显示
  syntax,
  heading,
  bold,
  italic,
  boldItalic,
  strike,
  codeSpan,
  codeBlock,
  math,
  link,
  url,
  listMarker,
  quote,
  divider,
}

/// 一段着色区间 [start, end),区间互不重叠且按起点升序
class MdSourceToken {
  const MdSourceToken(
    this.start,
    this.end,
    this.kind, {
    this.level = 0,
    this.concealable = false,
  });

  final int start;
  final int end;
  final MdSourceKind kind;

  /// heading 的级别 1..6,其余种类为 0
  final int level;

  /// 光标不在所在行时是否隐藏(marktext 式动态显隐)。
  /// 只有行内记号(** ` []() # 前缀等)可隐藏;围栏/竖线/列表符等
  /// 结构记号常显,否则行高塌陷、表格错位。
  final bool concealable;

  @override
  String toString() => 'MdSourceToken($start,$end,${kind.name}'
      '${level > 0 ? ',h$level' : ''}${concealable ? ',conceal' : ''})';
}

/// 把 markdown 源码切成着色 token — 供 MarkdownEditingController 的
/// buildTextSpan 实时渲染:标题变大、粗斜删上样式、语法记号淡化。
/// 纯 Dart,行级状态机(代码/公式围栏) + 行内正则(复用解析器的 pattern)。
class MarkdownSourceHighlighter {
  MarkdownSourceHighlighter._();

  static final _fenceRe = RegExp(r'^(```|~~~)');
  static final _headingRe = RegExp(r'^(\s*#{1,6}\s+)(.*)$');
  static final _dividerRe = RegExp(r'^([-*_])\s*(\1\s*){2,}$');
  static final _quotePrefixRe = RegExp(r'^(\s*(?:>\s*)+)');
  static final _listPrefixRe = RegExp(
    r'^(\s*)([-*+]\s+(?:\[[ xX]\]\s+)?|\d{1,9}[.)]\s+)',
  );

  static List<MdSourceToken> tokenize(String text) {
    final tokens = <MdSourceToken>[];
    void add(
      int start,
      int end,
      MdSourceKind kind, {
      int level = 0,
      bool conceal = false,
    }) {
      if (start < end) {
        tokens.add(
          MdSourceToken(start, end, kind, level: level, concealable: conceal),
        );
      }
    }

    var offset = 0;
    String? fence;
    var inMath = false;

    for (final line in text.split('\n')) {
      final lineEnd = offset + line.length;
      final trimmed = line.trim();

      if (fence != null) {
        if (trimmed == fence) {
          // 闭合围栏行整行隐藏(光标所在行才显形),行高塌成细缝即"消失"
          add(offset, lineEnd, MdSourceKind.syntax, conceal: true);
          fence = null;
        } else if (offset == lineEnd) {
          // 围栏内空行:零宽占位 token,维持底色分组的行相邻链
          tokens.add(MdSourceToken(offset, offset, MdSourceKind.codeBlock));
        } else {
          add(offset, lineEnd, MdSourceKind.codeBlock);
        }
      } else if (inMath) {
        if (trimmed == r'$$') {
          add(offset, lineEnd, MdSourceKind.syntax, conceal: true);
          inMath = false;
        } else if (offset == lineEnd) {
          tokens.add(MdSourceToken(offset, offset, MdSourceKind.math));
        } else {
          add(offset, lineEnd, MdSourceKind.math);
        }
      } else if (trimmed.isEmpty) {
        // 空行无 token
      } else if (_fenceRe.hasMatch(trimmed)) {
        add(offset, lineEnd, MdSourceKind.syntax, conceal: true);
        fence = _fenceRe.firstMatch(trimmed)![1];
      } else if (trimmed.startsWith(r'$$')) {
        if (trimmed.length > 4 && trimmed.endsWith(r'$$')) {
          add(offset, lineEnd, MdSourceKind.math); // 单行公式
        } else {
          add(offset, lineEnd, MdSourceKind.syntax, conceal: true);
          inMath = true;
        }
      } else if (_headingRe.hasMatch(line)) {
        final m = _headingRe.firstMatch(line)!;
        final level = '#'.allMatches(m[1]!).length;
        // 标题文本非空才允许隐藏 # 前缀,避免整行塌陷
        add(
          offset,
          offset + m[1]!.length,
          MdSourceKind.syntax,
          conceal: m[2]!.isNotEmpty,
        );
        add(offset + m[1]!.length, lineEnd, MdSourceKind.heading, level: level);
      } else if (_dividerRe.hasMatch(trimmed)) {
        add(offset, lineEnd, MdSourceKind.divider);
      } else {
        // 引用前缀 → 列表前缀 → 行内标记 → 表格竖线
        var rest = line;
        var base = offset;
        final quote = _quotePrefixRe.firstMatch(rest);
        if (quote != null) {
          add(base, base + quote[1]!.length, MdSourceKind.quote);
          base += quote[1]!.length;
          rest = rest.substring(quote[1]!.length);
        }
        final list = _listPrefixRe.firstMatch(rest);
        if (list != null) {
          final prefixLen = list[1]!.length + list[2]!.length;
          add(base + list[1]!.length, base + prefixLen, MdSourceKind.listMarker);
          base += prefixLen;
          rest = rest.substring(prefixLen);
        }
        final before = tokens.length;
        _inlineTokens(rest, base, add);
        _pipeTokens(rest, base, tokens, before, add);
      }
      offset = lineEnd + 1;
    }
    // 竖线 token 追加在行内 token 之后,统一排序保证起点升序
    tokens.sort((a, b) => a.start - b.start);
    return tokens;
  }

  /// 选区覆盖的整行范围 [start, end)(选区跨多行则全算)。
  /// 编辑器用它决定哪些行的 concealable 记号显形。
  static (int, int) activeLineRange(
    String text,
    int selectionStart,
    int selectionEnd,
  ) {
    final length = text.length;
    final s = selectionStart.clamp(0, length);
    final e = selectionEnd.clamp(0, length);
    final lineStart = s == 0 ? 0 : text.lastIndexOf('\n', s - 1) + 1;
    var lineEnd = text.indexOf('\n', e);
    if (lineEnd < 0) lineEnd = length;
    return (lineStart, lineEnd);
  }

  /// 聚焦模式:光标所在段落块的范围 [start, end),块以空行为界。
  /// 选区跨多块时向两侧扩到各自的空行边界。
  static (int, int) focusBlockRange(
    String text,
    int selectionStart,
    int selectionEnd,
  ) {
    var (start, end) = activeLineRange(text, selectionStart, selectionEnd);
    // 向上扩:前一行非空则并入
    while (start > 0) {
      final prevEnd = start - 1; // 前一行的换行符
      final prevStart =
          prevEnd == 0 ? 0 : text.lastIndexOf('\n', prevEnd - 1) + 1;
      if (text.substring(prevStart, prevEnd).trim().isEmpty) break;
      start = prevStart;
    }
    // 向下扩:后一行非空则并入
    while (end < text.length) {
      final nextStart = end + 1;
      var nextEnd = text.indexOf('\n', nextStart);
      if (nextEnd < 0) nextEnd = text.length;
      if (text.substring(nextStart, nextEnd).trim().isEmpty) break;
      end = nextEnd;
    }
    return (start, end);
  }

  /// 行内标记 token 化,组号语义与 MarkdownParser.inlinePattern 一致。
  /// 记号一律 conceal:光标不在行上时隐藏,只留最终样式的内容。
  static void _inlineTokens(
    String segment,
    int base,
    void Function(int, int, MdSourceKind, {int level, bool conceal}) add,
  ) {
    for (final m in MarkdownParser.inlinePattern.allMatches(segment)) {
      final s = base + m.start;
      final e = base + m.end;
      if (m[1] != null) {
        // 反斜杠隐藏;被转义字符保持正文
        add(s, s + 1, MdSourceKind.syntax, conceal: true);
      } else if (m[3] != null) {
        final n = m[2]!.length;
        add(s, s + n, MdSourceKind.syntax, conceal: true);
        add(s + n, e - n, MdSourceKind.codeSpan);
        add(e - n, e, MdSourceKind.syntax, conceal: true);
      } else if (m[5] != null) {
        _linkTokens(s, e, m[4]!, m[5]!, prefixLength: 2, add: add); // 图片 ![
      } else if (m[7] != null) {
        _linkTokens(s, e, m[6]!, m[7]!, prefixLength: 1, add: add); // 链接 [
      } else if (m[8] != null) {
        add(s, s + 3, MdSourceKind.syntax, conceal: true);
        add(s + 3, e - 3, MdSourceKind.boldItalic);
        add(e - 3, e, MdSourceKind.syntax, conceal: true);
      } else if (m[9] != null) {
        add(s, s + 2, MdSourceKind.syntax, conceal: true);
        add(s + 2, e - 2, MdSourceKind.bold);
        add(e - 2, e, MdSourceKind.syntax, conceal: true);
      } else if (m[10] != null || m[11] != null) {
        add(s, s + 1, MdSourceKind.syntax, conceal: true);
        add(s + 1, e - 1, MdSourceKind.italic);
        add(e - 1, e, MdSourceKind.syntax, conceal: true);
      } else if (m[12] != null) {
        add(s, s + 2, MdSourceKind.syntax, conceal: true);
        add(s + 2, e - 2, MdSourceKind.strike);
        add(e - 2, e, MdSourceKind.syntax, conceal: true);
      } else if (m[13] != null) {
        add(s, e, MdSourceKind.url); // 裸链接本身就是内容,常显
      }
    }
  }

  /// [文字](地址) / ![alt](地址):文字按链接色常显,
  /// 括号与地址隐藏(光标所在行才显形)。alt/文字为空时不隐藏,防整体消失。
  static void _linkTokens(
    int start,
    int end,
    String label,
    String url, {
    required int prefixLength,
    required void Function(int, int, MdSourceKind, {int level, bool conceal})
        add,
  }) {
    final conceal = label.isNotEmpty;
    final labelStart = start + prefixLength;
    final labelEnd = labelStart + label.length;
    final urlStart = labelEnd + 2; // "]("
    add(start, labelStart, MdSourceKind.syntax, conceal: conceal);
    add(labelStart, labelEnd, MdSourceKind.link);
    add(labelEnd, urlStart, MdSourceKind.syntax, conceal: conceal);
    add(urlStart, urlStart + url.length, MdSourceKind.url, conceal: conceal);
    add(urlStart + url.length, end, MdSourceKind.syntax, conceal: conceal);
  }

  /// 表格竖线淡化(避开已被行内 token 覆盖的位置,如代码段里的 |)
  static void _pipeTokens(
    String segment,
    int base,
    List<MdSourceToken> tokens,
    int fromIndex,
    void Function(int, int, MdSourceKind, {int level, bool conceal}) add,
  ) {
    if (!segment.contains('|')) return;
    bool covered(int position) {
      for (var i = fromIndex; i < tokens.length; i++) {
        if (position >= tokens[i].start && position < tokens[i].end) {
          return true;
        }
      }
      return false;
    }

    for (var i = 0; i < segment.length; i++) {
      if (segment[i] == '|' && !covered(base + i)) {
        add(base + i, base + i + 1, MdSourceKind.syntax);
      }
    }
  }
}
