import 'package:flutter/services.dart';

/// markdown 编辑操作 — 对 TextEditingValue 做纯函数变换,
/// 工具栏按钮与快捷键共用,便于单测。
class MarkdownEditing {
  MarkdownEditing._();

  // ══════════════ 行内标记 ══════════════

  /// 用 [marker] 包裹/解包选区(粗体 ** 、斜体 * 、删除线 ~~ 、行内代码 `)。
  /// 无选区时插入一对标记并把光标停在中间。
  static TextEditingValue toggleInline(TextEditingValue value, String marker) {
    final text = value.text;
    final sel = _normalized(value.selection, text.length);
    final start = sel.start;
    final end = sel.end;
    final selected = text.substring(start, end);
    final n = marker.length;

    if (start == end) {
      final next = text.substring(0, start) + marker * 2 + text.substring(end);
      return TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: start + n),
      );
    }

    // 选区自带标记 → 解包
    if (selected.length >= n * 2 &&
        selected.startsWith(marker) &&
        selected.endsWith(marker)) {
      final inner = selected.substring(n, selected.length - n);
      final next = text.substring(0, start) + inner + text.substring(end);
      return TextEditingValue(
        text: next,
        selection: TextSelection(baseOffset: start, extentOffset: start + inner.length),
      );
    }

    // 选区外侧紧贴标记 → 解包
    if (start >= n &&
        end + n <= text.length &&
        text.substring(start - n, start) == marker &&
        text.substring(end, end + n) == marker) {
      final next = text.substring(0, start - n) + selected + text.substring(end + n);
      return TextEditingValue(
        text: next,
        selection: TextSelection(
          baseOffset: start - n,
          extentOffset: start - n + selected.length,
        ),
      );
    }

    // 包裹
    final next =
        text.substring(0, start) + marker + selected + marker + text.substring(end);
    return TextEditingValue(
      text: next,
      selection: TextSelection(
        baseOffset: start + n,
        extentOffset: start + n + selected.length,
      ),
    );
  }

  /// 清除选区内的行内标记(粗/斜/删/行内代码/链接留文字)
  static TextEditingValue clearInline(TextEditingValue value) {
    final text = value.text;
    final sel = _normalized(value.selection, text.length);
    if (sel.start == sel.end) return value;
    var inner = text.substring(sel.start, sel.end);
    final markRe = RegExp(
      r'\*\*\*(.+?)\*\*\*|\*\*(.+?)\*\*|\*(.+?)\*|~~(.+?)~~|`(.+?)`',
    );
    final linkRe = RegExp(r'!?\[([^\]]*)\]\(([^)]*)\)');
    String previous;
    do {
      previous = inner;
      inner = inner.replaceAllMapped(
        markRe,
        (m) => m[1] ?? m[2] ?? m[3] ?? m[4] ?? m[5] ?? '',
      );
      inner = inner.replaceAllMapped(linkRe, (m) => m[1] ?? '');
    } while (inner != previous);
    final next = text.substring(0, sel.start) + inner + text.substring(sel.end);
    return TextEditingValue(
      text: next,
      selection: TextSelection(
        baseOffset: sel.start,
        extentOffset: sel.start + inner.length,
      ),
    );
  }

  // ══════════════ 行级前缀 ══════════════

  static final _headingPrefixRe = RegExp(r'^(#{1,6})\s+');
  static final _orderedPrefixRe = RegExp(r'^\d{1,9}[.)]\s+');

  /// 给选中的所有行加/去 [prefix](- 、> 、- [ ] )。
  /// 全部行已有该前缀 → 移除,否则补齐。
  static TextEditingValue toggleLinePrefix(
    TextEditingValue value,
    String prefix,
  ) {
    return _transformLines(value, (lines) {
      final targets = lines.where((l) => l.trim().isNotEmpty);
      final allHave =
          targets.isNotEmpty && targets.every((l) => l.startsWith(prefix));
      return [
        for (final l in lines)
          if (l.trim().isEmpty)
            l
          else if (allHave)
            l.substring(prefix.length)
          else
            prefix + _stripListPrefix(l),
      ];
    });
  }

  /// 有序列表:全部行已编号 → 去编号,否则按 1. 2. 3. 重新编号
  static TextEditingValue toggleOrderedList(TextEditingValue value) {
    return _transformLines(value, (lines) {
      final targets = lines.where((l) => l.trim().isNotEmpty);
      final allHave = targets.isNotEmpty &&
          targets.every((l) => _orderedPrefixRe.hasMatch(l));
      var number = 0;
      return [
        for (final l in lines)
          if (l.trim().isEmpty)
            l
          else if (allHave)
            l.replaceFirst(_orderedPrefixRe, '')
          else
            '${++number}. ${_stripListPrefix(l)}',
      ];
    });
  }

  /// 设置标题级别;当前已是该级 → 转回正文
  static TextEditingValue setHeading(TextEditingValue value, int level) {
    return _transformLines(value, (lines) {
      return [
        for (final l in lines)
          if (l.trim().isEmpty)
            l
          else
            _applyHeading(l, level),
      ];
    });
  }

  static String _applyHeading(String line, int level) {
    final existing = _headingPrefixRe.firstMatch(line);
    final body = existing == null ? line : line.substring(existing.end);
    if (existing != null && existing[1]!.length == level) return body;
    return '${'#' * level} $body';
  }

  /// 去掉已有的列表/引用前缀,避免叠加出 "- - x"
  static String _stripListPrefix(String line) {
    return line
        .replaceFirst(RegExp(r'^([-*+]\s+(\[[ xX]\]\s+)?)'), '')
        .replaceFirst(_orderedPrefixRe, '')
        .replaceFirst(RegExp(r'^>\s+'), '');
  }

  /// 对选区覆盖的整行做变换,并选中变换后的行范围
  static TextEditingValue _transformLines(
    TextEditingValue value,
    List<String> Function(List<String>) transform,
  ) {
    final text = value.text;
    final sel = _normalized(value.selection, text.length);
    var lineStart = text.lastIndexOf('\n', sel.start > 0 ? sel.start - 1 : 0);
    lineStart = lineStart < 0 ? 0 : lineStart + 1;
    if (sel.start == 0) lineStart = 0;
    var lineEnd = text.indexOf('\n', sel.end);
    if (lineEnd < 0) lineEnd = text.length;

    final replaced = transform(
      text.substring(lineStart, lineEnd).split('\n'),
    ).join('\n');
    final next = text.substring(0, lineStart) + replaced + text.substring(lineEnd);
    return TextEditingValue(
      text: next,
      selection: TextSelection(
        baseOffset: lineStart,
        extentOffset: lineStart + replaced.length,
      ),
    );
  }

  // ══════════════ 插入 ══════════════

  /// 链接:有选区 → [选区](url) 并选中 url 占位;无选区 → 完整占位
  static TextEditingValue insertLink(TextEditingValue value) =>
      _insertWrapped(value, '[', '](url)', placeholder: '链接文字', target: 'url');

  /// 图片:alt 用选区或占位,并选中地址占位
  static TextEditingValue insertImage(TextEditingValue value) =>
      _insertWrapped(value, '![', '](图片地址)', placeholder: '描述', target: '图片地址');

  static TextEditingValue _insertWrapped(
    TextEditingValue value,
    String prefix,
    String suffix, {
    required String placeholder,
    required String target,
  }) {
    final text = value.text;
    final sel = _normalized(value.selection, text.length);
    final label = sel.start == sel.end
        ? placeholder
        : text.substring(sel.start, sel.end);
    final inserted = '$prefix$label$suffix';
    final next =
        text.substring(0, sel.start) + inserted + text.substring(sel.end);
    // 选中 url/地址占位,直接输入即可替换
    final targetStart =
        sel.start + prefix.length + label.length + 2; // "](" 两个字符
    return TextEditingValue(
      text: next,
      selection: TextSelection(
        baseOffset: targetStart,
        extentOffset: targetStart + target.length,
      ),
    );
  }

  /// 在光标处按块插入模板(前后保证空行),光标落到 [caretOffset] 或模板末尾
  static TextEditingValue insertBlock(
    TextEditingValue value,
    String block, {
    int? caretOffset,
  }) {
    final text = value.text;
    final sel = _normalized(value.selection, text.length);
    final before = text.substring(0, sel.start);
    final after = text.substring(sel.end);

    var head = '';
    if (before.isNotEmpty && !before.endsWith('\n')) {
      head = '\n\n';
    } else if (before.endsWith('\n') && !before.endsWith('\n\n')) {
      head = '\n';
    }
    var tail = '';
    if (after.isNotEmpty && !after.startsWith('\n')) {
      tail = '\n';
    }

    final insertion = '$head$block$tail';
    final caret =
        sel.start + head.length + (caretOffset ?? block.length);
    return TextEditingValue(
      text: before + insertion + after,
      selection: TextSelection.collapsed(offset: caret),
    );
  }

  static TextSelection _normalized(TextSelection selection, int length) {
    if (!selection.isValid) return const TextSelection.collapsed(offset: 0);
    final start = selection.start.clamp(0, length);
    final end = selection.end.clamp(0, length);
    return TextSelection(baseOffset: start, extentOffset: end);
  }

  // ══════════════ Tab 缩进 ══════════════

  static const _indent = '  ';

  /// Tab:光标在列表行 → 整行缩进(嵌套一层);普通行 → 光标处插两空格;
  /// 多行选区 → 覆盖的每个非空行都缩进,选区跟随。
  static TextEditingValue indentLines(TextEditingValue value) {
    final text = value.text;
    final sel = _normalized(value.selection, text.length);

    if (sel.start == sel.end) {
      final lineStart = _lineStartOf(text, sel.start);
      var lineEnd = text.indexOf('\n', sel.start);
      if (lineEnd < 0) lineEnd = text.length;
      final line = text.substring(lineStart, lineEnd);
      final insertAt = _continuableLineRe.hasMatch(line) ? lineStart : sel.start;
      return TextEditingValue(
        text: text.substring(0, insertAt) + _indent + text.substring(insertAt),
        selection: TextSelection.collapsed(offset: sel.start + _indent.length),
      );
    }

    final lineStart = _lineStartOf(text, sel.start);
    var lineEnd = text.indexOf('\n', sel.end);
    if (lineEnd < 0) lineEnd = text.length;
    var indentedFirst = 0;
    var indentedTotal = 0;
    var isFirst = true;
    final lines = <String>[];
    for (final l in text.substring(lineStart, lineEnd).split('\n')) {
      if (l.trim().isEmpty) {
        lines.add(l);
      } else {
        lines.add('$_indent$l');
        if (isFirst) indentedFirst = _indent.length;
        indentedTotal += _indent.length;
      }
      isFirst = false;
    }
    return TextEditingValue(
      text: text.substring(0, lineStart) +
          lines.join('\n') +
          text.substring(lineEnd),
      selection: TextSelection(
        baseOffset: sel.start + indentedFirst,
        extentOffset: sel.end + indentedTotal,
      ),
    );
  }

  /// Shift+Tab:覆盖的每行行首去掉最多两个空格,选区/光标跟随
  static TextEditingValue outdentLines(TextEditingValue value) {
    final text = value.text;
    final sel = _normalized(value.selection, text.length);
    final lineStart = _lineStartOf(text, sel.start);
    var lineEnd = text.indexOf('\n', sel.end);
    if (lineEnd < 0) lineEnd = text.length;

    var removedFirst = 0;
    var removedTotal = 0;
    var isFirst = true;
    final lines = <String>[];
    for (final l in text.substring(lineStart, lineEnd).split('\n')) {
      var removed = 0;
      while (removed < _indent.length &&
          removed < l.length &&
          l[removed] == ' ') {
        removed++;
      }
      if (isFirst) {
        isFirst = false;
        removedFirst = removed;
      }
      removedTotal += removed;
      lines.add(l.substring(removed));
    }

    return TextEditingValue(
      text: text.substring(0, lineStart) +
          lines.join('\n') +
          text.substring(lineEnd),
      selection: TextSelection(
        baseOffset: (sel.start - removedFirst).clamp(lineStart, text.length),
        extentOffset: (sel.end - removedTotal).clamp(lineStart, text.length),
      ),
    );
  }

  static int _lineStartOf(String text, int offset) =>
      offset == 0 ? 0 : text.lastIndexOf('\n', offset - 1) + 1;

  // ══════════════ 任务勾选 ══════════════

  /// 任务行(可带引用前缀),与解析器的 taskIndex 计数口径一致
  static final _taskLineRe =
      RegExp(r'^((?:\s*>\s*)*\s*[-*+]\s+\[)([ xX])(\]\s?.*)$');

  /// 翻转全文中第 [ordinal](从 0 起)个任务项的勾选态;越界原样返回
  static String toggleTaskAt(String text, int ordinal) {
    final lines = text.split('\n');
    var seen = 0;
    for (var i = 0; i < lines.length; i++) {
      final m = _taskLineRe.firstMatch(lines[i]);
      if (m == null) continue;
      if (seen++ == ordinal) {
        final flipped = m[2] == ' ' ? 'x' : ' ';
        lines[i] = '${m[1]}$flipped${m[3]}';
        break;
      }
    }
    return lines.join('\n');
  }

  /// 在光标处插入文本(有选区则替换),光标落在插入内容之后
  static TextEditingValue insertText(TextEditingValue value, String text) {
    final current = value.text;
    final sel = _normalized(value.selection, current.length);
    return TextEditingValue(
      text: current.substring(0, sel.start) + text + current.substring(sel.end),
      selection: TextSelection.collapsed(offset: sel.start + text.length),
    );
  }

  // ══════════════ 拖拽插入 ══════════════

  static const _imageExtensions = {
    'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'svg',
  };

  /// 拖文件进编辑器:图片 → ![名](路径),其他 → [名](路径),按块插入光标处
  static TextEditingValue insertDroppedPaths(
    TextEditingValue value,
    List<String> paths,
  ) => insertStoredAssets(value, [for (final p in paths) (p, p)]);

  /// 插入落地后的资源:显示名取原文件名,目标用落地路径。
  /// 图片走图片语法,视频/任意文件走链接语法(预览渲染成附件卡片)。
  static TextEditingValue insertStoredAssets(
    TextEditingValue value,
    List<(String original, String stored)> assets,
  ) {
    if (assets.isEmpty) return value;
    final lines = <String>[];
    for (final (original, stored) in assets) {
      final name = original.split(RegExp(r'[/\\]')).last;
      final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
      lines.add(
        _imageExtensions.contains(ext)
            ? '![$name]($stored)'
            : '[$name]($stored)',
      );
    }
    return insertBlock(value, lines.join('\n'));
  }

  // ══════════════ 回车自动续行(所见即所得) ══════════════

  static final _continuableLineRe = RegExp(
    r'^(\s*)(?:([-*+])\s+(\[[ xX]\]\s+)?|(\d{1,9})([.)])\s+)(.*)$',
  );
  static final _quoteLineRe = RegExp(r'^(\s*(?:>\s*)+)(.*)$');

  /// 在列表/引用行敲回车:有内容 → 新行自动补前缀(有序列表递增编号);
  /// 空项 → 去掉前缀退出列表。仅当变化恰为"插入一个换行"时生效。
  static TextEditingValue autoContinueOnNewline(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (!newValue.selection.isCollapsed) return newValue;
    final caret = newValue.selection.baseOffset;
    if (newValue.text.length != oldValue.text.length + 1 || caret < 1) {
      return newValue;
    }
    if (newValue.text[caret - 1] != '\n') return newValue;
    // 确认是在光标处插入了一个换行(排除粘贴/IME 等其他变化)
    if (newValue.text.substring(0, caret - 1) + newValue.text.substring(caret) !=
        oldValue.text) {
      return newValue;
    }

    final lineStart =
        caret >= 2 ? newValue.text.lastIndexOf('\n', caret - 2) + 1 : 0;
    final prevLine = newValue.text.substring(lineStart, caret - 1);

    String? continuation;
    String? emptyCheckContent;
    final list = _continuableLineRe.firstMatch(prevLine);
    if (list != null) {
      emptyCheckContent = list[6];
      continuation = list[2] != null
          ? '${list[1]}${list[2]} ${list[3] != null ? '[ ] ' : ''}'
          : '${list[1]}${int.parse(list[4]!) + 1}${list[5]} ';
    } else {
      final quote = _quoteLineRe.firstMatch(prevLine);
      if (quote != null) {
        emptyCheckContent = quote[2];
        continuation = quote[1];
      }
    }
    if (continuation == null) return newValue;

    if (emptyCheckContent!.trim().isEmpty) {
      // 空项回车:删掉前缀和刚插的换行,光标回到行首(退出列表)
      final text =
          newValue.text.substring(0, lineStart) + newValue.text.substring(caret);
      return TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: lineStart),
      );
    }

    final text = newValue.text.substring(0, caret) +
        continuation +
        newValue.text.substring(caret);
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: caret + continuation.length),
    );
  }
}

/// 编辑器输入管道:回车自动续列表/引用
class MarkdownAutoContinueFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    return MarkdownEditing.autoContinueOnNewline(oldValue, newValue);
  }
}
