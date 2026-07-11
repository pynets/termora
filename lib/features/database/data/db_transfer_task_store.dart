import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:termora/features/database/domain/db_transfer_task.dart';

/// 传输任务持久化 — shared_preferences 存 JSON 列表(参考 connection_store)
class DbTransferTaskStore {
  DbTransferTaskStore._();

  static const _key = 'database.transfer_tasks.v1';

  static Future<List<DbTransferTask>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .whereType<Map<String, dynamic>>()
          .map(DbTransferTask.fromJson)
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(List<DbTransferTask> tasks) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode([for (final t in tasks) t.toJson()]),
    );
  }
}
