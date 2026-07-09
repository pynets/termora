/// 一条已保存的 SSH 主机配置(WindTerm 式会话管理器的最小字段集)
class SshHost {
  const SshHost({
    required this.id,
    required this.name,
    this.host = '',
    this.port = 22,
    this.user = '',
    this.keyPath = '',
    this.extraArgs = '',
    this.group = '',
  });

  final String id;
  final String name;
  final String host;
  final int port;
  final String user;

  /// 所属分组(会话管理器文件夹);空 = 未分组
  final String group;

  /// 私钥路径(空则走默认 ~/.ssh 或密码交互,由系统 OpenSSH 处理)
  final String keyPath;

  /// 追加到 ssh 命令的原样参数(如 -J jump@bastion)
  final String extraArgs;

  /// user@host 形式的连接目标(user 为空时只有 host)
  String get target => user.isEmpty ? host : '$user@$host';

  /// 组装交给终端会话运行的 ssh 命令。
  /// ControlMaster 让后续 SFTP/新会话复用这条已认证连接(socket 在 ~/.termora);
  /// ssh 自己会展开 ControlPath 里的 ~,不依赖 shell 展开。
  String sshCommand() {
    final parts = <String>[
      'ssh',
      '-o', 'ServerAliveInterval=30',
      '-o', 'ControlMaster=auto',
      '-o', 'ControlPath=~/.termora/cm-%C',
      '-o', 'ControlPersist=10m',
      if (port != 22) ...['-p', '$port'],
      if (keyPath.isNotEmpty) ...['-i', _quote(keyPath)],
      if (extraArgs.trim().isNotEmpty) extraArgs.trim(),
      _quote(target),
    ];
    return parts.join(' ');
  }

  static String _quote(String value) {
    if (value.isEmpty) return value;
    // 无特殊字符时保持可读,否则单引号包裹
    if (RegExp(r"^[A-Za-z0-9@._\-/~:]+$").hasMatch(value)) return value;
    return "'${value.replaceAll("'", "'\"'\"'")}'";
  }

  SshHost copyWith({
    String? name,
    String? host,
    int? port,
    String? user,
    String? keyPath,
    String? extraArgs,
    String? group,
  }) {
    return SshHost(
      id: id,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      user: user ?? this.user,
      keyPath: keyPath ?? this.keyPath,
      extraArgs: extraArgs ?? this.extraArgs,
      group: group ?? this.group,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'host': host,
    'port': port,
    'user': user,
    'keyPath': keyPath,
    'extraArgs': extraArgs,
    'group': group,
  };

  factory SshHost.fromJson(Map<String, dynamic> json) => SshHost(
    id: json['id'] as String,
    name: json['name'] as String? ?? '未命名主机',
    host: json['host'] as String? ?? '',
    port: (json['port'] as num?)?.toInt() ?? 22,
    user: json['user'] as String? ?? '',
    keyPath: json['keyPath'] as String? ?? '',
    extraArgs: json['extraArgs'] as String? ?? '',
    group: json['group'] as String? ?? '',
  );
}
