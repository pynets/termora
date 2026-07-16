import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 一条已打开表 Tab 的快照
class OpenTableSnapshot {
  const OpenTableSnapshot({
    required this.schema,
    required this.table,
    this.isView = false,
  });

  final String schema;
  final String table;
  final bool isView;

  String get key => '$schema.$table';

  Map<String, dynamic> toJson() => {
    'schema': schema,
    'table': table,
    'isView': isView,
  };

  factory OpenTableSnapshot.fromJson(Map<String, dynamic> json) =>
      OpenTableSnapshot(
        schema: json['schema'] as String? ?? '',
        table: json['table'] as String? ?? '',
        isView: json['isView'] as bool? ?? false,
      );
}

/// 某个连接的数据库工作区快照(打开的表 + 活动表)
class DbWorkspaceSnapshot {
  const DbWorkspaceSnapshot({this.openTables = const [], this.activeTableKey});

  final List<OpenTableSnapshot> openTables;

  /// 活动表 Tab 的 key(schema.table);null 表示活动的是 SQL 页
  final String? activeTableKey;

  Map<String, dynamic> toJson() => {
    'openTables': [for (final t in openTables) t.toJson()],
    'activeTableKey': activeTableKey,
  };

  factory DbWorkspaceSnapshot.fromJson(Map<String, dynamic> json) =>
      DbWorkspaceSnapshot(
        openTables: [
          for (final t in (json['openTables'] as List<dynamic>? ?? []))
            OpenTableSnapshot.fromJson(t as Map<String, dynamic>),
        ],
        activeTableKey: json['activeTableKey'] as String?,
      );
}

/// 会话/界面恢复的持久化(shared_preferences)
///
/// 存量都小、结构化、整体读写,故用 shared_preferences 而非 sqlite:
/// - 顶层选中的功能页(终端/数据库)
/// - SQL 编辑器当前文本
/// - 每个连接打开了哪些表 Tab(连接成功后再恢复,不在启动时静默连库)
class WorkspaceStore {
  WorkspaceStore._();

  static const _activeFeatureKey = 'app.active_feature';
  static const _railWidthKey = 'app.rail_width';
  static const _sqlTextKey = 'database.sql_text';
  static const _workspacePrefix = 'database.workspace.';
  static const _lastConnectionKey = 'database.last_connection';

  // ── 顶层选中页 ──

  static Future<int> loadActiveFeature() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_activeFeatureKey) ?? 0;
  }

  static Future<void> saveActiveFeature(int index) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_activeFeatureKey, index);
  }

  // ── 左侧导航栏宽度(可拖拽)──

  static Future<double?> loadRailWidth() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_railWidthKey);
  }

  static Future<void> saveRailWidth(double width) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_railWidthKey, width);
  }

  // ── SQL 编辑器文本 ──

  static Future<String> loadSqlText({String? connectionId}) async {
    final prefs = await SharedPreferences.getInstance();
    if (connectionId != null && connectionId.isNotEmpty) {
      final perConn = prefs.getString('database.sql_text.$connectionId');
      if (perConn != null) return perConn;
      return prefs.getString(_sqlTextKey) ?? '';
    }
    return prefs.getString(_sqlTextKey) ?? '';
  }

  static Future<void> saveSqlText(String text, {String? connectionId}) async {
    final prefs = await SharedPreferences.getInstance();
    if (connectionId != null && connectionId.isNotEmpty) {
      await prefs.setString('database.sql_text.$connectionId', text);
    } else {
      await prefs.setString(_sqlTextKey, text);
    }
  }

  // ── 上次活动连接(启动时自动重连)──

  static Future<String?> loadLastConnection() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_lastConnectionKey);
  }

  static Future<void> saveLastConnection(String connectionId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastConnectionKey, connectionId);
  }

  static Future<void> clearLastConnection() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_lastConnectionKey);
  }

  // ── 每连接工作区(打开的表 Tab)──

  static Future<DbWorkspaceSnapshot> loadWorkspace(String connectionId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_workspacePrefix$connectionId');
    if (raw == null || raw.isEmpty) return const DbWorkspaceSnapshot();
    try {
      return DbWorkspaceSnapshot.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      return const DbWorkspaceSnapshot();
    }
  }

  static Future<void> saveWorkspace(
    String connectionId,
    DbWorkspaceSnapshot snapshot,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      '$_workspacePrefix$connectionId',
      jsonEncode(snapshot.toJson()),
    );
  }

  static Future<void> clearWorkspace(String connectionId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_workspacePrefix$connectionId');
  }
}
