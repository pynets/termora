import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:termora/features/remote/domain/sftp_entry.dart';
import 'package:termora/features/remote/domain/ssh_host.dart';
import 'package:termora/core/l10n/app_l10n.dart';

class SftpException implements Exception {
  const SftpException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 一次进行中的传输(get/put)。进程可取消;完成/失败经 [done] 暴露。
class SftpTransferHandle {
  SftpTransferHandle._(this._process);

  final Process _process;

  /// 管道式传输(sudo tar)还有另一端进程,取消时一并杀掉
  final List<Process> _alsoKill = [];
  final Completer<void> _completer = Completer<void>();
  bool _cancelled = false;

  bool get cancelled => _cancelled;

  void _alsoKillOnCancel(Process p) => _alsoKill.add(p);

  /// 正常完成时 complete;失败时以 [SftpException] complete error。
  /// 取消导致的非零退出不会报错(以 cancelled 标记区分)。
  Future<void> get done => _completer.future;

  void cancel() {
    if (_completer.isCompleted) return;
    _cancelled = true;
    _process.kill();
    for (final p in _alsoKill) {
      p.kill();
    }
  }
}

/// SFTP v1 — 直接驱动系统 `/usr/bin/sftp` 批处理模式,零依赖:
/// 每个操作起一个 sftp 进程,通过与 SSH 终端会话相同的 ControlPath 复用
/// 已认证连接(免密、免握手,毫秒级)。批处理隐含 BatchMode,不能交互输密码,
/// 所以密码登录/首次指纹确认需要先在终端开一次 SSH 会话。
class SftpService {
  SftpService._();

  static List<String> _args(SshHost host, {required List<String> tail}) => [
    '-q',
    '-o',
    'ControlMaster=auto',
    '-o',
    'ControlPath=~/.termora/cm-%C',
    '-o',
    'ControlPersist=10m',
    '-o',
    'ServerAliveInterval=30',
    if (host.port != 22) ...['-P', '${host.port}'],
    if (host.keyPath.isNotEmpty) ...['-i', host.keyPath],
    ...tail,
    host.target,
  ];

  /// 跑一批 sftp 命令,返回 stdout(批处理里命令回显行以 "sftp>" 开头)
  static Future<String> _run(SshHost host, List<String> commands) async {
    final Process process;
    try {
      process = await Process.start(
        '/usr/bin/sftp',
        _args(host, tail: ['-b', '-']),
      );
    } catch (error) {
      throw SftpException(tr2('无法启动 sftp: {0}', [error]));
    }
    process.stdin.writeln(commands.join('\n'));
    await process.stdin.close();
    final stdoutFuture = process.stdout.transform(utf8.decoder).join();
    final stderrFuture = process.stderr.transform(utf8.decoder).join();
    final exitCode = await process.exitCode;
    final out = await stdoutFuture;
    final err = await stderrFuture;
    if (exitCode != 0) {
      throw SftpException(_friendlyError(err.trim(), out.trim()));
    }
    return out;
  }

  static String _friendlyError(String stderr, String stdout) {
    final raw = stderr.isNotEmpty ? stderr : stdout;
    final message = raw.isEmpty ? tr('sftp 操作失败') : raw;
    const needsSession = [
      'Permission denied',
      'Host key verification failed',
      'Connection closed',
      'Connection refused',
      'Connection timed out',
      'Couldn\'t read packet',
    ];
    if (needsSession.any(message.contains)) {
      return '$message\n${tr('提示:密码登录或首次连接请先在左侧打开该主机的 SSH 会话,SFTP 会自动复用已认证连接。')}';
    }
    return message;
  }

  /// sftp 批处理路径引号:双引号包裹,反斜杠转义
  static String _quote(String path) =>
      '"${path.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

  /// 远端家目录(绝对路径),作为浏览起点
  static Future<String> homeDirectory(SshHost host) async {
    final out = await _run(host, ['pwd']);
    final match = RegExp(r'Remote working directory:\s*(.+)').firstMatch(out);
    final home = match?.group(1)?.trim();
    return (home == null || home.isEmpty) ? '/' : home;
  }

  /// 列目录 — 解析 OpenSSH sftp `ls -la` 的长格式输出
  static Future<List<SftpEntry>> list(SshHost host, String path) async {
    final out = await _run(host, ['ls -la ${_quote(path)}']);
    final entries = <SftpEntry>[];
    for (final line in const LineSplitter().convert(out)) {
      final entry = _parseLsLine(line);
      if (entry != null) entries.add(entry);
    }
    entries.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  /// 长格式行:perms links owner group size month day time/year name...
  static SftpEntry? _parseLsLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('sftp>')) return null;
    final fields = trimmed.split(RegExp(r'\s+'));
    if (fields.length < 9) return null;
    final perms = fields[0];
    if (perms.length < 10 || !'-dlbcps'.contains(perms[0])) return null;
    final size = int.tryParse(fields[4]) ?? 0;
    final modified = fields.sublist(5, 8).join(' ');
    var name = fields.sublist(8).join(' ');
    final isLink = perms.startsWith('l');
    if (isLink) {
      final arrow = name.indexOf(' -> ');
      if (arrow > 0) name = name.substring(0, arrow);
    }
    // 部分 OpenSSH 版本对 `ls -la <dir>` 回显的是全路径(/root/.bashrc),
    // 统一取 basename;文件名里不可能有 '/',所以安全
    final slash = name.lastIndexOf('/');
    if (slash >= 0) name = name.substring(slash + 1);
    if (name.isEmpty || name == '.' || name == '..') return null;
    return SftpEntry(
      name: name,
      isDir: perms.startsWith('d'),
      isLink: isLink,
      size: size,
      modified: modified,
    );
  }

  /// 起一个可取消的传输进程(批处理),立即返回句柄
  static Future<SftpTransferHandle> _startTransfer(
    SshHost host,
    List<String> commands,
  ) async {
    final Process process;
    try {
      process = await Process.start(
        '/usr/bin/sftp',
        _args(host, tail: ['-b', '-']),
      );
    } catch (error) {
      throw SftpException(tr2('无法启动 sftp: {0}', [error]));
    }
    final handle = SftpTransferHandle._(process);
    process.stdin.writeln(commands.join('\n'));
    unawaited(process.stdin.close());
    final stdoutFuture = process.stdout.transform(utf8.decoder).join();
    final stderrFuture = process.stderr.transform(utf8.decoder).join();
    unawaited(() async {
      final exitCode = await process.exitCode;
      final out = await stdoutFuture;
      final err = await stderrFuture;
      if (handle._completer.isCompleted) return;
      if (exitCode != 0 && !handle._cancelled) {
        handle._completer.completeError(
          SftpException(_friendlyError(err.trim(), out.trim())),
        );
      } else {
        handle._completer.complete();
      }
    }());
    return handle;
  }

  /// 下载文件或目录(recursive)。local 为目录时 sftp 自动落到 local/<名字>。
  static Future<SftpTransferHandle> startDownload(
    SshHost host,
    String remotePath,
    String localPath, {
    bool recursive = false,
  }) => _startTransfer(host, [
    'get ${recursive ? '-r ' : ''}${_quote(remotePath)} ${_quote(localPath)}',
  ]);

  /// 上传文件到远端目录(保留原文件名)
  static Future<SftpTransferHandle> startUpload(
    SshHost host,
    String localPath,
    String remoteDir,
  ) => _startTransfer(host, ['put ${_quote(localPath)} ${_quote(remoteDir)}']);

  /// 递归上传目录到远端目录(落到 remoteDir/<目录名>)。
  /// 先 -mkdir(前缀 - 表示忽略已存在报错)兼容不自建顶层目录的旧服务端。
  static Future<SftpTransferHandle> startUploadDir(
    SshHost host,
    String localDir,
    String remoteDir,
  ) {
    final baseName = localDir.split('/').where((s) => s.isNotEmpty).last;
    final target = remoteDir == '/' ? '/$baseName' : '$remoteDir/$baseName';
    return _startTransfer(host, [
      '-mkdir ${_quote(target)}',
      'put -r ${_quote(localDir)} ${_quote(remoteDir)}',
    ]);
  }

  /// 单个远端文件的当前大小(上传进度轮询用);拿不到返回 null
  static Future<int?> fileSize(SshHost host, String remotePath) async {
    try {
      final out = await _run(host, ['ls -la ${_quote(remotePath)}']);
      for (final line in const LineSplitter().convert(out)) {
        final entry = _parseLsLine(line);
        if (entry != null) return entry.size;
      }
    } on SftpException {
      return null;
    }
    return null;
  }

  /// 远端目录累计大小(字节),目录上传进度轮询用;拿不到返回 null。
  /// sftp 没有 du/递归 ls,改走 ssh 复用 ControlMaster 跑 `du -sk`(KB→字节)。
  static Future<int?> dirSize(SshHost host, String remotePath) async {
    try {
      final out = await _sshExec(
        host,
        'du -sk ${_quote(remotePath)} 2>/dev/null',
      );
      final first = const LineSplitter().convert(out).firstOrNull;
      if (first == null || first.isEmpty) return null;
      final kb = int.tryParse(first.split(RegExp(r'\s+')).first);
      return kb == null ? null : kb * 1024;
    } catch (_) {
      return null;
    }
  }

  /// 非提权 ssh 单命令执行(复用 ControlMaster),返回 stdout 文本。
  /// 只用于只读探测(du/stat 之类),失败由调用方兜底。
  static Future<String> _sshExec(SshHost host, String command) async {
    final process = await Process.start('/usr/bin/ssh', [
      '-q',
      '-o',
      'ControlMaster=auto',
      '-o',
      'ControlPath=~/.termora/cm-%C',
      '-o',
      'ControlPersist=10m',
      '-o',
      'ServerAliveInterval=30',
      if (host.port != 22) ...['-p', '${host.port}'],
      if (host.keyPath.isNotEmpty) ...['-i', host.keyPath],
      host.target,
      command,
    ]);
    unawaited(process.stdin.close());
    final out = await process.stdout.transform(utf8.decoder).join();
    unawaited(process.stderr.drain<void>());
    await process.exitCode;
    return out;
  }

  static Future<void> remove(SshHost host, String remotePath) =>
      _run(host, ['rm ${_quote(remotePath)}']);

  /// 只删空目录(sftp rmdir 语义;v1 不做递归删除,防误伤)
  static Future<void> removeDir(SshHost host, String remotePath) =>
      _run(host, ['rmdir ${_quote(remotePath)}']);

  static Future<void> makeDir(SshHost host, String remotePath) =>
      _run(host, ['mkdir ${_quote(remotePath)}']);

  static Future<void> rename(SshHost host, String from, String to) =>
      _run(host, ['rename ${_quote(from)} ${_quote(to)}']);
}

/// 提权文件访问 — SFTP 走的是登录用户,进不了别的用户的私有目录(权限拒绝)。
/// 这里改用 `ssh 'sudo -S ...'`(密码经 stdin 喂给 sudo,不进命令行参数),
/// 以 root 身份跑 ls/cat/tee/mv/rm/mkdir,复用 ControlMaster 免再握手。
/// 需要账号能 sudo(会提示输密码;不要求 NOPASSWD)。
class SudoFileService {
  SudoFileService._();

  static List<String> _sshArgs(SshHost host, String remoteCommand) => [
    '-q',
    '-o',
    'ControlMaster=auto',
    '-o',
    'ControlPath=~/.termora/cm-%C',
    '-o',
    'ControlPersist=10m',
    '-o',
    'ServerAliveInterval=30',
    if (host.port != 22) ...['-p', '${host.port}'],
    if (host.keyPath.isNotEmpty) ...['-i', host.keyPath],
    host.target,
    remoteCommand,
  ];

  /// 远端(登录 shell 解析)单引号:防止路径里的特殊字符
  static String _sq(String s) => "'${s.replaceAll("'", r"'\''")}'";

  /// sudo -S:从 stdin 读密码(首行),-p '' 关掉提示,-k 先失效缓存凭证
  /// 强制每次都真的读一行密码——否则(sudo 缓存了凭证时)那行密码不会被
  /// 消费,会漏进 tar/tee/cat 的输入污染数据流。
  static String _sudo(String cmd) => "sudo -S -k -p '' $cmd";

  static String _sudoError(String stderr) {
    final s = stderr.trim();
    if (s.contains('incorrect password') ||
        s.contains('Sorry, try again') ||
        s.contains('one incorrect password')) {
      return tr('sudo 密码不正确');
    }
    if (s.contains('you must have a tty') ||
        s.contains('a terminal is required')) {
      return tr('该主机 sudo 需要 tty(requiretty),无法用此方式提权');
    }
    if (s.contains('is not in the sudoers') || s.contains('not allowed')) {
      return tr('当前用户没有 sudo 权限');
    }
    return s.isEmpty ? tr('sudo 操作失败') : s;
  }

  /// 跑一条提权命令,返回 stdout(文本);失败抛 [SftpException]
  static Future<String> _execText(
    SshHost host,
    String password,
    String remoteCommand,
  ) async {
    final Process process;
    try {
      process = await Process.start(
        '/usr/bin/ssh',
        _sshArgs(host, _sudo(remoteCommand)),
      );
    } catch (error) {
      throw SftpException(tr2('无法启动 ssh: {0}', [error]));
    }
    process.stdin.add(utf8.encode('$password\n'));
    unawaited(process.stdin.close());
    final outFut = process.stdout.transform(utf8.decoder).join();
    final errFut = process.stderr.transform(utf8.decoder).join();
    final code = await process.exitCode;
    final out = await outFut;
    final err = await errFut;
    if (code != 0) throw SftpException(_sudoError(err.isEmpty ? out : err));
    return out;
  }

  /// 校验密码 / sudo 可用性(以 root 身份返回用户名)
  static Future<void> verify(SshHost host, String password) async {
    final who = (await _execText(host, password, 'id -un')).trim();
    if (who.isEmpty) throw SftpException(tr('sudo 提权失败'));
  }

  static Future<List<SftpEntry>> list(
    SshHost host,
    String password,
    String path,
  ) async {
    // 与 sftp 的 ls -la 同格式(GNU ls 的 total/./.. 与 SELinux 点号都能被解析)
    final out = await _execText(host, password, 'ls -la -- ${_sq(path)}');
    final entries = <SftpEntry>[];
    for (final line in const LineSplitter().convert(out)) {
      final entry = SftpService._parseLsLine(line);
      if (entry != null) entries.add(entry);
    }
    entries.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  static Future<int?> fileSize(
    SshHost host,
    String password,
    String remotePath,
  ) async {
    try {
      final out = await _execText(
        host,
        password,
        'stat -c %s -- ${_sq(remotePath)}',
      );
      return int.tryParse(out.trim());
    } on SftpException {
      return null;
    }
  }

  static Future<void> remove(
    SshHost host,
    String password,
    String remotePath,
  ) => _execText(host, password, 'rm -f -- ${_sq(remotePath)}').then((_) {});

  static Future<void> removeDir(
    SshHost host,
    String password,
    String remotePath,
  ) => _execText(host, password, 'rmdir -- ${_sq(remotePath)}').then((_) {});

  static Future<void> makeDir(
    SshHost host,
    String password,
    String remotePath,
  ) => _execText(host, password, 'mkdir -- ${_sq(remotePath)}').then((_) {});

  static Future<void> rename(
    SshHost host,
    String password,
    String from,
    String to,
  ) => _execText(host, password, 'mv -- ${_sq(from)} ${_sq(to)}').then((_) {});

  /// 下载单个文件:`sudo cat` 的 stdout 写入本地文件
  static Future<SftpTransferHandle> startDownloadFile(
    SshHost host,
    String password,
    String remotePath,
    String localPath,
  ) async {
    final Process process;
    try {
      process = await Process.start(
        '/usr/bin/ssh',
        _sshArgs(host, _sudo('cat -- ${_sq(remotePath)}')),
      );
    } catch (error) {
      throw SftpException(tr2('无法启动 ssh: {0}', [error]));
    }
    final handle = SftpTransferHandle._(process);
    process.stdin.add(utf8.encode('$password\n'));
    unawaited(process.stdin.close());
    final sink = File(localPath).openWrite();
    final errFut = process.stderr.transform(utf8.decoder).join();
    process.stdout.listen(
      sink.add,
      onError: (Object _) {},
      onDone: () async {
        await sink.close();
        final code = await process.exitCode;
        final err = await errFut;
        if (handle._completer.isCompleted) return;
        if (code != 0 && !handle._cancelled) {
          try {
            await File(localPath).delete();
          } catch (_) {}
          handle._completer.completeError(SftpException(_sudoError(err)));
        } else {
          handle._completer.complete();
        }
      },
    );
    return handle;
  }

  static String _basename(String p) {
    final t = p.replaceAll(RegExp(r'/+$'), '');
    final i = t.lastIndexOf('/');
    return i < 0 ? t : t.substring(i + 1);
  }

  static String _dirname(String p) {
    final t = p.replaceAll(RegExp(r'/+$'), '');
    final i = t.lastIndexOf('/');
    if (i < 0) return '.';
    return i == 0 ? '/' : t.substring(0, i);
  }

  /// 下载目录(递归):`sudo tar -C 父 -cf - 名` 的流经本地 tar 解到 localTargetDir。
  /// 落地为 localTargetDir/<名>,和 sftp get -r 语义一致。
  static Future<SftpTransferHandle> startDownloadDir(
    SshHost host,
    String password,
    String remotePath,
    String localTargetDir,
  ) async {
    final parent = _dirname(remotePath);
    final name = _basename(remotePath);
    final Process ssh;
    try {
      ssh = await Process.start(
        '/usr/bin/ssh',
        _sshArgs(host, _sudo('tar -C ${_sq(parent)} -cf - -- ${_sq(name)}')),
      );
    } catch (error) {
      throw SftpException(tr2('无法启动 ssh: {0}', [error]));
    }
    final Process localTar;
    try {
      localTar = await Process.start('/usr/bin/tar', [
        '-C',
        localTargetDir,
        '-xf',
        '-',
      ]);
    } catch (error) {
      ssh.kill();
      throw SftpException(tr2('无法启动本地 tar: {0}', [error]));
    }
    final handle = SftpTransferHandle._(ssh);
    handle._alsoKillOnCancel(localTar);
    ssh.stdin.add(utf8.encode('$password\n'));
    unawaited(ssh.stdin.close());
    final errFut = ssh.stderr.transform(utf8.decoder).join();
    unawaited(localTar.stderr.drain<void>());
    ssh.stdout.listen(
      localTar.stdin.add,
      onError: (Object _) {},
      onDone: () => unawaited(localTar.stdin.close()),
    );
    unawaited(() async {
      final sshCode = await ssh.exitCode;
      final tarCode = await localTar.exitCode;
      final err = await errFut;
      if (handle._completer.isCompleted) return;
      if ((sshCode != 0 || tarCode != 0) && !handle._cancelled) {
        handle._completer.completeError(SftpException(_sudoError(err)));
      } else {
        handle._completer.complete();
      }
    }());
    return handle;
  }

  /// 上传目录(递归):本地 `tar -cf -` 流经 stdin 给远端 `sudo tar -xf -`。
  /// 落地为 remoteDir/<名>。
  static Future<SftpTransferHandle> startUploadDir(
    SshHost host,
    String password,
    String localPath,
    String remoteDir,
  ) async {
    final parent = File(localPath).parent.path;
    final name = _basename(localPath);
    final Process localTar;
    try {
      localTar = await Process.start('/usr/bin/tar', [
        '-C',
        parent,
        '-cf',
        '-',
        '--',
        name,
      ]);
    } catch (error) {
      throw SftpException(tr2('无法启动本地 tar: {0}', [error]));
    }
    final Process ssh;
    try {
      ssh = await Process.start(
        '/usr/bin/ssh',
        _sshArgs(host, _sudo('tar -C ${_sq(remoteDir)} -xf -')),
      );
    } catch (error) {
      localTar.kill();
      throw SftpException(tr2('无法启动 ssh: {0}', [error]));
    }
    final handle = SftpTransferHandle._(ssh);
    handle._alsoKillOnCancel(localTar);
    final errFut = ssh.stderr.transform(utf8.decoder).join();
    unawaited(localTar.stderr.drain<void>());
    ssh.stdin.add(utf8.encode('$password\n'));
    localTar.stdout.listen(
      ssh.stdin.add,
      onError: (Object _) {},
      onDone: () => unawaited(ssh.stdin.close()),
    );
    unawaited(() async {
      final tarCode = await localTar.exitCode;
      final sshCode = await ssh.exitCode;
      final err = await errFut;
      if (handle._completer.isCompleted) return;
      if ((sshCode != 0 || tarCode != 0) && !handle._cancelled) {
        handle._completer.completeError(SftpException(_sudoError(err)));
      } else {
        handle._completer.complete();
      }
    }());
    return handle;
  }

  /// 上传单个文件:本地文件流经 stdin,`sudo tee` 写入远端(丢弃 stdout)
  static Future<SftpTransferHandle> startUploadFile(
    SshHost host,
    String password,
    String localPath,
    String remotePath,
  ) async {
    final Process process;
    try {
      process = await Process.start(
        '/usr/bin/ssh',
        _sshArgs(host, _sudo('tee -- ${_sq(remotePath)} >/dev/null')),
      );
    } catch (error) {
      throw SftpException(tr2('无法启动 ssh: {0}', [error]));
    }
    final handle = SftpTransferHandle._(process);
    final errFut = process.stderr.transform(utf8.decoder).join();
    // 密码首行 + 文件内容;先写密码,再把本地文件灌进去
    process.stdin.add(utf8.encode('$password\n'));
    () async {
      try {
        await process.stdin.addStream(File(localPath).openRead());
      } catch (_) {}
      await process.stdin.close();
    }();
    unawaited(() async {
      final code = await process.exitCode;
      final err = await errFut;
      if (handle._completer.isCompleted) return;
      if (code != 0 && !handle._cancelled) {
        handle._completer.completeError(SftpException(_sudoError(err)));
      } else {
        handle._completer.complete();
      }
    }());
    return handle;
  }
}

/// 用 root 密码 `su` 提权访问 — 适用于登录用户不是 sudoer、且服务器禁了 root
/// SSH 的场景。`su` 只从 tty 读密码,所以用 `ssh -tt` 强制分配 pty,检测到
/// 密码提示后把 root 密码送进去;二进制传输经 pty 会被换行转换弄坏,所以
/// 下载走 base64 编解码。内层命令整体 base64 后再 `eval`,绕开多层引号。
class SuFileService {
  SuFileService._();

  static const String _marker = '__TERMORA_OK__';

  static List<String> _sshTtyArgs(SshHost host, String remoteCommand) => [
    '-tt',
    '-o',
    'LogLevel=QUIET',
    '-o',
    'ControlMaster=auto',
    '-o',
    'ControlPath=~/.termora/cm-%C',
    '-o',
    'ControlPersist=10m',
    '-o',
    'ServerAliveInterval=30',
    if (host.port != 22) ...['-p', '${host.port}'],
    if (host.keyPath.isNotEmpty) ...['-i', host.keyPath],
    host.target,
    remoteCommand,
  ];

  static String _sq(String s) => "'${s.replaceAll("'", r"'\''")}'";

  static String _suError(String head) {
    final s = head;
    if (s.contains('Authentication failure') ||
        s.contains('incorrect password') ||
        s.contains('Sorry')) {
      return tr('root 密码不正确');
    }
    if (s.contains('su: ') && s.contains('not permitted')) {
      return tr('su 被拒(可能 root 账号被锁或受限)');
    }
    return s.trim().isEmpty ? tr('su 提权失败') : s.trim();
  }

  static int _indexOf(List<int> hay, List<int> needle, [int from = 0]) {
    outer:
    for (var i = from; i + needle.length <= hay.length; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (hay[i + j] != needle[j]) continue outer;
      }
      return i;
    }
    return -1;
  }

  /// 起一个 su 提权进程,返回进程 + 「marker 之后的原始字节」的 future。
  /// [innerCmd] 是要以 root 跑的命令(路径用 _sq 引;stderr 建议自行丢弃)。
  static Future<({Process process, Future<List<int>> result})> _suStart(
    SshHost host,
    String rootPassword,
    String innerCmd,
  ) async {
    // 内层:先打 marker,再跑命令;整体 base64 → eval,规避引号
    final inner = "printf '$_marker\\n'; $innerCmd";
    final b64 = base64.encode(utf8.encode(inner));
    final remote = 'su -c ${_sq('eval "\$(printf %s $b64 | base64 -d)"')}';

    final Process process;
    try {
      process = await Process.start('/usr/bin/ssh', _sshTtyArgs(host, remote));
    } catch (error) {
      throw SftpException(tr2('无法启动 ssh: {0}', [error]));
    }

    final completer = Completer<List<int>>();
    final after = <int>[];
    final head = <int>[];
    final markerBytes = utf8.encode(_marker);
    var sentPassword = false;
    var markerFound = false;

    unawaited(process.stderr.drain<void>());
    process.stdout.listen(
      (chunk) {
        if (markerFound) {
          after.addAll(chunk);
          return;
        }
        head.addAll(chunk);
        final headStr = utf8.decode(head, allowMalformed: true);
        if (!sentPassword && RegExp('[Pp]assword|密码').hasMatch(headStr)) {
          sentPassword = true;
          process.stdin.add(utf8.encode('$rootPassword\n'));
        }
        final idx = _indexOf(head, markerBytes);
        if (idx >= 0) {
          markerFound = true;
          var s = idx + markerBytes.length;
          while (s < head.length && (head[s] == 0x0d || head[s] == 0x0a)) {
            s++;
          }
          after.addAll(head.sublist(s));
          head.clear();
        }
      },
      onDone: () {
        if (completer.isCompleted) return;
        if (markerFound) {
          completer.complete(after);
        } else {
          completer.completeError(
            SftpException(_suError(utf8.decode(head, allowMalformed: true))),
          );
        }
      },
      onError: (Object e) {
        if (!completer.isCompleted)
          completer.completeError(SftpException('$e'));
      },
    );

    return (process: process, result: completer.future);
  }

  /// 跑一条 su 命令,返回 marker 之后的文本(去掉 pty 的 \r)
  static Future<String> _suText(
    SshHost host,
    String rootPassword,
    String innerCmd,
  ) async {
    final started = await _suStart(host, rootPassword, innerCmd);
    final bytes = await started.result;
    return utf8.decode(bytes, allowMalformed: true).replaceAll('\r', '');
  }

  static Future<void> verify(SshHost host, String rootPassword) async {
    final who = (await _suText(
      host,
      rootPassword,
      'id -un 2>/dev/null',
    )).trim();
    if (!who.contains('root')) {
      throw SftpException(tr('su 提权失败(未取得 root)'));
    }
  }

  static Future<List<SftpEntry>> list(
    SshHost host,
    String rootPassword,
    String path,
  ) async {
    final out = await _suText(
      host,
      rootPassword,
      'ls -la -- ${_sq(path)} 2>/dev/null',
    );
    final entries = <SftpEntry>[];
    for (final line in const LineSplitter().convert(out)) {
      final entry = SftpService._parseLsLine(line);
      if (entry != null) entries.add(entry);
    }
    entries.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  static Future<int?> fileSize(
    SshHost host,
    String rootPassword,
    String remotePath,
  ) async {
    final out = await _suText(
      host,
      rootPassword,
      'stat -c %s -- ${_sq(remotePath)} 2>/dev/null',
    );
    return int.tryParse(out.trim());
  }

  static Future<void> rename(
    SshHost host,
    String rootPassword,
    String from,
    String to,
  ) => _suText(
    host,
    rootPassword,
    'mv -- ${_sq(from)} ${_sq(to)} 2>&1',
  ).then((_) {});

  static Future<void> remove(
    SshHost host,
    String rootPassword,
    String path,
    bool isDir,
  ) => _suText(
    host,
    rootPassword,
    '${isDir ? 'rmdir' : 'rm -f'} -- ${_sq(path)} 2>&1',
  ).then((_) {});

  static Future<void> makeDir(SshHost host, String rootPassword, String path) =>
      _suText(host, rootPassword, 'mkdir -- ${_sq(path)} 2>&1').then((_) {});

  /// 下载单个文件:root `base64 <file>` → 本地解码写盘
  static Future<SftpTransferHandle> startDownloadFile(
    SshHost host,
    String rootPassword,
    String remotePath,
    String localPath,
  ) async {
    final started = await _suStart(
      host,
      rootPassword,
      'base64 -- ${_sq(remotePath)} 2>/dev/null',
    );
    final handle = SftpTransferHandle._(started.process);
    unawaited(() async {
      try {
        final bytes = await started.result;
        if (handle._cancelled) return;
        final text = utf8
            .decode(bytes, allowMalformed: true)
            .replaceAll(RegExp(r'\s'), '');
        final data = base64.decode(text);
        await File(localPath).writeAsBytes(data, flush: true);
        if (!handle._completer.isCompleted) handle._completer.complete();
      } catch (e) {
        try {
          await File(localPath).delete();
        } catch (_) {}
        if (!handle._completer.isCompleted) {
          handle._completer.completeError(SftpException('$e'));
        }
      }
    }());
    return handle;
  }

  /// 下载目录:root `tar czf - <dir> | base64` → 本地解码 → tar 解到目标目录
  static Future<SftpTransferHandle> startDownloadDir(
    SshHost host,
    String rootPassword,
    String remotePath,
    String localTargetDir,
  ) async {
    final parent = _dirnameOf(remotePath);
    final name = _basenameOf(remotePath);
    final started = await _suStart(
      host,
      rootPassword,
      'tar czf - -C ${_sq(parent)} -- ${_sq(name)} 2>/dev/null | base64',
    );
    final handle = SftpTransferHandle._(started.process);
    unawaited(() async {
      try {
        final bytes = await started.result;
        if (handle._cancelled) return;
        final text = utf8
            .decode(bytes, allowMalformed: true)
            .replaceAll(RegExp(r'\s'), '');
        final data = base64.decode(text);
        final tar = await Process.start('/usr/bin/tar', [
          '-C',
          localTargetDir,
          '-xzf',
          '-',
        ]);
        tar.stdin.add(data);
        await tar.stdin.close();
        final code = await tar.exitCode;
        if (code != 0 && !handle._cancelled) {
          throw SftpException(tr('本地解包失败'));
        }
        if (!handle._completer.isCompleted) handle._completer.complete();
      } catch (e) {
        if (!handle._completer.isCompleted) {
          handle._completer.completeError(SftpException('$e'));
        }
      }
    }());
    return handle;
  }

  static String _basenameOf(String p) {
    final t = p.replaceAll(RegExp(r'/+$'), '');
    final i = t.lastIndexOf('/');
    return i < 0 ? t : t.substring(i + 1);
  }

  static String _dirnameOf(String p) {
    final t = p.replaceAll(RegExp(r'/+$'), '');
    final i = t.lastIndexOf('/');
    if (i < 0) return '.';
    return i == 0 ? '/' : t.substring(0, i);
  }
}
