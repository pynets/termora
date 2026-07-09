import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:termora/features/remote/domain/ssh_host.dart';

/// SSH 主机配置持久化 — shared_preferences 存 JSON 列表
class SshHostStore {
  SshHostStore._();

  static const _key = 'remote.ssh_hosts.v1';

  static Future<List<SshHost>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .whereType<Map<String, dynamic>>()
          .map(SshHost.fromJson)
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(List<SshHost> hosts) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode([for (final h in hosts) h.toJson()]));
  }

  /// 确保 ControlMaster socket 目录存在(ssh 不会自建 ControlPath 目录)
  static Future<void> ensureControlDirectory() async {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) return;
    try {
      await Directory('$home/.termora').create(recursive: true);
    } catch (_) {
      // 目录建不出来时 ssh 只是不复用连接,不影响登录本身
    }
  }

  /// ssh 强制私钥 0600,下载/工作目录里的 pem 常是 0644 会被整个忽略
  /// ("UNPROTECTED PRIVATE KEY FILE")。连接前 best-effort 收紧权限。
  static Future<void> tightenKeyPermissions(String keyPath) async {
    if (keyPath.isEmpty) return;
    try {
      await Process.run('/bin/chmod', ['600', keyPath]);
    } catch (_) {
      // chmod 失败就让 ssh 自己报错,不拦连接
    }
  }
}
