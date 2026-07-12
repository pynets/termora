import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:termora/app/theme/app_theme.dart';
import 'package:termora/core/l10n/app_l10n.dart';
import 'package:termora/core/widgets/charts/live_line_chart.dart';
import 'package:termora/core/widgets/charts/ring_gauge.dart';
import 'package:termora/features/monitor/controller/monitor_providers.dart';
import 'package:termora/features/monitor/domain/monitor_models.dart';
import 'package:termora/features/monitor/view/widgets/monitor_format.dart';

/// 折线序列配色(每核 CPU 等多序列时循环取用)。
const List<Color> kSeriesPalette = [
  Color(0xFF3B82F6), // blue
  Color(0xFF10B981), // emerald
  Color(0xFFF59E0B), // amber
  Color(0xFFEF4444), // red
  Color(0xFF8B5CF6), // violet
  Color(0xFF14B8A6), // teal
  Color(0xFFF97316), // orange
  Color(0xFFEC4899), // pink
  Color(0xFF84CC16), // lime
  Color(0xFF06B6D4), // cyan
  Color(0xFF6366F1), // indigo
  Color(0xFFA855F7), // purple
];

/// 面板外壳:标题行(图标 + 名称 + 右侧内容 + 最大化开关)+ 主体。
class MonitorPanel extends StatelessWidget {
  const MonitorPanel({
    super.key,
    required this.icon,
    required this.title,
    required this.child,
    this.trailing,
    this.maximized = false,
    this.onToggleMaximize,
    this.stretch = false,
  });

  final IconData icon;
  final String title;
  final Widget child;
  final Widget? trailing;

  /// 当前是否处于最大化(独占内容区)状态,影响开关图标。
  final bool maximized;

  /// 最大化/还原回调;null 时不显示开关。
  final VoidCallback? onToggleMaximize;

  /// 主体撑满剩余高度(仅在父约束有界时使用,如最大化模式)。
  final bool stretch;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: AppTheme.panelDecoration(),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: AppTheme.brandColor),
              const SizedBox(width: 7),
              Text(
                title,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.headingColor,
                ),
              ),
              const Spacer(),
              if (trailing != null)
                Flexible(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: trailing!,
                  ),
                ),
              if (onToggleMaximize != null) ...[
                const SizedBox(width: 8),
                Tooltip(
                  message: maximized ? tr('还原') : tr('最大化'),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(4),
                    onTap: onToggleMaximize,
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Icon(
                        maximized
                            ? LucideIcons.minimize2
                            : LucideIcons.maximize2,
                        size: 12,
                        color: AppTheme.subtleTextColor,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          if (stretch) Expanded(child: child) else child,
        ],
      ),
    );
  }
}

/// 面板标题右侧的小号说明文字。
class PanelCaption extends StatelessWidget {
  const PanelCaption(this.text, {super.key, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 11,
        color: color ?? AppTheme.subtleTextColor,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

/// 面板主体空态。
class PanelEmpty extends StatelessWidget {
  const PanelEmpty(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: Center(
        child: Text(
          text,
          style: TextStyle(fontSize: 11.5, color: AppTheme.subtleTextColor),
        ),
      ),
    );
  }
}

// ==================================================================== CPU

class CpuPanel extends StatefulWidget {
  const CpuPanel({
    super.key,
    required this.state,
    this.expanded = false,
    this.onToggleMaximize,
  });

  final MonitorState state;
  final bool expanded;
  final VoidCallback? onToggleMaximize;

  @override
  State<CpuPanel> createState() => _CpuPanelState();
}

class _CpuPanelState extends State<CpuPanel> {
  bool _showPerCore = false;

  @override
  Widget build(BuildContext context) {
    final latest = widget.state.latest?.cpu;
    final coreCount = latest?.perCore.length ?? 0;

    final series = <LineSeries>[
      LineSeries(
        label: tr('平均'),
        color: AppTheme.brandColor,
        values: widget.state.series((s) => s.cpu?.totalUsage),
      ),
      if (_showPerCore)
        for (var i = 0; i < coreCount; i++)
          LineSeries(
            label: 'C$i',
            color: kSeriesPalette[i % kSeriesPalette.length],
            values: widget.state.series(
              (s) =>
                  (s.cpu != null && i < s.cpu!.perCore.length)
                  ? s.cpu!.perCore[i]
                  : null,
            ),
          ),
    ];

    return MonitorPanel(
      icon: LucideIcons.cpu,
      title: 'CPU',
      maximized: widget.expanded,
      onToggleMaximize: widget.onToggleMaximize,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (latest != null)
            PanelCaption(
              coreCount > 0
                  ? tr2('{0} 核 · {1}', [coreCount, fmtPercent(latest.totalUsage)])
                  : fmtPercent(latest.totalUsage),
              color: AppTheme.headingColor,
            ),
          if (coreCount > 0) ...[
            const SizedBox(width: 10),
            _PerCoreToggle(
              value: _showPerCore,
              onChanged: (v) => setState(() => _showPerCore = v),
            ),
          ],
        ],
      ),
      child: latest == null
          ? PanelEmpty(tr('等待采样…'))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LiveLineChart(
                  series: series,
                  height: widget.expanded ? 340 : 150,
                  minY: 0,
                  maxY: 100,
                  yFormat: (v) => '${v.toStringAsFixed(0)}%',
                  gridColor: AppTheme.borderColor,
                  textColor: AppTheme.subtleTextColor,
                  tooltipBg: AppTheme.mutedSurfaceColor,
                ),
                if (coreCount > 0) ...[
                  const SizedBox(height: 10),
                  _CoreMeterGrid(perCore: latest.perCore),
                ],
              ],
            ),
    );
  }
}

/// 每核使用率网格(对齐 bottom 的 per-core 视图,一格一核)。
class _CoreMeterGrid extends StatelessWidget {
  const _CoreMeterGrid({required this.perCore});

  final List<double> perCore;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 6,
      children: [
        for (var i = 0; i < perCore.length; i++)
          SizedBox(
            width: 118,
            child: Row(
              children: [
                SizedBox(
                  width: 26,
                  child: Text(
                    'C$i',
                    style: TextStyle(
                      fontSize: 10,
                      color: AppTheme.subtleTextColor,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: (perCore[i] / 100).clamp(0.0, 1.0),
                      minHeight: 4,
                      backgroundColor: AppTheme.subtleSurfaceColor,
                      valueColor: AlwaysStoppedAnimation(
                        perCore[i] >= 90
                            ? AppTheme.errorColor
                            : perCore[i] >= 60
                            ? AppTheme.warningColor
                            : kSeriesPalette[i % kSeriesPalette.length],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 5),
                SizedBox(
                  width: 30,
                  child: Text(
                    '${perCore[i].round()}%',
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: 10,
                      color: AppTheme.bodyColor,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _PerCoreToggle extends StatelessWidget {
  const _PerCoreToggle({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(5),
      onTap: () => onChanged(!value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: value ? AppTheme.softBrandColor : Colors.transparent,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(
            color: value ? AppTheme.brandColor : AppTheme.borderColor,
            width: 0.8,
          ),
        ),
        child: Text(
          tr('每核'),
          style: TextStyle(
            fontSize: 10.5,
            color: value ? AppTheme.brandColor : AppTheme.subtleTextColor,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

// ================================================================= Memory

class MemoryPanel extends StatelessWidget {
  const MemoryPanel({
    super.key,
    required this.state,
    this.expanded = false,
    this.onToggleMaximize,
  });

  final MonitorState state;
  final bool expanded;
  final VoidCallback? onToggleMaximize;

  @override
  Widget build(BuildContext context) {
    final mem = state.latest?.memory;
    return MonitorPanel(
      icon: LucideIcons.memoryStick,
      title: tr('内存'),
      maximized: expanded,
      onToggleMaximize: onToggleMaximize,
      trailing: mem == null
          ? null
          : PanelCaption(
              '${fmtBytes(mem.usedBytes)} / ${fmtBytes(mem.totalBytes)}',
              color: AppTheme.headingColor,
            ),
      child: mem == null
          ? PanelEmpty(tr('等待采样…'))
          : Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Column(
                  children: [
                    RingGauge(
                      value: mem.usedPercent / 100,
                      color: AppTheme.brandColor,
                      trackColor: AppTheme.subtleSurfaceColor,
                      centerText: fmtPercent(mem.usedPercent),
                      centerTextColor: AppTheme.headingColor,
                      label: tr('内存'),
                      labelColor: AppTheme.subtleTextColor,
                    ),
                    if (mem.swapTotalBytes > 0) ...[
                      const SizedBox(height: 8),
                      RingGauge(
                        value: mem.swapPercent / 100,
                        color: AppTheme.warningColor,
                        trackColor: AppTheme.subtleSurfaceColor,
                        size: 52,
                        strokeWidth: 6,
                        centerText: fmtPercent(mem.swapPercent),
                        centerTextColor: AppTheme.headingColor,
                        label: tr('交换'),
                        labelColor: AppTheme.subtleTextColor,
                      ),
                    ],
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: LiveLineChart(
                    series: [
                      LineSeries(
                        label: tr('内存 %'),
                        color: AppTheme.brandColor,
                        values: state.series((s) => s.memory?.usedPercent),
                      ),
                      if (mem.cacheBytes > 0)
                        LineSeries(
                          label: tr('缓存 %'),
                          color: const Color(0xFF8B5CF6),
                          values: state.series((s) => s.memory?.cachePercent),
                        ),
                      if (mem.swapTotalBytes > 0)
                        LineSeries(
                          label: tr('交换 %'),
                          color: AppTheme.warningColor,
                          values: state.series((s) => s.memory?.swapPercent),
                        ),
                    ],
                    height: expanded ? 320 : 132,
                    minY: 0,
                    maxY: 100,
                    yFormat: (v) => '${v.toStringAsFixed(0)}%',
                    gridColor: AppTheme.borderColor,
                    textColor: AppTheme.subtleTextColor,
                    tooltipBg: AppTheme.mutedSurfaceColor,
                  ),
                ),
              ],
            ),
    );
  }
}

// ================================================================ Network

class NetworkPanel extends StatelessWidget {
  const NetworkPanel({
    super.key,
    required this.state,
    this.expanded = false,
    this.onToggleMaximize,
  });

  final MonitorState state;
  final bool expanded;
  final VoidCallback? onToggleMaximize;

  @override
  Widget build(BuildContext context) {
    final net = state.latest?.network;
    return MonitorPanel(
      icon: LucideIcons.arrowDownUp,
      title: tr('网络'),
      maximized: expanded,
      onToggleMaximize: onToggleMaximize,
      trailing: net == null
          ? null
          : PanelCaption(
              '↓ ${fmtRate(net.rxRate)}   ↑ ${fmtRate(net.txRate)}',
              color: AppTheme.headingColor,
            ),
      child: net == null
          ? PanelEmpty(tr('等待采样…'))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LiveLineChart(
                  series: [
                    LineSeries(
                      label: tr('接收'),
                      color: AppTheme.successColor,
                      values: state.series((s) => s.network?.rxRate),
                    ),
                    LineSeries(
                      label: tr('发送'),
                      color: const Color(0xFF3B82F6),
                      values: state.series((s) => s.network?.txRate),
                    ),
                  ],
                  height: expanded ? 320 : 132,
                  minY: 0,
                  yFormat: (v) => fmtBytes(v),
                  gridColor: AppTheme.borderColor,
                  textColor: AppTheme.subtleTextColor,
                  tooltipBg: AppTheme.mutedSurfaceColor,
                ),
                const SizedBox(height: 6),
                PanelCaption(
                  tr2('累计 ↓ {0} · ↑ {1}', [
                    fmtBytes(net.rxTotalBytes),
                    fmtBytes(net.txTotalBytes),
                  ]),
                ),
              ],
            ),
    );
  }
}

// =================================================================== Disk

class DiskPanel extends StatelessWidget {
  const DiskPanel({
    super.key,
    required this.state,
    this.expanded = false,
    this.onToggleMaximize,
  });

  final MonitorState state;
  final bool expanded;
  final VoidCallback? onToggleMaximize;

  @override
  Widget build(BuildContext context) {
    final snapshot = state.latest;
    final disks = snapshot?.disks ?? const <DiskInfo>[];
    final hasPerDiskIo = disks.any(
      (d) => d.readRate != null || d.writeRate != null,
    );

    String? ioCaption;
    if (snapshot?.diskReadRate != null && snapshot?.diskWriteRate != null) {
      ioCaption =
          '${tr('读')} ${fmtRate(snapshot!.diskReadRate)} · ${tr('写')} ${fmtRate(snapshot.diskWriteRate)}';
    } else if (snapshot?.diskReadRate != null) {
      ioCaption = 'I/O ${fmtRate(snapshot!.diskReadRate)}';
    }

    return MonitorPanel(
      icon: LucideIcons.hardDrive,
      title: tr('磁盘'),
      maximized: expanded,
      onToggleMaximize: onToggleMaximize,
      trailing: ioCaption == null
          ? null
          : PanelCaption(ioCaption, color: AppTheme.headingColor),
      child: disks.isEmpty
          ? PanelEmpty(tr('等待采样…'))
          : Column(
              children: [
                // 磁盘 I/O 历史曲线(bottom 的 disk_io_graph;
                // macOS 只有整机合计,Linux 分读/写)。
                if (state.history.any((s) => s.diskReadRate != null)) ...[
                  _DiskIoChart(state: state, expanded: expanded),
                  const SizedBox(height: 10),
                ],
                for (final d in disks) ...[
                  _DiskRow(disk: d, showIo: hasPerDiskIo),
                  if (d != disks.last) const SizedBox(height: 8),
                ],
              ],
            ),
    );
  }
}

class _DiskIoChart extends StatelessWidget {
  const _DiskIoChart({required this.state, this.expanded = false});

  final MonitorState state;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final split = state.history.any((s) => s.diskWriteRate != null);
    return LiveLineChart(
      series: split
          ? [
              LineSeries(
                label: tr('读'),
                color: AppTheme.successColor,
                values: state.series((s) => s.diskReadRate),
              ),
              LineSeries(
                label: tr('写'),
                color: const Color(0xFFF97316),
                values: state.series((s) => s.diskWriteRate),
              ),
            ]
          : [
              LineSeries(
                label: 'I/O',
                color: AppTheme.brandColor,
                values: state.series((s) => s.diskReadRate),
              ),
            ],
      height: expanded ? 240 : 90,
      minY: 0,
      yFormat: (v) => fmtBytes(v),
      gridColor: AppTheme.borderColor,
      textColor: AppTheme.subtleTextColor,
      tooltipBg: AppTheme.mutedSurfaceColor,
    );
  }
}

class _DiskRow extends StatelessWidget {
  const _DiskRow({required this.disk, required this.showIo});

  final DiskInfo disk;
  final bool showIo;

  @override
  Widget build(BuildContext context) {
    final percent = disk.usedPercent;
    final barColor = percent >= 90
        ? AppTheme.errorColor
        : percent >= 75
        ? AppTheme.warningColor
        : AppTheme.brandColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                disk.mountPoint,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.headingColor,
                ),
              ),
            ),
            if (showIo)
              PanelCaption(
                '${tr('读')} ${fmtRate(disk.readRate)} · ${tr('写')} ${fmtRate(disk.writeRate)}',
              ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: (percent / 100).clamp(0.0, 1.0),
                  minHeight: 5,
                  backgroundColor: AppTheme.subtleSurfaceColor,
                  valueColor: AlwaysStoppedAnimation(barColor),
                ),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 150,
              child: Text(
                '${fmtBytes(disk.usedBytes)} / ${fmtBytes(disk.totalBytes)} · ${fmtPercent(percent)}',
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: 10.5,
                  color: AppTheme.subtleTextColor,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          disk.device,
          style: TextStyle(fontSize: 10, color: AppTheme.subtleTextColor),
        ),
      ],
    );
  }
}

// ==================================================================== GPU

class GpuPanel extends StatelessWidget {
  const GpuPanel({
    super.key,
    required this.state,
    this.expanded = false,
    this.onToggleMaximize,
  });

  final MonitorState state;
  final bool expanded;
  final VoidCallback? onToggleMaximize;

  @override
  Widget build(BuildContext context) {
    final gpus = state.latest?.gpus ?? const <GpuInfo>[];
    return MonitorPanel(
      icon: LucideIcons.gpu,
      title: 'GPU',
      maximized: expanded,
      onToggleMaximize: onToggleMaximize,
      trailing: gpus.isEmpty
          ? null
          : PanelCaption(
              fmtPercent(gpus.first.utilization),
              color: AppTheme.headingColor,
            ),
      child: gpus.isEmpty
          ? PanelEmpty(tr('无 GPU 数据'))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LiveLineChart(
                  series: [
                    for (var i = 0; i < gpus.length; i++)
                      LineSeries(
                        label: gpus[i].label,
                        color: kSeriesPalette[i % kSeriesPalette.length],
                        values: state.series(
                          (s) => i < s.gpus.length
                              ? s.gpus[i].utilization
                              : null,
                        ),
                      ),
                  ],
                  height: expanded ? 320 : 132,
                  minY: 0,
                  maxY: 100,
                  yFormat: (v) => '${v.toStringAsFixed(0)}%',
                  gridColor: AppTheme.borderColor,
                  textColor: AppTheme.subtleTextColor,
                  tooltipBg: AppTheme.mutedSurfaceColor,
                ),
                const SizedBox(height: 6),
                for (final g in gpus)
                  if (g.memUsedBytes != null)
                    PanelCaption(
                      g.memTotalBytes != null
                          ? '${g.label} · ${tr('显存')} ${fmtBytes(g.memUsedBytes!)} / ${fmtBytes(g.memTotalBytes!)}'
                          : '${g.label} · ${tr('显存')} ${fmtBytes(g.memUsedBytes!)}',
                    ),
              ],
            ),
    );
  }
}

// ============================================================ Temperature

class TemperaturePanel extends StatelessWidget {
  const TemperaturePanel({
    super.key,
    required this.state,
    this.expanded = false,
    this.onToggleMaximize,
  });

  final MonitorState state;
  final bool expanded;
  final VoidCallback? onToggleMaximize;

  @override
  Widget build(BuildContext context) {
    final temps = state.latest?.temps ?? const <TempSensor>[];
    return MonitorPanel(
      icon: LucideIcons.thermometer,
      title: tr('温度'),
      maximized: expanded,
      onToggleMaximize: onToggleMaximize,
      child: temps.isEmpty
          ? PanelEmpty(tr('无可用温度传感器'))
          : Column(
              children: [
                for (final t in temps)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            tr(t.label),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11.5,
                              color: AppTheme.bodyColor,
                            ),
                          ),
                        ),
                        Text(
                          '${t.celsius.toStringAsFixed(1)} °C',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            fontFeatures: const [
                              FontFeature.tabularFigures(),
                            ],
                            color: t.celsius >= 80
                                ? AppTheme.errorColor
                                : t.celsius >= 60
                                ? AppTheme.warningColor
                                : AppTheme.successColor,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

// ================================================================ Battery

class BatteryPanel extends StatelessWidget {
  const BatteryPanel({
    super.key,
    required this.state,
    this.expanded = false,
    this.onToggleMaximize,
  });

  final MonitorState state;
  final bool expanded;
  final VoidCallback? onToggleMaximize;

  @override
  Widget build(BuildContext context) {
    final battery = state.latest?.battery;
    return MonitorPanel(
      icon: LucideIcons.batteryCharging,
      title: tr('电池'),
      maximized: expanded,
      onToggleMaximize: onToggleMaximize,
      child: battery == null
          ? PanelEmpty(tr('无电池'))
          : Row(
              children: [
                RingGauge(
                  value: battery.percent / 100,
                  color: battery.percent <= 20
                      ? AppTheme.errorColor
                      : AppTheme.successColor,
                  trackColor: AppTheme.subtleSurfaceColor,
                  centerText: '${battery.percent.toStringAsFixed(0)}%',
                  centerTextColor: AppTheme.headingColor,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _batteryLine(
                        tr('状态'),
                        switch (battery.state) {
                          BatteryState.charging => tr('充电中'),
                          BatteryState.discharging => tr('放电中'),
                          BatteryState.full => tr('已充满'),
                          BatteryState.unknown => tr('未知'),
                        },
                      ),
                      if (battery.timeRemaining != null)
                        _batteryLine(
                          battery.state == BatteryState.charging
                              ? tr('充满还需')
                              : tr('可用时间'),
                          fmtDuration(battery.timeRemaining!),
                        ),
                      if (battery.healthPercent != null)
                        _batteryLine(
                          tr('健康度'),
                          fmtPercent(battery.healthPercent!),
                        ),
                      if (battery.cycleCount != null)
                        _batteryLine(tr('循环次数'), '${battery.cycleCount}'),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _batteryLine(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: TextStyle(fontSize: 11, color: AppTheme.subtleTextColor),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: AppTheme.headingColor,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
