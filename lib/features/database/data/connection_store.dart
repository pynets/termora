import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:termora/features/database/domain/db_models.dart';

/// 连接配置持久化 — shared_preferences 存 JSON 列表
class DbConnectionStore {
  DbConnectionStore._();

  static const _key = 'database.connections.v1';

  static Future<List<DbConnectionConfig>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .whereType<Map<String, dynamic>>()
          .map(DbConnectionConfig.fromJson)
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(List<DbConnectionConfig> connections) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode([for (final c in connections) c.toJson()]),
    );
  }
}
