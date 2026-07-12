import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:termora/features/monitor/controller/monitor_providers.dart';
import 'package:termora/features/monitor/domain/monitor_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late MonitorController controller;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    container = ProviderContainer();
    addTearDown(container.dispose);
    controller = container.read(monitorControllerProvider.notifier);
  });

  MonitorState state() => container.read(monitorControllerProvider);

  test('面板拖拽排序(ReorderableListView 下标语义)', () {
    controller.movePanel(0, 3); // cpu 移到 disk 前
    expect(
      state().panelOrder.take(4),
      ['memory', 'network', 'cpu', 'disk'],
    );
    controller.movePanel(2, 0); // cpu 移回最前
    expect(state().panelOrder.first, 'cpu');
  });

  test('面板显示/隐藏与恢复默认', () async {
    controller.togglePanelVisible('battery');
    controller.togglePanelVisible('gpu');
    expect(state().hiddenPanels, {'battery', 'gpu'});
    expect(state().visiblePanels, isNot(contains('battery')));

    controller.togglePanelVisible('battery');
    expect(state().hiddenPanels, {'gpu'});

    controller.resetPanelLayout();
    expect(state().hiddenPanels, isEmpty);
    expect(state().panelOrder, kMonitorPanelIds);

    // 持久化落到 SharedPreferences。
    controller.togglePanelVisible('temp');
    await Future<void>.delayed(Duration.zero);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('monitor.hiddenPanels'), ['temp']);
  });

  test('时间窗按采样时刻裁切历史', () {
    final base = MonitorState(
      chartWindowSeconds: 60,
      history: [
        for (var i = 0; i < 100; i++)
          MonitorSnapshot(tMillis: i * 2000), // 2s 间隔
      ],
    );
    // 60s 窗口 = 最近 31 条(含端点)。
    expect(base.windowedHistory.length, 31);
    expect(base.copyWith(chartWindowSeconds: 0).windowedHistory.length, 100);
  });
}
