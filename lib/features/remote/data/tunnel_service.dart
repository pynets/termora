import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:termora/features/remote/domain/ssh_host.dart';
import 'package:termora/core/l10n/app_l10n.dart';

enum TunnelType {
  local, // -L 本地转发:本地端口 → 经服务器 → 目标
  remote, // -R 远程转发:服务器端口 → 经本地 → 目标
  dynamic, // -D 动态(SOCKS 代理)
}

/// 一条 SSH 端口转发配置。
@immutable
class SshTunnel {
  const SshTunnel({
    required this.id,
    required this.hostId,
    required this.type,
    this.bindAddress = '',
    required this.bindPort,
    this.destHost = 'localhost',
    this.destPort = 0,
  });

  final String id;
  final String hostId;
  final TunnelType type;

  /// 绑定地址(留空:-L/-D 默认本地回环;-R 默认服务器回环)
  final String bindAddress;
  final int bindPort;

  /// 目标(动态代理不需要)
  final String destHost;
  final int destPort;

  String get _bindPrefix => bindAddress.isEmpty ? '' : '$bindAddress:';

  /// 传给 ssh 的转发规格
  String get spec {
    switch (type) {
      case TunnelType.local:
      case TunnelType.remote:
        return '$_bindPrefix$bindPort:$destHost:$destPort';
      case TunnelType.dynamic:
        return '$_bindPrefix$bindPort';
    }
  }

  String get typeFlag {
    switch (type) {
      case TunnelType.local:
        return '-L';
      case TunnelType.remote:
        return '-R';
      case TunnelType.dynamic:
        return '-D';
    }
  }

  String get typeLabel {
    switch (type) {
      case TunnelType.local:
        return tr('本地 -L');
      case TunnelType.remote:
        return tr('远程 -R');
      case TunnelType.dynamic:
        return 'SOCKS -D';
    }
  }

  String get summary {
    switch (type) {
      case TunnelType.local:
        return tr2('本地 {0}{1} → {2}:{3}', [_bindPrefix, bindPort, destHost, destPort]);
      case TunnelType.remote:
        return tr2('服务器 {0}{1} → {2}:{3}', [_bindPrefix, bindPort, destHost, destPort]);
      case TunnelType.dynamic:
        return tr2('SOCKS 代理 {0}{1}', [_bindPrefix, bindPort]);
    }
  }

  SshTunnel copyWith({
    TunnelType? type,
    String? bindAddress,
    int? bindPort,
    String? destHost,
    int? destPort,
  }) => SshTunnel(
    id: id,
    hostId: hostId,
    type: type ?? this.type,
    bindAddress: bindAddress ?? this.bindAddress,
    bindPort: bindPort ?? this.bindPort,
    destHost: destHost ?? this.destHost,
    destPort: destPort ?? this.destPort,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'hostId': hostId,
    'type': type.name,
    'bindAddress': bindAddress,
    'bindPort': bindPort,
    'destHost': destHost,
    'destPort': destPort,
  };

  factory SshTunnel.fromJson(Map<String, dynamic> json) => SshTunnel(
    id: json['id'] as String,
    hostId: json['hostId'] as String,
    type: TunnelType.values.firstWhere(
      (t) => t.name == json['type'],
      orElse: () => TunnelType.local,
    ),
    bindAddress: json['bindAddress'] as String? ?? '',
    bindPort: (json['bindPort'] as num?)?.toInt() ?? 0,
    destHost: json['destHost'] as String? ?? 'localhost',
    destPort: (json['destPort'] as num?)?.toInt() ?? 0,
  );
}

/// 隧道配置存储(SharedPreferences 持久化)。
class TunnelStore {
  TunnelStore._();

  static const _key = 'ssh_tunnels_v1';
  static final ValueNotifier<List<SshTunnel>> tunnels =
      ValueNotifier<List<SshTunnel>>(const []);
  static bool _loaded = false;

  static Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return;
      tunnels.value = (json.decode(raw) as List<dynamic>)
          .map((e) => SshTunnel.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {}
  }

  static List<SshTunnel> forHost(String hostId) =>
      [for (final t in tunnels.value) if (t.hostId == hostId) t];

  static Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _key,
        json.encode([for (final t in tunnels.value) t.toJson()]),
      );
    } catch (_) {}
  }

  static Future<void> upsert(SshTunnel tunnel) async {
    final list = [...tunnels.value];
    final i = list.indexWhere((t) => t.id == tunnel.id);
    if (i >= 0) {
      list[i] = tunnel;
    } else {
      list.add(tunnel);
    }
    tunnels.value = list;
    await _save();
  }

  static Future<void> remove(String id) async {
    tunnels.value = [
      for (final t in tunnels.value)
        if (t.id != id) t,
    ];
    await _save();
  }
}

/// 启停端口转发进程。复用 ControlMaster(需该主机的 SSH 会话已连,免再认证)。
class TunnelService {
  TunnelService._();

  static final Map<String, Process> _running = {};

  /// 正在运行的隧道 id 集合;UI 订阅
  static final ValueNotifier<Set<String>> runningIds =
      ValueNotifier<Set<String>>(const {});

  /// 最近一次失败原因(隧道 id → 消息),UI 可提示
  static final ValueNotifier<Map<String, String>> errors =
      ValueNotifier<Map<String, String>>(const {});

  static bool isRunning(String id) => _running.containsKey(id);

  static List<String> _args(SshHost host, SshTunnel tunnel) => [
    '-N',
    '-o', 'ExitOnForwardFailure=yes',
    '-o', 'BatchMode=yes',
    '-o', 'ControlMaster=auto',
    '-o', 'ControlPath=~/.termora/cm-%C',
    '-o', 'ControlPersist=10m',
    '-o', 'ServerAliveInterval=30',
    if (host.port != 22) ...['-p', '${host.port}'],
    if (host.keyPath.isNotEmpty) ...['-i', host.keyPath],
    tunnel.typeFlag, tunnel.spec,
    host.target,
  ];

  static Future<void> start(SshHost host, SshTunnel tunnel) async {
    if (_running.containsKey(tunnel.id)) return;
    _clearError(tunnel.id);
    final Process process;
    try {
      process = await Process.start('/usr/bin/ssh', _args(host, tunnel));
    } catch (e) {
      _setError(tunnel.id, tr2('无法启动 ssh: {0}', [e]));
      return;
    }
    _running[tunnel.id] = process;
    runningIds.value = {..._running.keys};
    final errFut = process.stderr.transform(utf8.decoder).join();
    unawaited(() async {
      final code = await process.exitCode;
      final err = (await errFut).trim();
      _running.remove(tunnel.id);
      runningIds.value = {..._running.keys};
      // 非主动 kill 的失败退出 → 记录原因
      if (code != 0) {
        _setError(
          tunnel.id,
          err.isEmpty
              ? tr2('转发退出(码 {0})。请先连接该主机的 SSH 会话(复用已认证连接)。', [code])
              : err,
        );
      }
    }());
    // 给 ssh 一点时间,若立刻因端口占用/转发失败退出,上面会记录
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }

  static void stop(String id) {
    _running.remove(id)?.kill();
    runningIds.value = {..._running.keys};
  }

  static void _setError(String id, String message) {
    errors.value = {...errors.value, id: message};
  }

  static void _clearError(String id) {
    if (!errors.value.containsKey(id)) return;
    final m = {...errors.value}..remove(id);
    errors.value = m;
  }
}
