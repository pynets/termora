import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:termora/app/theme/app_theme.dart';
import 'package:termora/core/services/tray_service.dart';
import 'package:termora/features/database/controller/db_schedule_controller.dart';
import 'package:termora/core/services/workspace_store.dart';
import 'package:termora/features/database/view/database_page.dart';
import 'package:termora/features/notes/view/notes_page.dart';
import 'package:termora/features/remote/view/remote_page.dart';
import 'package:termora/features/settings/controller/app_update_controller.dart';
import 'package:termora/features/settings/controller/setting_providers.dart';
import 'package:termora/features/settings/view/settings_dialog.dart';
import 'package:termora/features/settings/view/update_dialog.dart';
import 'package:termora/features/terminal/view/terminal_page.dart';

/// 主界面外壳 — 左侧 NavigationRail 导航
/// 目前只有「终端」,后续在 _destinations 里追加数据库连接等入口即可
class MainShell extends ConsumerStatefulWidget {
  const MainShell({super.key});

  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell> {
  static const _updateCheckInterval = Duration(hours: 3);

  int _selectedIndex = 0;
  final _contentNavigatorKey = GlobalKey<NavigatorState>();
  late final Timer _updateCheckTimer;

  @override
  void initState() {
    super.initState();
    // 恢复上次停留的功能页
    WorkspaceStore.loadActiveFeature().then((index) {
      if (mounted && index >= 0 && index < 4) {
        setState(() => _selectedIndex = index);
      }
    });
    // 首帧后初始化托盘(常驻小羊图标 + 截屏快捷键)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      TrayService.instance.initialize();
      unawaited(
        ref.read(appUpdateControllerProvider.notifier).checkForUpdate(),
      );
    });
    _updateCheckTimer = Timer.periodic(_updateCheckInterval, (_) {
      unawaited(
        ref.read(appUpdateControllerProvider.notifier).checkForUpdate(),
      );
    });
  }

  @override
  void dispose() {
    _updateCheckTimer.cancel();
    super.dispose();
  }

  void _selectFeature(int index) {
    setState(() => _selectedIndex = index);
    WorkspaceStore.saveActiveFeature(index);
  }

  /// 手动检查更新:静默检查,已是最新给轻提示,发现新版本才弹更新小弹窗
  Future<void> _checkUpdateManually() async {
    final l10n = AppL10n.current;
    final messenger = ScaffoldMessenger.of(context);
    final notifier = ref.read(appUpdateControllerProvider.notifier);
    var state = ref.read(appUpdateControllerProvider);

    // 已经发现过新版本(启动/定时检查的结果),直接弹窗,不重复请求
    if (state.update == null) {
      if (state.isBusy) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(l10n.checkingForUpdates),
          duration: const Duration(seconds: 10),
        ),
      );
      await notifier.checkForUpdate();
      messenger.hideCurrentSnackBar();
      if (!mounted) return;
      state = ref.read(appUpdateControllerProvider);
    }

    if (state.update != null) {
      await showUpdateDialog(_contentNavigatorKey.currentContext ?? context);
    } else {
      messenger.showSnackBar(
        SnackBar(
          content: Text(l10n.upToDate),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // 监听主题/品牌色/多语言变化,保证侧栏配色即时刷新
    ref.watch(appThemeControllerProvider);
    ref.watch(appBrandColorControllerProvider);
    final updateState = ref.watch(appUpdateControllerProvider);
    final locale = ref.watch(appLocaleControllerProvider);
    final l10n = AppL10n.resolve(locale);
    AppL10n.current = l10n;

    // 常驻传输任务调度器(watch 一次即启动,随会话存活)
    ref.watch(dbScheduleControllerProvider);

    return Scaffold(
      backgroundColor: AppTheme.backgroundColor,
      body: Row(
        children: [
          _buildRail(l10n, updateState),
          VerticalDivider(width: 0.5, color: AppTheme.borderColor),
          Expanded(
            child: Navigator(
              key: _contentNavigatorKey,
              pages: [
                MaterialPage(
                  key: const ValueKey('main_shell_content'),
                  child: IndexedStack(
                    index: _selectedIndex,
                    children: const [
                      _FeatureHost(child: TerminalPage()),
                      _FeatureHost(child: RemotePage()),
                      _FeatureHost(child: DatabasePage()),
                      _FeatureHost(child: NotesPage()),
                    ],
                  ),
                ),
              ],
              onDidRemovePage: (page) {},
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRail(AppL10n l10n, AppUpdateState updateState) {
    final destinations = [
      (icon: LucideIcons.squareTerminal, label: l10n.terminal),
      (icon: LucideIcons.server, label: l10n.remote),
      (icon: LucideIcons.database, label: l10n.database),
      (icon: LucideIcons.notebookPen, label: l10n.notes),
    ];

    return Container(
      color: AppTheme.surfaceColor,
      child: NavigationRail(
        backgroundColor: Colors.transparent,
        selectedIndex: _selectedIndex,
        onDestinationSelected: _selectFeature,
        labelType: NavigationRailLabelType.all,
        minWidth: 68,
        indicatorColor: AppTheme.softBrandColor,
        selectedIconTheme: IconThemeData(color: AppTheme.brandColor, size: 20),
        unselectedIconTheme: IconThemeData(
          color: AppTheme.subtleTextColor,
          size: 20,
        ),
        selectedLabelTextStyle: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: AppTheme.brandColor,
        ),
        unselectedLabelTextStyle: TextStyle(
          fontSize: 11,
          color: AppTheme.subtleTextColor,
        ),
        leading: const SizedBox(height: 8),
        trailing: Expanded(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: updateState.update == null
                        ? l10n.checkForUpdates
                        : l10n.updateAvailable(updateState.update!.tagName),
                    icon: Icon(
                      LucideIcons.circleArrowUp300,
                      size: 18,
                      color: updateState.update == null
                          ? AppTheme.subtleTextColor
                          : AppTheme.brandColor,
                    ),
                    onPressed: _checkUpdateManually,
                  ),
                  IconButton(
                    tooltip: l10n.settings,
                    icon: Icon(
                      LucideIcons.settings,
                      size: 18,
                      color: AppTheme.subtleTextColor,
                    ),
                    onPressed: () => showSettingsDialog(
                      _contentNavigatorKey.currentContext ?? context,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        destinations: [
          for (final d in destinations)
            NavigationRailDestination(icon: Icon(d.icon), label: Text(d.label)),
        ],
      ),
    );
  }
}

/// 每个功能页包一层独立 Navigator —— 该页弹出的对话框(useRootNavigator: false)
/// 会挂在自己这层 Navigator 上,于是:
/// ① 遮罩只覆盖内容区,不盖左侧导航栏;
/// ② 切到别的功能页时,对话框随 IndexedStack 一起隐藏(不再悬浮残留到别的页);
/// ③ 切回本页时对话框依旧在(IndexedStack 保活整棵子树 + 路由状态)。
class _FeatureHost extends StatelessWidget {
  const _FeatureHost({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Navigator(
      // 单一根路由 = 功能页本身;无进出场动画(它不是被“推入”的页面)。
      onGenerateRoute: (settings) => PageRouteBuilder(
        settings: settings,
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (context, animation, secondaryAnimation) => child,
      ),
    );
  }
}
