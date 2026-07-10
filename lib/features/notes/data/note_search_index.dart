import 'package:termora/core/data/app_database.dart';

/// 笔记全文搜索索引 — SQLite FTS5(trigram 分词,中英文子串匹配,
/// 大小写不敏感,语义与内存 contains 过滤一致但有索引加速)。
/// 笔记正文仍是 .md 文件(本体不动),这里只是索引层:
/// 不可用(老 SQLite / 未初始化 / 短查询)时调用方回落内存过滤。
class NoteSearchIndex {
  NoteSearchIndex._();

  /// trigram 至少 3 个字符才能命中索引
  static const _minQueryLength = 3;

  static bool get _ready =>
      AppDatabase.maybeInstance?.trigramAvailable ?? false;

  /// 全量重建(启动加载后调用一次,之后随保存增量)
  static Future<void> reindexAll(Map<String, String> contentById) async {
    final app = await AppDatabase.instance();
    if (!app.trigramAvailable) return;
    app.db.execute('BEGIN');
    try {
      app.db.execute('DELETE FROM notes_fts');
      for (final entry in contentById.entries) {
        app.db.execute(
          'INSERT INTO notes_fts(id, content) VALUES(?, ?)',
          [entry.key, entry.value],
        );
      }
      app.db.execute('COMMIT');
    } catch (_) {
      app.db.execute('ROLLBACK');
    }
  }

  static void upsert(String id, String content) {
    final app = AppDatabase.maybeInstance;
    if (app == null || !app.trigramAvailable) return;
    app.db.execute('DELETE FROM notes_fts WHERE id = ?', [id]);
    app.db.execute(
      'INSERT INTO notes_fts(id, content) VALUES(?, ?)',
      [id, content],
    );
  }

  static void remove(String id) {
    final app = AppDatabase.maybeInstance;
    if (app == null || !app.trigramAvailable) return;
    app.db.execute('DELETE FROM notes_fts WHERE id = ?', [id]);
  }

  /// 子串搜索,返回命中的笔记 id 集;null = 索引不可用/查询过短,
  /// 调用方应回落内存 contains 过滤(行为不变,只是慢路径)。
  static Set<String>? trySearch(String query) {
    final q = query.trim();
    if (!_ready || q.length < _minQueryLength) return null;
    final app = AppDatabase.maybeInstance!;
    try {
      // 双引号包裹 = FTS5 字符串字面量(trigram 下即子串匹配);
      // 内部双引号按 FTS 语法翻倍转义
      final escaped = q.replaceAll('"', '""');
      final rows = app.db.select(
        'SELECT id FROM notes_fts WHERE notes_fts MATCH ?',
        ['"$escaped"'],
      );
      return {for (final r in rows) r.columnAt(0) as String};
    } catch (_) {
      return null;
    }
  }
}
