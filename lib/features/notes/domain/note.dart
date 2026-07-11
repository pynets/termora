import 'package:termora/core/l10n/app_l10n.dart';
/// 一条 markdown 笔记。标题不单独存储,从正文首个有效行推导,
/// 与 marktext 一致:文件即内容,改第一行标题就变。
class Note {
  const Note({
    required this.id,
    required this.content,
    required this.createdAt,
    required this.updatedAt,
    this.pinned = false,
    this.notebookId,
  });

  final String id;
  final String content;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// 置顶(列表排序优先于更新时间)
  final bool pinned;

  /// 所属笔记本;null = 未分组(默认)
  final String? notebookId;

  /// 列表展示标题:第一个非空行,剥掉行首 markdown 标记
  String get title {
    for (final line in content.split('\n')) {
      final stripped = stripMarkdownLine(line);
      if (stripped.isNotEmpty) return stripped;
    }
    return tr('无标题笔记');
  }

  /// 列表摘要:标题之后的第一个非空行
  String get summary {
    var titleSeen = false;
    for (final line in content.split('\n')) {
      final stripped = stripMarkdownLine(line);
      if (stripped.isEmpty) continue;
      if (!titleSeen) {
        titleSeen = true;
        continue;
      }
      return stripped;
    }
    return '';
  }

  static final _cjkRe = RegExp(r'[㐀-䶿一-鿿豈-﫿]');
  static final _wordRe = RegExp(r'[A-Za-z0-9_]+');

  /// 字数统计(marktext 顶栏的 W 计数):中日韩每字算 1,拉丁/数字连串算 1 词
  static int wordCount(String content) =>
      _cjkRe.allMatches(content).length + _wordRe.allMatches(content).length;

  static final _naturalChunkRe = RegExp(r'\d+|\D+');

  /// 数字自然排序:数字串按数值比较("第2章" < "第10章"),
  /// 其余按不区分大小写的字符顺序。列表"按名称排序"用。
  static int naturalCompare(String a, String b) {
    final aChunks = _naturalChunkRe.allMatches(a).map((m) => m[0]!).toList();
    final bChunks = _naturalChunkRe.allMatches(b).map((m) => m[0]!).toList();
    final n = aChunks.length < bChunks.length
        ? aChunks.length
        : bChunks.length;
    for (var i = 0; i < n; i++) {
      final x = aChunks[i];
      final y = bChunks[i];
      final xNum = int.tryParse(x);
      final yNum = int.tryParse(y);
      int result;
      if (xNum != null && yNum != null) {
        result = xNum.compareTo(yNum);
      } else {
        result = x.toLowerCase().compareTo(y.toLowerCase());
      }
      if (result != 0) return result;
    }
    return aChunks.length.compareTo(bChunks.length);
  }

  /// 去掉一行文本的 markdown 语法噪音(用于标题/摘要预览)
  static String stripMarkdownLine(String line) {
    var s = line.trim();
    // 代码围栏/水平线整行不算内容
    if (RegExp(r'^(```|~~~)').hasMatch(s)) return '';
    if (RegExp(r'^([-*_])\s*(\1\s*){2,}$').hasMatch(s)) return '';
    s = s.replaceFirst(RegExp(r'^#{1,6}\s+'), '');
    s = s.replaceFirst(RegExp(r'^>\s*'), '');
    s = s.replaceFirst(RegExp(r'^([-*+]|\d+[.)])\s+(\[[ xX]\]\s+)?'), '');
    // 行内标记:加粗/斜体/删除线/行内代码/链接
    s = s.replaceAllMapped(
      RegExp(r'\*\*\*(.+?)\*\*\*|\*\*(.+?)\*\*|\*(.+?)\*|~~(.+?)~~|`(.+?)`'),
      (m) => m[1] ?? m[2] ?? m[3] ?? m[4] ?? m[5] ?? '',
    );
    s = s.replaceAllMapped(
      RegExp(r'!?\[([^\]]*)\]\(([^)]*)\)'),
      (m) => m[1] ?? '',
    );
    return s.trim();
  }

  Note copyWith({
    String? content,
    DateTime? updatedAt,
    bool? pinned,
    String? notebookId,
    bool clearNotebook = false,
  }) => Note(
    id: id,
    content: content ?? this.content,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    pinned: pinned ?? this.pinned,
    notebookId: clearNotebook ? null : (notebookId ?? this.notebookId),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'content': content,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
    if (pinned) 'pinned': true,
    if (notebookId != null) 'notebookId': notebookId,
  };

  factory Note.fromJson(Map<String, dynamic> json) => Note(
    id: json['id'] as String? ?? '',
    content: json['content'] as String? ?? '',
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      json['createdAt'] as int? ?? 0,
    ),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(
      json['updatedAt'] as int? ?? 0,
    ),
    pinned: json['pinned'] as bool? ?? false,
    notebookId: json['notebookId'] as String?,
  );
}

/// 笔记本(分组)
class Notebook {
  const Notebook({required this.id, required this.name});

  final String id;
  final String name;

  Map<String, dynamic> toJson() => {'id': id, 'name': name};

  factory Notebook.fromJson(Map<String, dynamic> json) => Notebook(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
  );
}
