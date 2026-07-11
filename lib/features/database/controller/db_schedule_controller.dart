import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:toastification/toastification.dart';

import 'package:termora/app/theme/app_theme.dart';
import 'package:termora/core/l10n/app_l10n.dart';
import 'package:termora/core/widgets/app_toast.dart';
import 'package:termora/features/database/controller/database_providers.dart';
import 'package:termora/features/database/domain/db_transfer_task.dart';
import 'package:termora/main.dart' show rootNavigatorKey;

/// 传输任务定时调度器。应用打开期间常驻(托盘应用)——每 [_tickInterval]
/// 扫描一次已保存任务,到期(interval/dailyAt)且未在运行的任务无头执行,
/// 完成/失败弹 toast 并回写 lastRun(下次到期据此重算)。
///
/// 用 tick 轮询而非每任务定时器:实现简单、对增删改天然鲁棒;
/// 30s 精度对备份/同步这类任务完全够用。
class DbScheduleController extends Notifier<int> {
  Timer? _timer;
  final Set<String> _running = {};

  static const _tickInterval = Duration(seconds: 30);

  @override
  int build() {
    ref.onDispose(() {
      _timer?.cancel();
      _timer = null;
    });
    _timer ??= Timer.periodic(_tickInterval, (_) => _tick());
    return 0;
  }

  Future<void> _tick() async {
    // 连接还没加载出来时不跑,避免把"连接不存在"记成失败、误顺延日程
    if (ref.read(dbConnectionsProvider).isEmpty) return;

    final tasks = ref.read(dbTransferTasksProvider);
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final task in tasks) {
      if (!task.schedule.isActive) continue;
      if (_running.contains(task.id)) continue;
      final due = task.schedule.nextRunMs(task.lastRunAtMs, now);
      if (due == null || due > now) continue;

      _running.add(task.id);
      state = state + 1;
      unawaited(
        _runScheduled(task).whenComplete(() => _running.remove(task.id)),
      );
    }
  }

  Future<void> _runScheduled(DbTransferTask task) async {
    final name = task.name;
    try {
      final summary = await ref
          .read(dbTransferTasksProvider.notifier)
          .run(task);
      final detail = summary.statements > 0
          ? tr2('已执行 {0} 条语句', [summary.statements])
          : tr2('{0} 张表 / {1} 行', [summary.tables, summary.rows]);
      _toast(tr2('定时任务「{0}」完成', [name]), detail, ok: true);
    } catch (e) {
      _toast(tr2('定时任务「{0}」失败', [name]), '$e', ok: false);
      debugPrint('[DB schedule] task "$name" failed: $e');
    }
  }

  void _toast(String title, String detail, {required bool ok}) {
    final context = rootNavigatorKey.currentContext;
    if (context == null) return;
    AppToast.show(
      context: context,
      type: ok ? ToastificationType.success : ToastificationType.error,
      style: ToastificationStyle.flatColored,
      autoCloseDuration: Duration(seconds: ok ? 4 : 8),
      alignment: Alignment.bottomRight,
      icon: Icon(
        ok ? LucideIcons.circleCheck : LucideIcons.circleX,
        size: 18,
      ),
      title: Text(
        title,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      description: Text(
        detail,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11.5, color: AppTheme.subtleTextColor),
      ),
    );
  }
}

/// 常驻调度器 provider —— 在 MainShell 里 watch 一次即启动,随会话存活。
final dbScheduleControllerProvider =
    NotifierProvider<DbScheduleController, int>(DbScheduleController.new);
