import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:termora/features/monitor/data/platform_collector.dart';

void main() {
  test('ps 输出解析', () {
    const output = '''
    1     0 root               0.0  0.1  18512 Ss   /sbin/launchd
  102 99972 wangxi            23.6  0.3  86560 S    /Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper
''';
    final procs = parsePsOutput(output);
    expect(procs, hasLength(2));
    expect(procs[0].pid, 1);
    expect(procs[0].user, 'root');
    expect(procs[0].name, 'launchd');
    expect(procs[0].state, 'S');
    expect(procs[1].cpuPercent, closeTo(23.6, 0.01));
    expect(procs[1].name, 'Claude Helper'); // comm 含空格
    expect(procs[1].rssBytes, 86560 * 1024);
  });

  test('df -kP 输出解析(同设备去重、挂载点含空格)', () {
    const output = '''
Filesystem     1024-blocks      Used Available Capacity  Mounted on
/dev/disk3s1s1   971350180  12274664 110972932    10%    /
devfs                  258       258         0   100%    /dev
/dev/disk3s1s1   971350180  12274664 110972932    10%    /System/Volumes/Data
/dev/disk5s1       1000000    500000    500000    50%    /Volumes/My Disk
''';
    final disks = parseDfOutput(output);
    expect(disks, hasLength(2));
    expect(disks[0].mountPoint, '/');
    expect(disks[0].totalBytes, 971350180 * 1024);
    expect(disks[1].mountPoint, '/Volumes/My Disk');
    expect(disks[1].usedPercent, closeTo(50, 0.1));
  });

  test(
    '真实采样两轮:CPU/内存/网络/磁盘/进程可用',
    skip: !Platform.isMacOS && !Platform.isLinux
        ? '仅 macOS / Linux 跑真实采样'
        : false,
    () async {
      final collector = PlatformCollector.forCurrentPlatform()!;
      final first = await collector.sample();
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      final second = await collector.sample();

      // 第二轮已有差分基线,速率类指标应有值。
      expect(second.cpu, isNotNull);
      expect(second.cpu!.totalUsage, inInclusiveRange(0, 100));
      if (Platform.isMacOS) {
        // FFI 每核使用率在第二轮应可用。
        expect(second.cpu!.perCore, isNotEmpty);
        for (final core in second.cpu!.perCore) {
          expect(core, inInclusiveRange(0, 100));
        }
      }

      expect(second.memory, isNotNull);
      expect(second.memory!.totalBytes, greaterThan(0));
      expect(
        second.memory!.usedBytes,
        inInclusiveRange(1, second.memory!.totalBytes),
      );

      expect(second.network, isNotNull);
      expect(second.network!.rxRate, isNotNull);
      expect(second.network!.rxRate!, greaterThanOrEqualTo(0));

      expect(second.disks, isNotEmpty);
      expect(second.disks.first.totalBytes, greaterThan(0));

      expect(second.processes, isNotEmpty);
      expect(first.processes.any((p) => p.pid == pid), isTrue);

      if (Platform.isMacOS) {
        // Apple Silicon 的 IOAccelerator 应给出 GPU 利用率。
        expect(second.gpus, isNotEmpty);
        expect(second.gpus.first.utilization, inInclusiveRange(0, 100));
      }

      expect(second.loadAvg, isNotNull);
      expect(second.loadAvg, hasLength(3));
      expect(second.uptime, isNotNull);
      expect(second.uptime!.inSeconds, greaterThan(0));

      collector.dispose();
    },
  );
}
