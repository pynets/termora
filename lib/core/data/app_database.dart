import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

/// 应用内部 SQLite(termora.db)— 「会增长、要查询」数据的统一存储:
/// 命令历史、SFTP 传输记录、笔记全文搜索索引。
/// 分工不变:设置与小快照仍在 shared_preferences,笔记正文仍是 .md 文件。
///
/// 落盘在应用支持目录(与 notes/ 同级);同步 API(sqlite3 FFI),
/// 单条语句亚毫秒级,桌面 UI isolate 直接调用无压力。
class AppDatabase {
  AppDatabase._(this.db);

  final Database db;

  static AppDatabase? _instance;
  static Database? _debugOverride;

  /// 是否支持 FTS5 trigram 分词(中英文子串搜索);
  /// 老 SQLite(<3.34)建表失败时为 false,笔记搜索回落内存过滤
  bool trigramAvailable = false;

  /// 测试注入:改用 in-memory 库(重置单例)
  static void debugUseDatabase(Database? db) {
    _instance?.db.close();
    _instance = null;
    _debugOverride = db;
  }

  /// 已初始化的实例(同步;未初始化返回 null,调用方走回落路径)。
  /// 供 build/getter 等无法 await 的位置使用。
  static AppDatabase? get maybeInstance => _instance;

  static Future<AppDatabase> instance() async {
    final existing = _instance;
    if (existing != null) return existing;
    final Database db;
    if (_debugOverride != null) {
      db = _debugOverride!;
    } else {
      final base = await getApplicationSupportDirectory();
      db = sqlite3.open(p.join(base.path, 'termora.db'));
    }
    final created = AppDatabase._(db);
    created._migrate();
    return _instance = created;
  }

  void _migrate() {
    db.execute('PRAGMA journal_mode = WAL');
    final version =
        db.select('PRAGMA user_version').first.columnAt(0) as int;
    if (version < 1) {
      db.execute('''
        CREATE TABLE IF NOT EXISTS meta(
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS command_history(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          session_key TEXT NOT NULL,
          command TEXT NOT NULL,
          used_at INTEGER NOT NULL,
          UNIQUE(session_key, command)
        );
        CREATE INDEX IF NOT EXISTS idx_history_session
          ON command_history(session_key, used_at);
        CREATE TABLE IF NOT EXISTS transfer_log(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          host TEXT NOT NULL,
          label TEXT NOT NULL,
          is_upload INTEGER NOT NULL,
          state TEXT NOT NULL,
          error TEXT,
          total INTEGER,
          finished_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_transfer_host
          ON transfer_log(host, finished_at DESC);
      ''');
      db.execute('PRAGMA user_version = 1');
    }
    if (version < 2) {
      // v2:命令使用次数(喂给 Tab 补全的频率排序)
      db.execute(
        'ALTER TABLE command_history '
        'ADD COLUMN use_count INTEGER NOT NULL DEFAULT 1',
      );
      db.execute('PRAGMA user_version = 2');
    }
    // FTS 虚表单独建:trigram 需要 SQLite ≥3.34(macOS 系统库满足),
    // 失败不致命 —— 笔记搜索回落内存过滤
    try {
      db.execute('''
        CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts
          USING fts5(id UNINDEXED, content, tokenize='trigram')
      ''');
      trigramAvailable = true;
    } catch (_) {
      trigramAvailable = false;
    }
  }

  String? getMeta(String key) {
    final rows = db.select('SELECT value FROM meta WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.first.columnAt(0) as String;
  }

  void setMeta(String key, String value) {
    db.execute(
      'INSERT INTO meta(key, value) VALUES(?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      [key, value],
    );
  }
}
