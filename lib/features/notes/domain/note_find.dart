import 'package:flutter/services.dart';

/// 笔记内查找/替换 — 纯函数,供查找条与编辑控制器共用
class NoteFind {
  NoteFind._();

  /// 大小写不敏感的非重叠命中区间,按起点升序
  static List<TextRange> matches(String text, String query) {
    if (query.isEmpty) return const [];
    final haystack = text.toLowerCase();
    final needle = query.toLowerCase();
    final result = <TextRange>[];
    var from = 0;
    while (true) {
      final at = haystack.indexOf(needle, from);
      if (at < 0) break;
      result.add(TextRange(start: at, end: at + needle.length));
      from = at + needle.length;
    }
    return result;
  }

  /// 光标之后(含光标处)的第一个命中下标;没有则回绕到 0。空列表返回 -1。
  static int activeIndexFor(List<TextRange> matches, int caret) {
    if (matches.isEmpty) return -1;
    for (final (index, m) in matches.indexed) {
      if (m.start >= caret) return index;
    }
    return 0;
  }

  /// 替换单个命中,光标落到替换文本之后
  static TextEditingValue replaceMatch(
    TextEditingValue value,
    TextRange match,
    String replacement,
  ) {
    final text = value.text;
    if (match.start < 0 || match.end > text.length) return value;
    return TextEditingValue(
      text: text.substring(0, match.start) +
          replacement +
          text.substring(match.end),
      selection: TextSelection.collapsed(
        offset: match.start + replacement.length,
      ),
    );
  }

  /// 全部替换,返回(新值, 替换数)。从后往前替换避免偏移失效。
  static (TextEditingValue, int) replaceAll(
    TextEditingValue value,
    String query,
    String replacement,
  ) {
    final found = matches(value.text, query);
    if (found.isEmpty) return (value, 0);
    var text = value.text;
    for (final m in found.reversed) {
      text = text.substring(0, m.start) + replacement + text.substring(m.end);
    }
    return (
      TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      ),
      found.length,
    );
  }
}
