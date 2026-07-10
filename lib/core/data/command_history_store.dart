import 'package:shared_preferences/shared_preferences.dart';
import 'package:termora/core/data/app_database.dart';

/// 命令历史 — SQLite 存储(此前是 shared_preferences 每会话一个 key)。
/// 上下键语义不变:按会话隔离,列表旧→新;同命令重复执行去重上移。
/// 全库落盘让历史天然支持将来的跨会话搜索/统计。
class CommandHistoryStore {
  CommandHistoryStore._();

  static const _maxPerSession = 200;

  /// 旧 prefs 前缀(会话级 key = `$_legacyPrefix.sessionKey`,裸 key 为
  /// 更早的全局共享历史);迁移后旧全局历史挂在这个虚拟会话上作新会话种子
  static const _legacyPrefix = 'workbench_terminal_history_v1';
  static const _seedSessionKey = '__legacy_global_seed__';
  static const _migratedFlag = 'command_history_migrated_v1';

  /// 读一个会话的历史(旧→新)。会话还没有自己的历史时,
  /// 回落旧全局种子(与迁移前行为一致)。
  static Future<List<String>> load(String sessionKey) async {
    final app = await AppDatabase.instance();
    await _ensureMigrated(app);
    var rows = app.db.select(
      'SELECT command FROM command_history WHERE session_key = ? '
      'ORDER BY used_at ASC, id ASC LIMIT ?',
      [sessionKey, _maxPerSession],
    );
    if (rows.isEmpty) {
      rows = app.db.select(
        'SELECT command FROM command_history WHERE session_key = ? '
        'ORDER BY used_at ASC, id ASC LIMIT ?',
        [_seedSessionKey, _maxPerSession],
      );
    }
    return [for (final r in rows) r.columnAt(0) as String];
  }

  /// 记录一条命令:同会话同命令去重上移,并裁掉超出上限的最旧条目。
  /// used_at 取「墙钟」与「全库现有最大值 + 1」的较大者:同一毫秒内
  /// 连续执行也保持严格单调,会话内与跨会话搜索的排序都反映使用顺序。
  static Future<void> record(String sessionKey, String command) async {
    final app = await AppDatabase.instance();
    final now = DateTime.now().millisecondsSinceEpoch;
    app.db.execute(
      'INSERT INTO command_history(session_key, command, used_at) '
      'VALUES(?, ?, MAX(?, COALESCE('
      '  (SELECT MAX(used_at) + 1 FROM command_history), 0))) '
      'ON CONFLICT(session_key, command) DO UPDATE '
      'SET used_at = excluded.used_at, use_count = use_count + 1',
      [sessionKey, command, now],
    );
    app.db.execute(
      'DELETE FROM command_history WHERE session_key = ? AND id NOT IN ('
      '  SELECT id FROM command_history WHERE session_key = ? '
      '  ORDER BY used_at DESC, id DESC LIMIT ?)',
      [sessionKey, sessionKey, _maxPerSession],
    );
  }

  /// 跨会话搜索历史(全库、去重、最近使用优先)。
  /// [query] 为空返回全局最近命令;匹配是大小写不敏感的子串(LIKE)。
  static Future<List<String>> search(String query, {int limit = 50}) async {
    final app = await AppDatabase.instance();
    await _ensureMigrated(app);
    final escaped = query
        .replaceAll(r'\', r'\\')
        .replaceAll('%', r'\%')
        .replaceAll('_', r'\_');
    final rows = app.db.select(
      'SELECT command, MAX(used_at) AS last_used FROM command_history '
      "WHERE command LIKE ? ESCAPE '\\' "
      'GROUP BY command ORDER BY last_used DESC LIMIT ?',
      ['%$escaped%', limit],
    );
    return [for (final r in rows) r.columnAt(0) as String];
  }

  /// 按命令首词聚合的全库使用次数(Tab 补全的频率排序依据)。
  /// 表规模 = 每会话 ≤200 条,内存聚合亚毫秒级。
  static Future<Map<String, int>> usageByFirstToken() async {
    final app = await AppDatabase.instance();
    await _ensureMigrated(app);
    final rows = app.db.select(
      'SELECT command, use_count FROM command_history',
    );
    final usage = <String, int>{};
    for (final row in rows) {
      final command = (row.columnAt(0) as String).trim();
      if (command.isEmpty) continue;
      final first = command.split(RegExp(r'\s+')).first;
      usage[first] = (usage[first] ?? 0) + (row.columnAt(1) as int);
    }
    return usage;
  }

  /// 会话被永久关闭后清掉它的历史
  static Future<void> removeSession(String sessionKey) async {
    final app = await AppDatabase.instance();
    app.db.execute(
      'DELETE FROM command_history WHERE session_key = ?',
      [sessionKey],
    );
  }

  /// 一次性迁移旧 prefs 历史(幂等):
  /// - `$_legacyPrefix.sessionKey` → 对应会话
  /// - 裸 '$_legacyPrefix'(更早的全局共享) → 种子会话
  /// 迁移完成后删除旧 key,防止双份存储漂移。
  static Future<void> _ensureMigrated(AppDatabase app) async {
    if (app.getMeta(_migratedFlag) == '1') return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs
          .getKeys()
          .where((k) => k == _legacyPrefix || k.startsWith('$_legacyPrefix.'))
          .toList();
      final base = DateTime.now().millisecondsSinceEpoch - 1000000;
      for (final key in keys) {
        final list = prefs.getStringList(key);
        if (list == null || list.isEmpty) continue;
        final sessionKey = key == _legacyPrefix
            ? _seedSessionKey
            : key.substring(_legacyPrefix.length + 1);
        for (var i = 0; i < list.length; i++) {
          final command = list[i].trim();
          if (command.isEmpty) continue;
          app.db.execute(
            'INSERT INTO command_history(session_key, command, used_at) '
            'VALUES(?, ?, ?) '
            'ON CONFLICT(session_key, command) DO UPDATE '
            'SET used_at = excluded.used_at',
            [sessionKey, command, base + i],
          );
        }
        await prefs.remove(key);
      }
    } catch (_) {
      // 迁移失败不阻塞使用(下次启动重试)
      return;
    }
    app.setMeta(_migratedFlag, '1');
  }
}
