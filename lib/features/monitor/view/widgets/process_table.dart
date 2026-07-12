import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:toastification/toastification.dart';

import 'package:termora/app/theme/app_theme.dart';
import 'package:termora/core/l10n/app_l10n.dart';
import 'package:termora/core/widgets/app_toast.dart';
import 'package:termora/features/monitor/controller/monitor_providers.dart';
import 'package:termora/features/monitor/domain/monitor_models.dart';
import 'package:termora/features/monitor/view/widgets/monitor_format.dart';
import 'package:termora/features/monitor/view/widgets/monitor_panels.dart';

enum _ProcSort { cpu, mem, pid, name, user, io }

/// 信号菜单可选信号(TERM/KILL 已有专属按钮)。
const List<String> kProcSignals = [
  'HUP',
  'INT',
  'QUIT',
  'USR1',
  'USR2',
  'STOP',
  'CONT',
];

/// 展示模式(对齐 bottom):平铺列表 / 父子进程树 / 按名称聚合。
enum _ViewMode { list, tree, group }

/// 一行可见的进程(树模式下带缩进层级与折叠状态)。
class _ProcRowData {
  const _ProcRowData(
    this.proc, {
    this.depth = 0,
    this.hasChildren = false,
    this.collapsed = false,
  });

  final ProcInfo proc;
  final int depth;
  final bool hasChildren;
  final bool collapsed;
}

/// 按名称聚合后的一组进程。
class _ProcGroup {
  const _ProcGroup({
    required this.name,
    required this.count,
    required this.cpuPercent,
    required this.memPercent,
    required this.rssBytes,
    required this.pids,
  });

  final String name;
  final int count;
  final double cpuPercent;
  final double memPercent;
  final int rssBytes;
  final List<int> pids;
}

/// 进程面板:搜索 + 表头排序 + 列表/树/聚合 + 结束进程。
class ProcessPanel extends ConsumerStatefulWidget {
  const ProcessPanel({
    super.key,
    required this.state,
    this.expanded = false,
    this.onToggleMaximize,
  });

  final MonitorState state;
  final bool expanded;
  final VoidCallback? onToggleMaximize;

  @override
  ConsumerState<ProcessPanel> createState() => _ProcessPanelState();
}

class _ProcessPanelState extends ConsumerState<ProcessPanel> {
  _ProcSort _sort = _ProcSort.cpu;
  bool _ascending = false;
  String _filter = '';
  _ViewMode _mode = _ViewMode.list;

  /// 树模式下折叠的父进程 pid。
  final Set<int> _collapsed = {};

  List<ProcInfo> get _all =>
      widget.state.latest?.processes ?? const <ProcInfo>[];

  String get _keyword => _filter.trim().toLowerCase();

  bool _matches(ProcInfo p) {
    final k = _keyword;
    return k.isEmpty ||
        p.name.toLowerCase().contains(k) ||
        p.user.toLowerCase().contains(k) ||
        '${p.pid}' == k;
  }

  static double _ioOf(ProcInfo p) => (p.readRate ?? 0) + (p.writeRate ?? 0);

  int _compare(ProcInfo a, ProcInfo b) {
    final cmp = switch (_sort) {
      _ProcSort.cpu => a.cpuPercent.compareTo(b.cpuPercent),
      _ProcSort.mem => a.rssBytes.compareTo(b.rssBytes),
      _ProcSort.pid => a.pid.compareTo(b.pid),
      _ProcSort.name => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      _ProcSort.user => a.user.compareTo(b.user),
      _ProcSort.io => _ioOf(a).compareTo(_ioOf(b)),
    };
    return _ascending ? cmp : -cmp;
  }

  // ------------------------------------------------------------ 行数据

  List<_ProcRowData> _flatRows() {
    final rows = [for (final p in _all) if (_matches(p)) p]..sort(_compare);
    return [for (final p in rows) _ProcRowData(p)];
  }

  /// 树模式:按 ppid 建树,DFS 展开(跳过折叠节点的子树)。
  /// 有搜索词时退化为平铺过滤(与 bottom 一致)。
  List<_ProcRowData> _treeRows() {
    if (_keyword.isNotEmpty) return _flatRows();
    final all = _all;
    final pids = {for (final p in all) p.pid};
    final byParent = <int, List<ProcInfo>>{};
    for (final p in all) {
      // 父进程不在列表里(或指向自身)的都算根。
      final parent = (p.ppid != p.pid && pids.contains(p.ppid)) ? p.ppid : -1;
      byParent.putIfAbsent(parent, () => []).add(p);
    }
    for (final children in byParent.values) {
      children.sort(_compare);
    }
    final rows = <_ProcRowData>[];
    void walk(int parent, int depth) {
      for (final p in byParent[parent] ?? const <ProcInfo>[]) {
        final hasChildren = byParent.containsKey(p.pid);
        final collapsed = _collapsed.contains(p.pid);
        rows.add(
          _ProcRowData(
            p,
            depth: depth,
            hasChildren: hasChildren,
            collapsed: collapsed,
          ),
        );
        if (hasChildren && !collapsed) walk(p.pid, depth + 1);
      }
    }

    walk(-1, 0);
    return rows;
  }

  List<_ProcGroup> _groupRows() {
    final byName = <String, List<ProcInfo>>{};
    for (final p in _all) {
      if (_matches(p)) byName.putIfAbsent(p.name, () => []).add(p);
    }
    final groups = [
      for (final e in byName.entries)
        _ProcGroup(
          name: e.key,
          count: e.value.length,
          cpuPercent: e.value.fold(0.0, (a, p) => a + p.cpuPercent),
          memPercent: e.value.fold(0.0, (a, p) => a + p.memPercent),
          rssBytes: e.value.fold(0, (a, p) => a + p.rssBytes),
          pids: [for (final p in e.value) p.pid],
        ),
    ];
    groups.sort((a, b) {
      final cmp = switch (_sort) {
        _ProcSort.cpu => a.cpuPercent.compareTo(b.cpuPercent),
        _ProcSort.mem => a.rssBytes.compareTo(b.rssBytes),
        // 聚合模式下 PID 列显示的是进程数,排序也按它来。
        _ProcSort.pid || _ProcSort.io => a.count.compareTo(b.count),
        _ProcSort.name || _ProcSort.user => a.name.toLowerCase().compareTo(
          b.name.toLowerCase(),
        ),
      };
      return _ascending ? cmp : -cmp;
    });
    return groups;
  }

  // ------------------------------------------------------------ 操作

  void _tapHeader(_ProcSort column) {
    setState(() {
      if (_sort == column) {
        _ascending = !_ascending;
      } else {
        _sort = column;
        // 数值列默认降序(大的在前),文本列默认升序。
        _ascending = column == _ProcSort.name || column == _ProcSort.user;
      }
    });
  }

  Future<void> _kill(ProcInfo proc, {required bool force}) async {
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: false,
      builder: (context) => AlertDialog(
        title: Text(force ? tr('强制结束进程?') : tr('结束进程?')),
        content: Text(
          '${proc.name} (PID ${proc.pid})\n${force ? tr('SIGKILL 无法被进程拦截,未保存数据会丢失。') : tr('向进程发送 SIGTERM,允许其清理后退出。')}',
          style: const TextStyle(fontSize: 12.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(tr('取消')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: force ? AppTheme.errorColor : null,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(force ? tr('强制结束') : tr('结束')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final ok = await ref
        .read(monitorControllerProvider.notifier)
        .killProcess(proc.pid, force: force);
    _feedback(
      ok,
      okText: tr2('已向 {0} 发送结束信号', [proc.name]),
      failText: tr2('结束 {0} 失败(权限不足?)', [proc.name]),
    );
  }

  /// 信号菜单直接发送(STOP/CONT 等非致命信号不弹确认,与 bottom 一致)。
  Future<void> _sendSignal(ProcInfo proc, String signal) async {
    final ok = await ref
        .read(monitorControllerProvider.notifier)
        .sendSignal(proc.pid, signal);
    _feedback(
      ok,
      okText: tr2('已向 {0} 发送 SIG{1}', [proc.name, signal]),
      failText: tr2('向 {0} 发送 SIG{1} 失败(权限不足?)', [proc.name, signal]),
    );
  }

  void _feedback(bool ok, {required String okText, required String failText}) {
    if (!mounted) return;
    AppToast.show(
      context: context,
      style: ToastificationStyle.flat,
      applyBlurEffect: true,
      type: ok ? ToastificationType.success : ToastificationType.error,
      autoCloseDuration: const Duration(seconds: 4),
      title: Text(
        ok ? okText : failText,
        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w400),
      ),
    );
  }

  // ------------------------------------------------------------ 构建

  @override
  Widget build(BuildContext context) {
    final total = _all.length;
    final hasUser = _all.any((p) => p.user.isNotEmpty);
    final hasIo = _all.any((p) => p.readRate != null || p.writeRate != null);

    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 560;
        final showIo = hasIo && constraints.maxWidth >= 760;
        final showUser = hasUser && constraints.maxWidth >= 580;
        final showPid = constraints.maxWidth >= 460;

        final grouped = _mode == _ViewMode.group;
        final minWidth = grouped
            ? 410.0
            : 398.0 +
                (showPid ? 76.0 : 0.0) +
                (showUser ? 90.0 : 0.0) +
                (showIo ? 128.0 : 0.0);

        Widget content = Column(
          children: [
            _headerRow(showPid, showUser, showIo),
            Divider(height: 1, color: AppTheme.borderColor),
            Expanded(
              child: _buildBody(total, showPid, showUser, showIo),
            ),
          ],
        );

        if (constraints.maxWidth < minWidth) {
          content = SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: minWidth,
              child: content,
            ),
          );
        }

        final trailing = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ModeSwitch(
              mode: _mode,
              onChanged: (m) => setState(() => _mode = m),
            ),
            if (!narrow) ...[
              const SizedBox(width: 10),
              PanelCaption(tr2('共 {0} 个', [total])),
            ],
            const SizedBox(width: 10),
            SizedBox(
              width: narrow ? 130 : 180,
              height: 26,
              child: TextField(
                onChanged: (v) => setState(() => _filter = v),
                style: TextStyle(fontSize: 11.5, color: AppTheme.headingColor),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: tr('搜索名称 / 用户 / PID'),
                  hintStyle: TextStyle(
                    fontSize: 11,
                    color: AppTheme.subtleTextColor,
                  ),
                  prefixIcon: Icon(
                    LucideIcons.search,
                    size: 13,
                    color: AppTheme.subtleTextColor,
                  ),
                  prefixIconConstraints: const BoxConstraints(
                    minWidth: 28,
                    minHeight: 26,
                  ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 4),
                  filled: true,
                  fillColor: AppTheme.mutedSurfaceColor,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
          ],
        );

        return MonitorPanel(
          icon: LucideIcons.listTree,
          title: tr('进程'),
          maximized: widget.expanded,
          onToggleMaximize: widget.onToggleMaximize,
          stretch: widget.expanded,
          trailing: trailing,
          child: widget.expanded ? content : SizedBox(height: 380, child: content),
        );
      },
    );
  }

  Widget _buildBody(int total, bool showPid, bool showUser, bool showIo) {
    if (_mode == _ViewMode.group) {
      final groups = _groupRows();
      if (groups.isEmpty) return _emptyBody(total);
      return ListView.builder(
        itemCount: groups.length,
        itemExtent: 26,
        itemBuilder: (context, i) => _GroupRow(
          group: groups[i],
          hasUser: showUser,
          even: i.isEven,
        ),
      );
    }

    final rows = _mode == _ViewMode.tree ? _treeRows() : _flatRows();
    if (rows.isEmpty) return _emptyBody(total);
    return ListView.builder(
      itemCount: rows.length,
      itemExtent: 26,
      itemBuilder: (context, i) => _ProcRow(
        row: rows[i],
        showPid: showPid,
        showUser: showUser,
        showIo: showIo,
        even: i.isEven,
        onKill: (force) => _kill(rows[i].proc, force: force),
        onSignal: (signal) => _sendSignal(rows[i].proc, signal),
        onToggle: rows[i].hasChildren
            ? () => setState(() {
                _collapsed.contains(rows[i].proc.pid)
                    ? _collapsed.remove(rows[i].proc.pid)
                    : _collapsed.add(rows[i].proc.pid);
              })
            : null,
      ),
    );
  }

  Widget _emptyBody(int total) {
    return Center(
      child: Text(
        total == 0 ? tr('等待采样…') : tr('无匹配进程'),
        style: TextStyle(fontSize: 11.5, color: AppTheme.subtleTextColor),
      ),
    );
  }

  Widget _headerRow(bool showPid, bool showUser, bool showIo) {
    Widget cell(
      String label,
      _ProcSort? column, {
      int flex = 0,
      double? width,
      bool numeric = false,
    }) {
      final active = column != null && _sort == column;
      final child = InkWell(
        onTap: column == null ? null : () => _tapHeader(column),
        child: Row(
          mainAxisAlignment: numeric
              ? MainAxisAlignment.end
              : MainAxisAlignment.start,
          children: [
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.clip,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: active
                      ? AppTheme.brandColor
                      : AppTheme.subtleTextColor,
                ),
              ),
            ),
            if (active)
              Icon(
                _ascending ? LucideIcons.chevronUp : LucideIcons.chevronDown,
                size: 11,
                color: AppTheme.brandColor,
              ),
          ],
        ),
      );
      if (width != null) return SizedBox(width: width, child: child);
      return Expanded(flex: flex, child: child);
    }

    final grouped = _mode == _ViewMode.group;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          if (grouped || showPid) ...[
            cell(grouped ? tr('数量') : 'PID', _ProcSort.pid,
                width: 64, numeric: true),
            const SizedBox(width: 12),
          ],
          cell(tr('名称'), _ProcSort.name, flex: 1),
          if (showUser && !grouped) cell(tr('用户'), _ProcSort.user, width: 90),
          cell('CPU %', _ProcSort.cpu, width: 64, numeric: true),
          cell(tr('内存 %'), _ProcSort.mem, width: 64, numeric: true),
          cell(tr('内存'), null, width: 78, numeric: true),
          if (showIo && !grouped) ...[
            cell(tr('读/s'), _ProcSort.io, width: 64, numeric: true),
            cell(tr('写/s'), _ProcSort.io, width: 64, numeric: true),
          ],
          if (!grouped) cell(tr('状态'), null, width: 40, numeric: true),
          const SizedBox(width: 72),
        ],
      ),
    );
  }
}

/// 列表 / 树 / 聚合 三态切换。
class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({required this.mode, required this.onChanged});

  final _ViewMode mode;
  final ValueChanged<_ViewMode> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget item(_ViewMode m, IconData icon, String tooltip) {
      final selected = mode == m;
      return Tooltip(
        message: tooltip,
        child: InkWell(
          borderRadius: BorderRadius.circular(5),
          onTap: () => onChanged(m),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: selected ? AppTheme.softBrandColor : Colors.transparent,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Icon(
              icon,
              size: 13,
              color: selected ? AppTheme.brandColor : AppTheme.subtleTextColor,
            ),
          ),
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        item(_ViewMode.list, LucideIcons.list, tr('列表')),
        item(_ViewMode.tree, LucideIcons.listTree, tr('进程树')),
        item(_ViewMode.group, LucideIcons.layers, tr('按名称聚合')),
      ],
    );
  }
}

class _ProcRow extends StatefulWidget {
  const _ProcRow({
    required this.row,
    required this.showPid,
    required this.showUser,
    required this.showIo,
    required this.even,
    required this.onKill,
    required this.onSignal,
    this.onToggle,
  });

  final _ProcRowData row;
  final bool showPid;
  final bool showUser;
  final bool showIo;
  final bool even;
  final void Function(bool force) onKill;
  final void Function(String signal) onSignal;

  /// 树模式下折叠/展开子树;无子进程为 null。
  final VoidCallback? onToggle;

  @override
  State<_ProcRow> createState() => _ProcRowState();
}

class _ProcRowState extends State<_ProcRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.row.proc;
    final numStyle = TextStyle(
      fontSize: 11,
      color: AppTheme.bodyColor,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        color: _hovered
            ? AppTheme.softBrandColor
            : widget.even
            ? Colors.transparent
            : AppTheme.mutedSurfaceColor.withValues(alpha: 0.5),
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            if (widget.showPid) ...[
              SizedBox(
                width: 64,
                child: Text(
                  '${p.pid}',
                  textAlign: TextAlign.right,
                  style: numStyle,
                ),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Row(
                children: [
                  // 树缩进 + 折叠开关。
                  if (widget.row.depth > 0)
                    SizedBox(width: widget.row.depth * 14),
                  if (widget.onToggle != null)
                    InkWell(
                      onTap: widget.onToggle,
                      child: Icon(
                        widget.row.collapsed
                            ? LucideIcons.chevronRight
                            : LucideIcons.chevronDown,
                        size: 12,
                        color: AppTheme.subtleTextColor,
                      ),
                    )
                  else if (widget.row.depth > 0)
                    const SizedBox(width: 12),
                  Flexible(
                    child: Tooltip(
                      message: p.command,
                      waitDuration: const Duration(milliseconds: 600),
                      child: Text(
                        p.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: AppTheme.headingColor,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (widget.showUser)
              SizedBox(
                width: 90,
                child: Text(
                  p.user,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: AppTheme.subtleTextColor,
                  ),
                ),
              ),
            SizedBox(
              width: 64,
              child: Text(
                p.cpuPercent.toStringAsFixed(1),
                textAlign: TextAlign.right,
                style: p.cpuPercent >= 50
                    ? numStyle.copyWith(
                        color: AppTheme.warningColor,
                        fontWeight: FontWeight.w600,
                      )
                    : numStyle,
              ),
            ),
            SizedBox(
              width: 64,
              child: Text(
                p.memPercent.toStringAsFixed(1),
                textAlign: TextAlign.right,
                style: numStyle,
              ),
            ),
            SizedBox(
              width: 78,
              child: Text(
                fmtBytes(p.rssBytes),
                textAlign: TextAlign.right,
                style: numStyle,
              ),
            ),
            if (widget.showIo) ...[
              SizedBox(
                width: 64,
                child: Text(
                  p.readRate == null ? '—' : fmtBytes(p.readRate!),
                  textAlign: TextAlign.right,
                  style: numStyle,
                ),
              ),
              SizedBox(
                width: 64,
                child: Text(
                  p.writeRate == null ? '—' : fmtBytes(p.writeRate!),
                  textAlign: TextAlign.right,
                  style: numStyle,
                ),
              ),
            ],
            SizedBox(
              width: 40,
              child: Text(
                p.state,
                textAlign: TextAlign.right,
                style: numStyle.copyWith(
                  color: p.state == 'Z'
                      ? AppTheme.errorColor
                      : AppTheme.subtleTextColor,
                ),
              ),
            ),
            SizedBox(
              width: 72,
              child: _hovered
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (!Platform.isWindows) _signalMenu(),
                        _KillButton(
                          icon: LucideIcons.circleX,
                          tooltip: tr('结束进程'),
                          color: AppTheme.warningColor,
                          onTap: () => widget.onKill(false),
                        ),
                        _KillButton(
                          icon: LucideIcons.zap,
                          tooltip: tr('强制结束'),
                          color: AppTheme.errorColor,
                          onTap: () => widget.onKill(true),
                        ),
                      ],
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }

  /// 完整信号菜单(bottom 的 signal picker;STOP/CONT 可用来冻结/恢复)。
  Widget _signalMenu() {
    return PopupMenuButton<String>(
      tooltip: tr('发送信号'),
      padding: EdgeInsets.zero,
      position: PopupMenuPosition.under,
      onSelected: widget.onSignal,
      itemBuilder: (context) => [
        for (final s in kProcSignals)
          PopupMenuItem(
            value: s,
            height: 30,
            child: Text('SIG$s', style: const TextStyle(fontSize: 12)),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: Icon(
          LucideIcons.ellipsisVertical,
          size: 13,
          color: AppTheme.subtleTextColor,
        ),
      ),
    );
  }
}

/// 聚合模式的一行:数量 + 名称 + 汇总 CPU/内存。
class _GroupRow extends StatelessWidget {
  const _GroupRow({
    required this.group,
    required this.hasUser,
    required this.even,
  });

  final _ProcGroup group;
  final bool hasUser;
  final bool even;

  @override
  Widget build(BuildContext context) {
    final numStyle = TextStyle(
      fontSize: 11,
      color: AppTheme.bodyColor,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Container(
      color: even
          ? Colors.transparent
          : AppTheme.mutedSurfaceColor.withValues(alpha: 0.5),
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: Text(
              '×${group.count}',
              textAlign: TextAlign.right,
              style: numStyle.copyWith(color: AppTheme.subtleTextColor),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Tooltip(
              message: 'PID: ${group.pids.take(20).join(', ')}'
                  '${group.pids.length > 20 ? ' …' : ''}',
              waitDuration: const Duration(milliseconds: 600),
              child: Text(
                group.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: AppTheme.headingColor),
              ),
            ),
          ),
          SizedBox(
            width: 64,
            child: Text(
              group.cpuPercent.toStringAsFixed(1),
              textAlign: TextAlign.right,
              style: group.cpuPercent >= 50
                  ? numStyle.copyWith(
                      color: AppTheme.warningColor,
                      fontWeight: FontWeight.w600,
                    )
                  : numStyle,
            ),
          ),
          SizedBox(
            width: 64,
            child: Text(
              group.memPercent.toStringAsFixed(1),
              textAlign: TextAlign.right,
              style: numStyle,
            ),
          ),
          SizedBox(
            width: 78,
            child: Text(
              fmtBytes(group.rssBytes),
              textAlign: TextAlign.right,
              style: numStyle,
            ),
          ),
          const SizedBox(width: 72),
        ],
      ),
    );
  }
}

class _KillButton extends StatelessWidget {
  const _KillButton({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Icon(icon, size: 13, color: color),
        ),
      ),
    );
  }
}
