import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:termora/app/theme/app_theme.dart';
import 'package:termora/core/l10n/app_l10n.dart';
import 'package:termora/features/database/controller/database_providers.dart';
import 'package:termora/features/database/data/db_transfer_service.dart';
import 'package:termora/features/database/domain/db_transfer_task.dart';
import 'package:termora/features/database/view/widgets/copyable_error_box.dart';

/// 打开「传输任务」管理器 — 列出已保存任务,支持运行 / 调度 / 删除。
Future<void> showTransferTasksDialog(BuildContext context) {
  return showDialog(
    context: context,
    useRootNavigator: false,
    barrierColor: Colors.black.withValues(alpha: 0.3),
    builder: (context) => const _TransferTasksDialog(),
  );
}

({IconData icon, String label}) _modeMeta(DbTransferMode mode) =>
    switch (mode) {
      DbTransferMode.export => (icon: LucideIcons.fileDown, label: '导出'),
      DbTransferMode.importScript => (icon: LucideIcons.fileUp, label: '导入'),
      DbTransferMode.exportDump => (icon: LucideIcons.package, label: '归档'),
      DbTransferMode.importDump => (icon: LucideIcons.packageOpen, label: '还原'),
      DbTransferMode.migrate => (icon: LucideIcons.arrowRightLeft, label: '迁移'),
    };

String _fmtTime(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

class _TransferTasksDialog extends ConsumerWidget {
  const _TransferTasksDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(dbTransferTasksProvider);
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    LucideIcons.listChecks,
                    size: 17,
                    color: AppTheme.brandColor,
                  ),
                  const SizedBox(width: 9),
                  Text(
                    tr('传输任务'),
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.headingColor,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${tasks.length}',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppTheme.subtleTextColor,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              if (tasks.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 34),
                  child: Center(
                    child: Column(
                      children: [
                        Icon(
                          LucideIcons.bookmark,
                          size: 26,
                          color: AppTheme.subtleTextColor.withValues(
                            alpha: 0.5,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          tr('还没有任务'),
                          style: TextStyle(
                            fontSize: 13,
                            color: AppTheme.bodyColor,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          tr('在导出/导入/迁移向导里点「保存为任务」即可添加'),
                          style: TextStyle(
                            fontSize: 11.5,
                            color: AppTheme.subtleTextColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              else
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: tasks.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) => _TaskCard(task: tasks[i]),
                  ),
                ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(tr('关闭')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TaskCard extends ConsumerWidget {
  const _TaskCard({required this.task});

  final DbTransferTask task;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meta = _modeMeta(task.mode);
    final scope = task.wholeDatabase
        ? tr('整库')
        : (task.schema ?? '${task.tables.length} ${tr('张表')}');
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: AppTheme.mutedSurfaceColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(meta.icon, size: 15, color: AppTheme.brandColor),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  task.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.headingColor,
                  ),
                ),
              ),
              if (task.schedule.isActive)
                Container(
                  margin: const EdgeInsets.only(right: 4),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.brandColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        LucideIcons.clock,
                        size: 10,
                        color: AppTheme.brandColor,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        tr(task.schedule.summary),
                        style: TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.brandColor,
                        ),
                      ),
                    ],
                  ),
                ),
              _iconBtn(
                LucideIcons.play,
                tr('运行'),
                () => showTaskRunner(context, task),
              ),
              _iconBtn(
                LucideIcons.clock,
                tr('调度'),
                () => _editSchedule(context, ref),
              ),
              _iconBtn(
                LucideIcons.trash2,
                tr('删除'),
                () =>
                    ref.read(dbTransferTasksProvider.notifier).remove(task.id),
                color: AppTheme.errorColor,
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 23, top: 2),
            child: Text(
              '${tr(meta.label)} · $scope',
              style: TextStyle(fontSize: 11, color: AppTheme.subtleTextColor),
            ),
          ),
          if (task.lastRunAtMs != null)
            Padding(
              padding: const EdgeInsets.only(left: 23, top: 3),
              child: Row(
                children: [
                  Icon(
                    task.lastRunOk == true
                        ? LucideIcons.circleCheck
                        : LucideIcons.circleX,
                    size: 11,
                    color: task.lastRunOk == true
                        ? AppTheme.successColor
                        : AppTheme.errorColor,
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      '${_fmtTime(task.lastRunAtMs!)} · ${task.lastRunMessage ?? ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: AppTheme.subtleTextColor,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _iconBtn(
    IconData icon,
    String tip,
    VoidCallback onTap, {
    Color? color,
  }) => IconButton(
    tooltip: tip,
    visualDensity: VisualDensity.compact,
    constraints: const BoxConstraints(),
    padding: const EdgeInsets.all(5),
    icon: Icon(icon, size: 14, color: color ?? AppTheme.subtleTextColor),
    onPressed: onTap,
  );

  Future<void> _editSchedule(BuildContext context, WidgetRef ref) async {
    final schedule = await showScheduleEditor(context, task.schedule);
    if (schedule == null) return;
    await ref
        .read(dbTransferTasksProvider.notifier)
        .upsert(task.copyWith(schedule: schedule));
  }
}

// ══════════════ 运行器(进度 + 日志)══════════════

/// 运行一个已保存任务,展示进度与日志。
Future<void> showTaskRunner(BuildContext context, DbTransferTask task) {
  return showDialog(
    context: context,
    useRootNavigator: false,
    barrierColor: Colors.black.withValues(alpha: 0.3),
    barrierDismissible: false,
    builder: (context) => _TaskRunnerDialog(task: task),
  );
}

class _TaskRunnerDialog extends ConsumerStatefulWidget {
  const _TaskRunnerDialog({required this.task});

  final DbTransferTask task;

  @override
  ConsumerState<_TaskRunnerDialog> createState() => _TaskRunnerDialogState();
}

class _TaskRunnerDialogState extends ConsumerState<_TaskRunnerDialog> {
  bool _running = false;
  bool _cancelRequested = false;
  bool _done = false;
  double? _progress;
  String? _error;
  final List<String> _log = [];
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _append(DbTransferProgress p) {
    if (!mounted) return;
    setState(() {
      _log.add(p.message);
      if (_log.length > 500) _log.removeRange(0, _log.length - 400);
      _progress = p.total > 0 ? p.done / p.total : null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _run() async {
    setState(() {
      _running = true;
      _cancelRequested = false;
      _done = false;
      _error = null;
      _progress = null;
      _log.clear();
    });
    try {
      final summary = await ref
          .read(dbTransferTasksProvider.notifier)
          .run(
            widget.task,
            onProgress: _append,
            isCancelled: () => _cancelRequested,
          );
      if (!mounted) return;
      setState(() {
        _running = false;
        _done = true;
        _progress = 1;
        _log.add(
          widget.task.mode == DbTransferMode.importScript
              ? tr2('完成:已执行 {0} 条语句', [summary.statements])
              : tr2('完成:{0} 张表 / {1} 行', [summary.tables, summary.rows]),
        );
      });
    } on DbTransferCancelledException {
      if (!mounted) return;
      setState(() {
        _running = false;
        _log.add(tr('已取消'));
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    _modeMeta(widget.task.mode).icon,
                    size: 16,
                    color: AppTheme.brandColor,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.task.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.headingColor,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              LinearProgressIndicator(
                value: _progress,
                minHeight: 3,
                borderRadius: BorderRadius.circular(2),
              ),
              const SizedBox(height: 8),
              Container(
                height: 130,
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppTheme.mutedSurfaceColor,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.borderColor),
                ),
                child: SelectionArea(
                  child: ListView.builder(
                    controller: _scroll,
                    itemCount: _log.length,
                    itemBuilder: (context, i) => Text(
                      _log[i],
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'Menlo',
                        color: AppTheme.bodyColor,
                      ),
                    ),
                  ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                CopyableErrorBox(text: _error!),
              ],
              const SizedBox(height: 14),
              Row(
                children: [
                  if (_running)
                    TextButton.icon(
                      onPressed: _cancelRequested
                          ? null
                          : () => setState(() => _cancelRequested = true),
                      icon: const Icon(LucideIcons.circleStop, size: 14),
                      label: Text(tr('停止')),
                    ),
                  const Spacer(),
                  TextButton(
                    onPressed: _running
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: Text(tr('关闭')),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _running ? null : _run,
                    icon: const Icon(LucideIcons.rotateCcw, size: 14),
                    label: Text(
                      _done || _error != null ? tr('再次运行') : tr('运行'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ══════════════ 调度编辑 ══════════════

/// 编辑任务调度设置。返回新设置(取消返回 null)。
Future<DbTransferSchedule?> showScheduleEditor(
  BuildContext context,
  DbTransferSchedule current,
) {
  return showDialog<DbTransferSchedule>(
    context: context,
    useRootNavigator: false,
    barrierColor: Colors.black.withValues(alpha: 0.3),
    builder: (context) => _ScheduleEditor(current: current),
  );
}

class _ScheduleEditor extends StatefulWidget {
  const _ScheduleEditor({required this.current});

  final DbTransferSchedule current;

  @override
  State<_ScheduleEditor> createState() => _ScheduleEditorState();
}

class _ScheduleEditorState extends State<_ScheduleEditor> {
  late DbScheduleKind _kind = widget.current.kind;
  late final TextEditingController _interval = TextEditingController(
    text: '${widget.current.intervalMinutes}',
  );
  late int _hour = widget.current.dailyHour;
  late int _minute = widget.current.dailyMinute;

  @override
  void dispose() {
    _interval.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Icon(LucideIcons.clock, size: 16, color: AppTheme.brandColor),
          const SizedBox(width: 8),
          Text(tr('调度')),
        ],
      ),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _radio(DbScheduleKind.manual, tr('手动(不自动运行)')),
            _radio(DbScheduleKind.interval, tr('按间隔')),
            if (_kind == DbScheduleKind.interval)
              Padding(
                padding: const EdgeInsets.only(left: 28, bottom: 4),
                child: Row(
                  children: [
                    SizedBox(
                      width: 70,
                      child: TextField(
                        controller: _interval,
                        keyboardType: TextInputType.number,
                        style: const TextStyle(fontSize: 13),
                        decoration: const InputDecoration(isDense: true),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      tr('分钟一次'),
                      style: TextStyle(fontSize: 12, color: AppTheme.bodyColor),
                    ),
                  ],
                ),
              ),
            _radio(DbScheduleKind.dailyAt, tr('每天定点')),
            if (_kind == DbScheduleKind.dailyAt)
              Padding(
                padding: const EdgeInsets.only(left: 28),
                child: Row(
                  children: [
                    _spin(_hour, 23, (v) => setState(() => _hour = v), tr('时')),
                    const SizedBox(width: 12),
                    _spin(
                      _minute,
                      59,
                      (v) => setState(() => _minute = v),
                      tr('分'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('取消')),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(context).pop(
              DbTransferSchedule(
                kind: _kind,
                intervalMinutes:
                    int.tryParse(_interval.text.trim())?.clamp(1, 100000) ?? 60,
                dailyHour: _hour,
                dailyMinute: _minute,
              ),
            );
          },
          child: Text(tr('保存')),
        ),
      ],
    );
  }

  Widget _radio(DbScheduleKind kind, String label) => InkWell(
    onTap: () => setState(() => _kind = kind),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            _kind == kind ? LucideIcons.circleDot : LucideIcons.circle,
            size: 15,
            color: _kind == kind
                ? AppTheme.brandColor
                : AppTheme.subtleTextColor,
          ),
          const SizedBox(width: 10),
          Text(
            label,
            style: TextStyle(fontSize: 13, color: AppTheme.bodyColor),
          ),
        ],
      ),
    ),
  );

  Widget _spin(int value, int max, ValueChanged<int> onChanged, String unit) {
    return Row(
      children: [
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(LucideIcons.minus, size: 13),
          onPressed: () => onChanged((value - 1).clamp(0, max)),
        ),
        Text(
          value.toString().padLeft(2, '0'),
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: AppTheme.headingColor,
          ),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(LucideIcons.plus, size: 13),
          onPressed: () => onChanged((value + 1).clamp(0, max)),
        ),
        Text(unit, style: TextStyle(fontSize: 12, color: AppTheme.bodyColor)),
      ],
    );
  }
}
