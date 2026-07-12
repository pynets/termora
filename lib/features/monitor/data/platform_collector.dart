import 'dart:io';

import 'package:termora/features/monitor/data/linux_collector.dart';
import 'package:termora/features/monitor/data/macos_collector.dart';
import 'package:termora/features/monitor/data/windows_collector.dart';
import 'package:termora/features/monitor/domain/monitor_models.dart';

/// 平台采集器 —— 每次 [sample] 返回一份完整快照。
/// 速率类指标(网络/磁盘 I/O)由采集器内部保存上次累计值差分得出。
abstract class PlatformCollector {
  /// 按当前平台挑实现;不支持的平台返回 null(页面显示不支持提示)。
  static PlatformCollector? forCurrentPlatform() {
    if (Platform.isMacOS) return MacosCollector();
    if (Platform.isLinux) return LinuxCollector();
    if (Platform.isWindows) return WindowsCollector();
    return null;
  }

  Future<MonitorSnapshot> sample();

  /// 结束进程;[force] 为强制(SIGKILL / taskkill /F)。
  Future<bool> killProcess(int pid, {bool force = false}) async {
    try {
      final result = Platform.isWindows
          ? await Process.run('taskkill', [
              if (force) '/F',
              '/PID',
              '$pid',
            ])
          : await Process.run('kill', [force ? '-KILL' : '-TERM', '$pid']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// 向进程发送任意信号(如 HUP/INT/STOP/CONT);Windows 不支持。
  Future<bool> sendSignal(int pid, String signal) async {
    if (Platform.isWindows) return false;
    try {
      final result = await Process.run('kill', ['-$signal', '$pid']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  void dispose() {}
}

/// 运行命令拿 stdout;失败返回 null,采集降级不抛错。
Future<String?> runForStdout(
  String executable,
  List<String> args, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  try {
    final result = await Process.run(
      executable,
      args,
    ).timeout(timeout, onTimeout: () => ProcessResult(0, -1, '', 'timeout'));
    if (result.exitCode != 0) return null;
    return result.stdout as String;
  } catch (_) {
    return null;
  }
}

/// 解析 `ps axo pid=,ppid=,user=,pcpu=,pmem=,rss=,state=,comm=` 输出
/// (macOS 与 Linux 通用;comm 在最后,允许含空格)。
List<ProcInfo> parsePsOutput(String output) {
  final procs = <ProcInfo>[];
  for (final line in output.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    // 前 7 个字段定长切割,剩余整体是命令路径。
    final parts = trimmed.split(RegExp(r'\s+'));
    if (parts.length < 8) continue;
    final pid = int.tryParse(parts[0]);
    final ppid = int.tryParse(parts[1]);
    if (pid == null || ppid == null) continue;
    final cpu = double.tryParse(parts[3]) ?? 0;
    final mem = double.tryParse(parts[4]) ?? 0;
    final rssKb = int.tryParse(parts[5]) ?? 0;
    final state = parts[6];
    final command = parts.sublist(7).join(' ');
    final name = command.split('/').last;
    procs.add(
      ProcInfo(
        pid: pid,
        ppid: ppid,
        user: parts[2],
        name: name.isEmpty ? command : name,
        command: command,
        cpuPercent: cpu,
        memPercent: mem,
        rssBytes: rssKb * 1024,
        state: state.isEmpty ? '' : state[0],
      ),
    );
  }
  return procs;
}

/// 解析 `df -kP`(POSIX 格式)输出;只保留 [devicePrefix] 打头的行,
/// 同一设备只保留第一条(APFS 一卷多挂载去重)。
List<DiskInfo> parseDfOutput(String output, {String devicePrefix = '/dev/'}) {
  final disks = <DiskInfo>[];
  final seen = <String>{};
  final lines = output.split('\n');
  for (var i = 1; i < lines.length; i++) {
    final line = lines[i].trim();
    if (!line.startsWith(devicePrefix)) continue;
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length < 6) continue;
    final device = parts[0];
    if (!seen.add(device)) continue;
    final totalKb = int.tryParse(parts[1]) ?? 0;
    final usedKb = int.tryParse(parts[2]) ?? 0;
    if (totalKb <= 0) continue;
    // 挂载点可能含空格:第 6 列起整体拼回。
    final mount = parts.sublist(5).join(' ');
    disks.add(
      DiskInfo(
        device: device,
        mountPoint: mount,
        totalBytes: totalKb * 1024,
        usedBytes: usedKb * 1024,
      ),
    );
  }
  return disks;
}
