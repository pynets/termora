import 'package:termora/features/notes/domain/note.dart';

/// 大纲里的一个标题
class OutlineEntry {
  const OutlineEntry({
    required this.level,
    required this.title,
    required this.offset,
  });

  final int level; // 1..6

  /// 剥掉行内标记后的纯文本标题
  final String title;

  /// 标题行行首在全文中的偏移(跳转/定位用)
  final int offset;

  @override
  String toString() => 'OutlineEntry(h$level "$title" @$offset)';
}

/// 从 markdown 源码提取标题大纲(marktext 侧栏 outline 的数据层)
class MarkdownOutline {
  MarkdownOutline._();

  static final _headingRe = RegExp(r'^\s*(#{1,6})\s+(.+)$');
  static final _fenceRe = RegExp(r'^(```|~~~)');

  static List<OutlineEntry> extract(String text) {
    final entries = <OutlineEntry>[];
    var offset = 0;
    String? fence;
    var inMath = false;

    for (final line in text.split('\n')) {
      final trimmed = line.trim();
      if (fence != null) {
        if (trimmed == fence) fence = null;
      } else if (inMath) {
        if (trimmed == r'$$') inMath = false;
      } else if (_fenceRe.hasMatch(trimmed)) {
        fence = _fenceRe.firstMatch(trimmed)![1];
      } else if (trimmed.startsWith(r'$$') &&
          !(trimmed.length > 4 && trimmed.endsWith(r'$$'))) {
        inMath = true;
      } else {
        final m = _headingRe.firstMatch(line);
        if (m != null) {
          final title = Note.stripMarkdownLine(m[2]!);
          if (title.isNotEmpty) {
            entries.add(
              OutlineEntry(
                level: m[1]!.length,
                title: title,
                offset: offset,
              ),
            );
          }
        }
      }
      offset += line.length + 1;
    }
    return entries;
  }

  /// 光标所在的章节(其后没有更近的标题);无标题或光标在首个标题前返回 null
  static OutlineEntry? activeEntry(List<OutlineEntry> entries, int caret) {
    OutlineEntry? active;
    for (final e in entries) {
      if (e.offset > caret) break;
      active = e;
    }
    return active;
  }
}
