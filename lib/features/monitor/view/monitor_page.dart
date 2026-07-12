import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:termora/app/shell/page_top_bar.dart';
import 'package:termora/app/theme/app_theme.dart';
import 'package:termora/core/l10n/app_l10n.dart';
import 'package:termora/features/monitor/controller/monitor_providers.dart';
import 'package:termora/features/monitor/view/widgets/monitor_format.dart';
import 'package:termora/features/monitor/view/widgets/monitor_panels.dart';
import 'package:termora/features/monitor/view/widgets/process_table.dart';

/// 系统监控页 —— 参考 bottom(btm):CPU / 内存 / 网络 / 磁盘 /
/// 温度 / 电池 / 进程 七块面板。
///
/// 页面不可见(IndexedStack 切走,TickerMode 关闭)时自动停采,
/// 切回来立即恢复并补一轮采样。
class MonitorPage extends ConsumerStatefulWidget {
  const MonitorPage({super.key});

  @override
  ConsumerState<MonitorPage> createState() => _MonitorPageState();
}

class _MonitorPageState extends ConsumerState<MonitorPage> {
  bool? _lastVisible;

  /// 当前最大化独占内容区的面板 id;null = 正常栅格。
  String? _maxPanelId;

  /// dispose 阶段不能再碰 ref,提前存下 notifier。
  late MonitorController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(monitorControllerProvider.notifier);
  }

  @override
  void dispose() {
    // 页面树被销毁时确保停采(通常不会发生,IndexedStack 常驻)。
    final controller = _controller;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      controller.setPageVisible(false);
    });
    super.dispose();
  }

  void _reportVisible(bool visible) {
    if (_lastVisible == visible) return;
    _lastVisible = visible;
    // build 期间不能改 provider,推到帧后。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller.setPageVisible(visible);
    });
  }

  @override
  Widget build(BuildContext context) {
    _reportVisible(TickerMode.valuesOf(context).enabled);
    final state = ref.watch(monitorControllerProvider);
    final latest = state.latest;

    final subtitleParts = <String>[
      if (latest?.loadAvg != null)
        '${tr('负载')} ${latest!.loadAvg!.map((v) => v.toStringAsFixed(2)).join(' ')}',
      if (latest?.uptime != null)
        '${tr('已开机')} ${fmtDuration(latest!.uptime!)}',
    ];

    return Container(
      color: AppTheme.backgroundColor,
      child: Column(
        children: [
          PageTopBar(
            icon: LucideIcons.activity,
            title: tr('监控'),
            subtitle: subtitleParts.join(' · '),
          ),
          _Toolbar(state: state),
          Expanded(
            child: !state.supported
                ? Center(
                    child: Text(
                      tr('当前平台暂不支持系统监控'),
                      style: TextStyle(
                        fontSize: 13,
                        color: AppTheme.subtleTextColor,
                      ),
                    ),
                  )
                : _maxPanelId != null
                ? Padding(
                    padding: const EdgeInsets.all(12),
                    // 进程面板最大化时内部用 Expanded 撑满,直接铺满内容区
                    // (不能进 ScrollView);其余面板高度固定,滚动兜底。
                    child: _maxPanelId == 'process'
                        ? _buildPanel('process', state, expanded: true)
                        : SingleChildScrollView(
                            child: _buildPanel(
                              _maxPanelId!,
                              state,
                              expanded: true,
                            ),
                          ),
                  )
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: _PanelGrid(
                      state: state,
                      buildPanel: (id) => _buildPanel(id, state),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// 按 id 构建面板;所有面板都带最大化开关。
  Widget _buildPanel(String id, MonitorState state, {bool expanded = false}) {
    void toggle() =>
        setState(() => _maxPanelId = _maxPanelId == null ? id : null);
    return switch (id) {
      'cpu' => CpuPanel(
        state: state,
        expanded: expanded,
        onToggleMaximize: toggle,
      ),
      'memory' => MemoryPanel(
        state: state,
        expanded: expanded,
        onToggleMaximize: toggle,
      ),
      'network' => NetworkPanel(
        state: state,
        expanded: expanded,
        onToggleMaximize: toggle,
      ),
      'disk' => DiskPanel(
        state: state,
        expanded: expanded,
        onToggleMaximize: toggle,
      ),
      'gpu' => GpuPanel(
        state: state,
        expanded: expanded,
        onToggleMaximize: toggle,
      ),
      'temp' => TemperaturePanel(
        state: state,
        expanded: expanded,
        onToggleMaximize: toggle,
      ),
      'battery' => BatteryPanel(
        state: state,
        expanded: expanded,
        onToggleMaximize: toggle,
      ),
      _ => ProcessPanel(
        state: state,
        expanded: expanded,
        onToggleMaximize: toggle,
      ),
    };
  }
}

/// 工具栏:采样状态 + 间隔选择 + 暂停/继续。
class _Toolbar extends ConsumerWidget {
  const _Toolbar({required this.state});

  final MonitorState state;

  static const _intervals = [1, 2, 5, 10];

  /// 图表时间窗选项(秒);0 = 全部历史。
  static const _windows = [60, 300, 0];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(monitorControllerProvider.notifier);
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: AppTheme.surfaceColor,
        border: Border(
          bottom: BorderSide(color: AppTheme.borderColor, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          // 采样状态指示灯。
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: state.sampling
                  ? AppTheme.successColor
                  : AppTheme.subtleTextColor,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            state.paused
                ? tr('已暂停')
                : state.latest == null
                ? tr('等待采样…')
                : tr('实时采样中'),
            style: TextStyle(fontSize: 11, color: AppTheme.subtleTextColor),
          ),
          const Spacer(),
          Text(
            tr('时间窗'),
            style: TextStyle(fontSize: 11, color: AppTheme.subtleTextColor),
          ),
          const SizedBox(width: 8),
          for (final w in _windows) ...[
            _ToolbarChip(
              label: w == 0 ? tr('全部') : (w < 60 ? '${w}s' : '${w ~/ 60}m'),
              selected: state.chartWindowSeconds == w,
              onTap: () => controller.setChartWindow(w),
            ),
            const SizedBox(width: 4),
          ],
          const SizedBox(width: 14),
          Text(
            tr('采样间隔'),
            style: TextStyle(fontSize: 11, color: AppTheme.subtleTextColor),
          ),
          const SizedBox(width: 8),
          for (final s in _intervals) ...[
            _ToolbarChip(
              label: '${s}s',
              selected: state.intervalSeconds == s,
              onTap: () => controller.setInterval(s),
            ),
            const SizedBox(width: 4),
          ],
          const SizedBox(width: 8),
          IconButton(
            tooltip: tr('面板布局'),
            visualDensity: VisualDensity.compact,
            icon: Icon(
              LucideIcons.layoutDashboard,
              size: 15,
              color: AppTheme.subtleTextColor,
            ),
            onPressed: () => _showLayoutDialog(context),
          ),
          IconButton(
            tooltip: state.paused ? tr('继续') : tr('暂停'),
            visualDensity: VisualDensity.compact,
            icon: Icon(
              state.paused ? LucideIcons.play : LucideIcons.pause,
              size: 15,
              color: state.paused
                  ? AppTheme.brandColor
                  : AppTheme.subtleTextColor,
            ),
            onPressed: controller.togglePaused,
          ),
        ],
      ),
    );
  }
}

/// 面板 id → 展示名。
String monitorPanelName(String id) => switch (id) {
  'cpu' => 'CPU',
  'memory' => tr('内存'),
  'network' => tr('网络'),
  'disk' => tr('磁盘'),
  'gpu' => 'GPU',
  'temp' => tr('温度'),
  'battery' => tr('电池'),
  _ => tr('进程'),
};

/// 布局管理对话框:拖拽排序 + 显示开关 + 恢复默认。
void _showLayoutDialog(BuildContext context) {
  showDialog<void>(
    context: context,
    useRootNavigator: false,
    builder: (context) => Consumer(
      builder: (context, ref, _) {
        final state = ref.watch(monitorControllerProvider);
        final controller = ref.read(monitorControllerProvider.notifier);
        return AlertDialog(
          title: Row(
            children: [
              Text(tr('面板布局'), style: const TextStyle(fontSize: 15)),
              const Spacer(),
              TextButton.icon(
                onPressed: controller.resetPanelLayout,
                icon: const Icon(LucideIcons.rotateCcw, size: 13),
                label: Text(
                  tr('恢复默认'),
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
          contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          content: SizedBox(
            width: 320,
            height: 384,
            child: ReorderableListView.builder(
              buildDefaultDragHandles: false,
              itemCount: state.panelOrder.length,
              onReorder: controller.movePanel,
              itemBuilder: (context, index) {
                final id = state.panelOrder[index];
                final visible = !state.hiddenPanels.contains(id);
                return SizedBox(
                  key: ValueKey(id),
                  height: 44,
                  child: Row(
                    children: [
                      ReorderableDragStartListener(
                        index: index,
                        child: MouseRegion(
                          cursor: SystemMouseCursors.grab,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                            ),
                            child: Icon(
                              LucideIcons.gripVertical,
                              size: 14,
                              color: AppTheme.subtleTextColor,
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          monitorPanelName(id),
                          style: TextStyle(
                            fontSize: 12.5,
                            color: visible
                                ? AppTheme.headingColor
                                : AppTheme.subtleTextColor,
                          ),
                        ),
                      ),
                      Switch(
                        value: visible,
                        onChanged: (_) => controller.togglePanelVisible(id),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(tr('关闭')),
            ),
          ],
        );
      },
    ),
  );
}

class _ToolbarChip extends StatelessWidget {
  const _ToolbarChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(5),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: selected ? AppTheme.softBrandColor : Colors.transparent,
          borderRadius: BorderRadius.circular(5),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
            color: selected ? AppTheme.brandColor : AppTheme.subtleTextColor,
          ),
        ),
      ),
    );
  }
}

/// 通栏面板(其余为半宽,宽屏下两两一行)。
const Set<String> _fullSpanPanels = {'cpu', 'disk', 'process'};

/// 面板栅格:按用户自定义顺序渲染;宽屏下半宽面板两两打包一行,
/// 窄屏单列。
class _PanelGrid extends StatelessWidget {
  const _PanelGrid({required this.state, required this.buildPanel});

  final MonitorState state;

  /// 由页面按面板 id 构建(带最大化开关)。
  final Widget Function(String id) buildPanel;

  @override
  Widget build(BuildContext context) {
    final visible = state.visiblePanels;
    if (visible.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 48),
        child: Center(
          child: Text(
            tr('所有面板都被隐藏了,点工具栏「面板」重新打开'),
            style: TextStyle(fontSize: 12, color: AppTheme.subtleTextColor),
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 920;
        const gap = SizedBox(width: 12, height: 12);

        if (!wide) {
          return Column(
            children: [
              for (var i = 0; i < visible.length; i++) ...[
                if (i > 0) gap,
                buildPanel(visible[i]),
              ],
            ],
          );
        }

        final rows = <Widget>[];
        var i = 0;
        while (i < visible.length) {
          final id = visible[i];
          if (_fullSpanPanels.contains(id)) {
            rows.add(buildPanel(id));
            i++;
          } else if (i + 1 < visible.length &&
              !_fullSpanPanels.contains(visible[i + 1])) {
            // 相邻两个半宽面板拼一行。
            rows.add(
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: buildPanel(id)),
                  gap,
                  Expanded(child: buildPanel(visible[i + 1])),
                ],
              ),
            );
            i += 2;
          } else {
            // 落单的半宽面板:占半行,右边留白。
            rows.add(
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: buildPanel(id)),
                  gap,
                  const Expanded(child: SizedBox()),
                ],
              ),
            );
            i++;
          }
        }
        return Column(
          children: [
            for (var r = 0; r < rows.length; r++) ...[
              if (r > 0) gap,
              rows[r],
            ],
          ],
        );
      },
    );
  }
}
