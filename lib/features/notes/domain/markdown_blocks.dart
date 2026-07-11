/// 块式编辑器的文档模型 — 把 markdown 源码切成带源码区间的块,
/// 编辑单块后按区间写回全文。纯 Dart,可单测。
library;

enum SourceBlockKind {
  /// 普通文本块(段落/标题/列表/引用的连续非空行)
  text,

  /// 围栏代码块
  code,

  /// $$ 公式块
  math,

  /// 管道表格
  table,

  /// 水平分隔线
  divider,

  /// 整行只有一张图片
  image,
}

/// 一个块及其在全文中的源码区间 [start, end)(不含尾随空行)
class SourceBlock {
  const SourceBlock({
    required this.start,
    required this.end,
    required this.source,
    required this.kind,
  });

  final int start;
  final int end;
  final String source;
  final SourceBlockKind kind;

  @override
  String toString() => 'SourceBlock(${kind.name}, $start..$end)';
}

class MarkdownBlockSplitter {
  MarkdownBlockSplitter._();

  static final _fenceRe = RegExp(r'^(```|~~~)');
  static final _dividerRe = RegExp(r'^([-*_])\s*(\1\s*){2,}$');
  static final _tableSeparatorRe = RegExp(r'^\s*\|?[\s:|-]+\|[\s:|-]*$');
  static final _imageLineRe = RegExp(r'^!\[[^\]]*\]\([^)]*\)$');

  static List<SourceBlock> split(String source) {
    // 不做换行归一:块区间要按原始字符串切,归一会让偏移错位啃字。
    // CRLF 由文本入口统一转 LF(MarkdownEditing.normalizeNewlines)。
    final lines = source.split('\n');
    // 每行的起始偏移
    final offsets = List<int>.filled(lines.length + 1, 0);
    for (var i = 0; i < lines.length; i++) {
      offsets[i + 1] = offsets[i] + lines[i].length + 1;
    }

    final blocks = <SourceBlock>[];
    void add(int firstLine, int lastLine, SourceBlockKind kind) {
      final start = offsets[firstLine];
      final end = offsets[lastLine] + lines[lastLine].length;
      blocks.add(
        SourceBlock(
          start: start,
          end: end,
          source: source.substring(start, end),
          kind: kind,
        ),
      );
    }

    var i = 0;
    while (i < lines.length) {
      final trimmed = lines[i].trim();
      if (trimmed.isEmpty) {
        i++;
        continue;
      }

      // 围栏代码块(未闭合吃到文末)
      final fence = _fenceRe.firstMatch(trimmed);
      if (fence != null) {
        final first = i;
        i++;
        while (i < lines.length && lines[i].trim() != fence[1]) {
          i++;
        }
        if (i < lines.length) i++; // 闭合围栏行
        add(first, i - 1, SourceBlockKind.code);
        continue;
      }

      // 公式块
      if (trimmed.startsWith(r'$$')) {
        final first = i;
        if (trimmed.length > 4 && trimmed.endsWith(r'$$')) {
          add(first, i, SourceBlockKind.math);
          i++;
          continue;
        }
        i++;
        while (i < lines.length && lines[i].trim() != r'$$') {
          i++;
        }
        if (i < lines.length) i++;
        add(first, i - 1, SourceBlockKind.math);
        continue;
      }

      // 表格:当前行含 | 且下一行是分隔行
      if (lines[i].contains('|') &&
          i + 1 < lines.length &&
          _tableSeparatorRe.hasMatch(lines[i + 1]) &&
          lines[i + 1].contains('-')) {
        final first = i;
        i += 2;
        while (i < lines.length && lines[i].contains('|')) {
          i++;
        }
        add(first, i - 1, SourceBlockKind.table);
        continue;
      }

      if (_dividerRe.hasMatch(trimmed)) {
        add(i, i, SourceBlockKind.divider);
        i++;
        continue;
      }

      if (_imageLineRe.hasMatch(trimmed)) {
        add(i, i, SourceBlockKind.image);
        i++;
        continue;
      }

      // 文本块:连续非空行,遇到空行或上述结构块起始行结束
      final first = i;
      while (i < lines.length) {
        final t = lines[i].trim();
        if (t.isEmpty ||
            _fenceRe.hasMatch(t) ||
            t.startsWith(r'$$') ||
            _imageLineRe.hasMatch(t)) {
          break;
        }
        if (lines[i].contains('|') &&
            i + 1 < lines.length &&
            _tableSeparatorRe.hasMatch(lines[i + 1]) &&
            lines[i + 1].contains('-')) {
          break;
        }
        i++;
      }
      add(first, i - 1, SourceBlockKind.text);
    }
    return blocks;
  }

  /// 把块的新内容写回全文。空内容 = 删除该块并收拢多余空行。
  static String replaceBlock(
    String source,
    SourceBlock block,
    String newText,
  ) {
    final trimmedNew = newText.trimRight();
    var before = source.substring(0, block.start);
    var after = source.substring(block.end);
    if (trimmedNew.trim().isEmpty) {
      // 删块:去掉块前的分隔空行,避免留下连续空行
      before = before.replaceFirst(RegExp(r'\n+$'), '\n');
      if (before.trim().isEmpty) before = '';
      after = after.replaceFirst(RegExp(r'^\n+'), before.isEmpty ? '' : '\n');
      return before + after;
    }
    return before + trimmedNew + after;
  }

  /// 在文末追加一个新块(保证与已有内容之间空一行)
  static String appendBlock(String source, String text) {
    final trimmed = source.trimRight();
    if (trimmed.isEmpty) return text;
    return '$trimmed\n\n$text';
  }

  /// 把第 [from] 块移动到 [to] 位置(拖拽排序)。
  /// 重排后统一以单个空行分隔(多余空行被规整)。
  static String moveBlock(String source, int from, int to) {
    final blocks = split(source);
    if (from < 0 ||
        from >= blocks.length ||
        to < 0 ||
        to >= blocks.length ||
        from == to) {
      return source;
    }
    final sources = [for (final b in blocks) b.source];
    final moved = sources.removeAt(from);
    sources.insert(to, moved);
    return sources.join('\n\n');
  }
}
