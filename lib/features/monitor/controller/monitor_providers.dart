import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:termora/features/monitor/data/platform_collector.dart';
import 'package:termora/features/monitor/domain/monitor_models.dart';

/// 历史窗口容量(样本数);2 秒间隔约等于 6 分钟。
const int kMonitorHistoryCapacity = 180;

/// 全部面板 id(默认顺序)。
const List<String> kMonitorPanelIds = [
  'cpu',
  'memory',
  'network',
  'disk',
  'gpu',
  'temp',
  'battery',
  'process',
];

class MonitorState {
  const MonitorState({
    this.supported = true,
    this.paused = false,
    this.pageVisible = false,
    this.intervalSeconds = 2,
    this.chartWindowSeconds = 0,
    this.panelOrder = kMonitorPanelIds,
    this.hiddenPanels = const {},
    this.history = const [],
  });

  /// 当前平台是否有采集器实现。
  final bool supported;

  /// 用户手动暂停。
  final bool paused;

  /// 监控页当前是否可见(不可见时停采,省资源)。
  final bool pageVisible;

  final int intervalSeconds;

  /// 图表时间窗(秒);0 = 显示全部历史。
  final int chartWindowSeconds;

  /// 面板展示顺序(含隐藏的)。
  final List<String> panelOrder;

  /// 被隐藏的面板 id。
  final Set<String> hiddenPanels;

  /// 滚动窗口内的快照序列(旧→新)。
  final List<MonitorSnapshot> history;

  /// 按顺序过滤出可见面板。
  List<String> get visiblePanels => [
    for (final id in panelOrder)
      if (!hiddenPanels.contains(id)) id,
  ];

  MonitorSnapshot? get latest => history.isEmpty ? null : history.last;

  bool get sampling => supported && pageVisible && !paused;

  MonitorState copyWith({
    bool? supported,
    bool? paused,
    bool? pageVisible,
    int? intervalSeconds,
    int? chartWindowSeconds,
    List<String>? panelOrder,
    Set<String>? hiddenPanels,
    List<MonitorSnapshot>? history,
  }) {
    return MonitorState(
      supported: supported ?? this.supported,
      paused: paused ?? this.paused,
      pageVisible: pageVisible ?? this.pageVisible,
      intervalSeconds: intervalSeconds ?? this.intervalSeconds,
      chartWindowSeconds: chartWindowSeconds ?? this.chartWindowSeconds,
      panelOrder: panelOrder ?? this.panelOrder,
      hiddenPanels: hiddenPanels ?? this.hiddenPanels,
      history: history ?? this.history,
    );
  }

  /// 时间窗内的历史(按采样时刻裁切,采样间隔中途改过也正确)。
  List<MonitorSnapshot> get windowedHistory {
    if (chartWindowSeconds <= 0 || history.isEmpty) return history;
    final cutoff = history.last.tMillis - chartWindowSeconds * 1000;
    final start = history.indexWhere((s) => s.tMillis >= cutoff);
    return start <= 0 ? history : history.sublist(start);
  }

  /// 从时间窗内的历史抽一条数值序列给折线图(null = 断点)。
  List<double?> series(double? Function(MonitorSnapshot s) selector) => [
    for (final s in windowedHistory) selector(s),
  ];
}

class MonitorController extends Notifier<MonitorState> {
  static const _prefInterval = 'monitor.intervalSeconds';
  static const _prefWindow = 'monitor.chartWindowSeconds';
  static const _prefOrder = 'monitor.panelOrder';
  static const _prefHidden = 'monitor.hiddenPanels';

  PlatformCollector? _collector;
  Timer? _timer;
  bool _busy = false;

  @override
  MonitorState build() {
    _collector = PlatformCollector.forCurrentPlatform();
    ref.onDispose(() {
      _timer?.cancel();
      _collector?.dispose();
    });
    unawaited(_loadPrefs());
    // Windows 每轮要跑 PowerShell,默认间隔放宽。
    return MonitorState(
      supported: _collector != null,
      intervalSeconds: Platform.isWindows ? 4 : 2,
    );
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final interval = prefs.getInt(_prefInterval);
    final window = prefs.getInt(_prefWindow);
    final order = prefs.getStringList(_prefOrder);
    final hidden = prefs.getStringList(_prefHidden);
    if (interval == null && window == null && order == null && hidden == null) {
      return;
    }
    state = state.copyWith(
      intervalSeconds: interval?.clamp(1, 60),
      chartWindowSeconds: window?.clamp(0, 86400),
      panelOrder: order == null ? null : _sanitizeOrder(order),
      hiddenPanels: hidden == null
          ? null
          : {
              for (final id in hidden)
                if (kMonitorPanelIds.contains(id)) id,
            },
    );
    _syncTimer();
  }

  /// 存档顺序与当前版本面板集合对齐:去掉未知 id,补上新增面板。
  static List<String> _sanitizeOrder(List<String> saved) {
    final order = [
      for (final id in saved)
        if (kMonitorPanelIds.contains(id)) id,
    ];
    for (final id in kMonitorPanelIds) {
      if (!order.contains(id)) order.add(id);
    }
    return order;
  }

  Future<void> _savePref(String key, int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(key, value);
  }

  Future<void> _savePanelPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefOrder, state.panelOrder);
    await prefs.setStringList(_prefHidden, state.hiddenPanels.toList());
  }

  /// 页面可见性变化(IndexedStack 切页时由页面上报)。
  void setPageVisible(bool visible) {
    if (state.pageVisible == visible) return;
    state = state.copyWith(pageVisible: visible);
    _syncTimer(immediateTick: visible);
  }

  void togglePaused() {
    state = state.copyWith(paused: !state.paused);
    _syncTimer(immediateTick: !state.paused);
  }

  void setInterval(int seconds) {
    if (seconds == state.intervalSeconds) return;
    state = state.copyWith(intervalSeconds: seconds);
    _syncTimer();
    unawaited(_savePref(_prefInterval, seconds));
  }

  /// 图表时间窗;0 = 全部。
  void setChartWindow(int seconds) {
    if (seconds == state.chartWindowSeconds) return;
    state = state.copyWith(chartWindowSeconds: seconds);
    unawaited(_savePref(_prefWindow, seconds));
  }

  Future<bool> killProcess(int pid, {bool force = false}) async {
    final ok = await _collector?.killProcess(pid, force: force) ?? false;
    if (ok) unawaited(_tick());
    return ok;
  }

  /// 发送任意信号(bottom 的信号菜单;Windows 不支持返回 false)。
  Future<bool> sendSignal(int pid, String signal) async {
    final ok = await _collector?.sendSignal(pid, signal) ?? false;
    if (ok) unawaited(_tick());
    return ok;
  }

  /// 拖拽调整面板顺序(ReorderableListView 语义的下标)。
  void movePanel(int oldIndex, int newIndex) {
    final order = [...state.panelOrder];
    if (oldIndex < 0 || oldIndex >= order.length) return;
    if (newIndex > oldIndex) newIndex--;
    final id = order.removeAt(oldIndex);
    order.insert(newIndex.clamp(0, order.length), id);
    state = state.copyWith(panelOrder: order);
    unawaited(_savePanelPrefs());
  }

  /// 显示/隐藏某个面板。
  void togglePanelVisible(String id) {
    final hidden = {...state.hiddenPanels};
    hidden.contains(id) ? hidden.remove(id) : hidden.add(id);
    state = state.copyWith(hiddenPanels: hidden);
    unawaited(_savePanelPrefs());
  }

  /// 恢复默认布局。
  void resetPanelLayout() {
    state = state.copyWith(
      panelOrder: kMonitorPanelIds,
      hiddenPanels: const {},
    );
    unawaited(_savePanelPrefs());
  }

  void _syncTimer({bool immediateTick = false}) {
    _timer?.cancel();
    _timer = null;
    if (!state.sampling) return;
    if (immediateTick) unawaited(_tick());
    _timer = Timer.periodic(
      Duration(seconds: state.intervalSeconds),
      (_) => _tick(),
    );
  }

  Future<void> _tick() async {
    final collector = _collector;
    if (collector == null || _busy) return;
    _busy = true;
    try {
      final snapshot = await collector.sample();
      final history = [...state.history, snapshot];
      if (history.length > kMonitorHistoryCapacity) {
        history.removeRange(0, history.length - kMonitorHistoryCapacity);
      }
      state = state.copyWith(history: history);
    } catch (_) {
      // 单轮采样失败不打断节奏,下一轮重试。
    } finally {
      _busy = false;
    }
  }
}

final monitorControllerProvider =
    NotifierProvider<MonitorController, MonitorState>(MonitorController.new);
