import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:termora/features/monitor/controller/monitor_providers.dart';
import 'package:termora/features/monitor/domain/monitor_models.dart';
import 'package:termora/features/monitor/view/monitor_page.dart';

/// 不真采样的桩控制器:预填两轮快照,忽略可见性上报。
class _StubMonitorController extends MonitorController {
  @override
  MonitorState build() {
    return MonitorState(history: [_snapshot(0), _snapshot(1)]);
  }

  @override
  void setPageVisible(bool visible) {}

  static MonitorSnapshot _snapshot(int i) {
    return MonitorSnapshot(
      tMillis: 1000000 + i * 2000,
      cpu: CpuSnapshot(
        totalUsage: 20 + i * 10,
        perCore: [10.0 + i, 30.0 + i, 50.0 + i, 70.0 + i],
      ),
      memory: MemorySnapshot(
        totalBytes: 16 * 1024 * 1024 * 1024,
        usedBytes: (8 + i) * 1024 * 1024 * 1024,
        swapTotalBytes: 4 * 1024 * 1024 * 1024,
        swapUsedBytes: 1024 * 1024 * 1024,
      ),
      network: NetworkSnapshot(
        rxTotalBytes: 1000000 * (i + 1),
        txTotalBytes: 500000 * (i + 1),
        rxRate: i == 0 ? null : 1234567,
        txRate: i == 0 ? null : 89012,
      ),
      disks: const [
        DiskInfo(
          device: '/dev/disk3s1s1',
          mountPoint: '/',
          totalBytes: 994662584320,
          usedBytes: 512000000000,
        ),
        DiskInfo(
          device: '/dev/disk5s1',
          mountPoint: '/Volumes/Backup',
          totalBytes: 2000000000000,
          usedBytes: 1900000000000,
          readRate: 1024,
          writeRate: 2048,
        ),
      ],
      diskReadRate: 3072,
      diskWriteRate: 4096,
      gpus: [
        GpuInfo(
          label: 'Apple M4',
          utilization: 40.0 + i,
          memUsedBytes: 3 * 1024 * 1024 * 1024,
        ),
      ],
      temps: const [
        TempSensor(label: '电池', celsius: 30.8),
        TempSensor(label: 'coretemp Core 0', celsius: 85.2),
      ],
      battery: const BatteryInfo(
        percent: 84,
        state: BatteryState.discharging,
        timeRemaining: Duration(hours: 6, minutes: 18),
        cycleCount: 112,
        healthPercent: 86.1,
      ),
      processes: const [
        ProcInfo(
          pid: 1,
          ppid: 0,
          user: 'root',
          name: 'launchd',
          command: '/sbin/launchd',
          cpuPercent: 0.1,
          memPercent: 0.1,
          rssBytes: 18512 * 1024,
          state: 'S',
        ),
        ProcInfo(
          pid: 2333,
          ppid: 1,
          user: 'wangxi',
          name: 'termora',
          command: '/Applications/termora.app/Contents/MacOS/termora',
          cpuPercent: 42.5,
          memPercent: 2.3,
          rssBytes: 380 * 1024 * 1024,
          state: 'R',
          readRate: 1024,
          writeRate: 2048,
        ),
      ],
      loadAvg: const [3.43, 3.52, 3.31],
      uptime: const Duration(days: 2, hours: 13),
    );
  }
}

Future<void> _pumpMonitorPage(WidgetTester tester, Size size) async {
  // 布局偏好持久化走 SharedPreferences,测试里用内存桩。
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        monitorControllerProvider.overrideWith(_StubMonitorController.new),
      ],
      // 真实应用里 MainShell 的 Scaffold 提供 Material 祖先,这里补一个。
      child: const MaterialApp(home: Scaffold(body: MonitorPage())),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('监控页宽屏渲染全部面板', (tester) async {
    await _pumpMonitorPage(tester, const Size(1280, 900));

    for (final title in [
      '监控',
      'CPU',
      '内存',
      '网络',
      '磁盘',
      'GPU',
      '温度',
      '电池',
      '进程',
    ]) {
      expect(find.text(title), findsWidgets, reason: '缺少面板: $title');
    }
    // 顶栏摘要:负载 + 开机时长。
    expect(find.textContaining('负载 3.43'), findsOneWidget);
    // 电池明细。
    expect(find.text('放电中'), findsOneWidget);
    expect(find.text('112'), findsOneWidget);
    // 进程行。
    expect(find.text('termora'), findsOneWidget);
    expect(find.text('launchd'), findsOneWidget);
    // 有进程带磁盘 I/O 数据时显示 读/s 写/s 两列。
    expect(find.text('读/s'), findsOneWidget);
    expect(find.text('写/s'), findsOneWidget);

    // 每核开关。
    await tester.tap(find.text('每核'));
    await tester.pump();
    expect(find.text('每核'), findsOneWidget);

    // 进程搜索过滤。
    await tester.enterText(find.byType(TextField), 'termora');
    await tester.pump();
    expect(find.text('termora'), findsWidgets);
    expect(find.text('launchd'), findsNothing);
    await tester.enterText(find.byType(TextField), '');
    await tester.pump();

    // 图表时间窗切换。
    await tester.tap(find.text('1m'));
    await tester.pump();
    expect(tester.takeException(), isNull);

    // 进程面板在首屏之下,先滚到可见再操作。
    await tester.ensureVisible(find.byTooltip('进程树'));
    await tester.pump();

    // 树模式:launchd(ppid 0)是根,termora(ppid 1)是其子。
    await tester.tap(find.byTooltip('进程树'));
    await tester.pump();
    expect(find.text('launchd'), findsOneWidget);
    expect(find.text('termora'), findsOneWidget);

    // 聚合模式:每组一行,数量列 ×1。
    await tester.tap(find.byTooltip('按名称聚合'));
    await tester.pump();
    expect(find.text('×1'), findsNWidgets(2));
  });

  testWidgets('面板最大化独占内容区,可还原', (tester) async {
    await _pumpMonitorPage(tester, const Size(1280, 900));

    // 文档树顺序里第一个最大化开关属于 CPU 面板。
    await tester.tap(find.byTooltip('最大化').first);
    await tester.pump();
    expect(find.text('CPU'), findsOneWidget);
    expect(find.text('网络'), findsNothing);
    expect(find.byTooltip('还原'), findsOneWidget);

    await tester.tap(find.byTooltip('还原'));
    await tester.pump();
    expect(find.text('网络'), findsOneWidget);

    // 进程面板最大化走独立分支(Expanded 撑满,不进 ScrollView)。
    await tester.ensureVisible(find.byTooltip('进程树'));
    await tester.pump();
    await tester.tap(find.byTooltip('最大化').last);
    await tester.pump();
    expect(find.text('进程'), findsOneWidget);
    expect(find.text('CPU'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('还原'));
    await tester.pump();
    expect(find.text('CPU'), findsOneWidget);
  });

  testWidgets('布局对话框:开关隐藏面板后栅格移除该面板', (tester) async {
    await _pumpMonitorPage(tester, const Size(1280, 900));
    expect(find.text('网络'), findsOneWidget);

    await tester.tap(find.byTooltip('面板布局'));
    await tester.pumpAndSettle();
    expect(find.text('面板布局'), findsOneWidget);

    // 面板顺序里 network 是第 3 项(下标 2)。
    await tester.tap(find.byType(Switch).at(2));
    await tester.pump();
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();

    expect(find.text('网络'), findsNothing);
    expect(find.text('内存'), findsWidgets); // 其余面板还在
  });

  testWidgets('监控页窄屏单列渲染不溢出', (tester) async {
    await _pumpMonitorPage(tester, const Size(700, 900));
    expect(tester.takeException(), isNull);
    expect(find.text('CPU'), findsOneWidget);
  });
}
