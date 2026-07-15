import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:termora/app/theme/app_theme.dart';
import 'package:termora/core/services/tray_service.dart';
import 'package:termora/features/database/controller/db_schedule_controller.dart';
import 'package:termora/core/services/workspace_store.dart';
import 'package:termora/features/database/view/database_page.dart';
import 'package:termora/features/monitor/view/monitor_page.dart';
import 'package:termora/features/notes/view/notes_page.dart';
import 'package:termora/features/remote/view/remote_page.dart';
import 'package:termora/features/settings/controller/app_update_controller.dart';
import 'package:termora/features/settings/controller/setting_providers.dart';
import 'package:termora/features/settings/view/settings_dialog.dart';
import 'package:termora/features/settings/view/update_dialog.dart';
import 'package:termora/app/shell/window_top_bar.dart';
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

  // 侧栏可拖拽宽度:min=纯图标,max=图标+宽标签
  static const _railMinWidth = 60.0;
  static const _railMaxWidth = 200.0;
  static const _railDefaultWidth = 76.0;

  int _selectedIndex = 0;
  double _railWidth = _railDefaultWidth;
  final _contentNavigatorKey = GlobalKey<NavigatorState>();
  late final Timer _updateCheckTimer;

  @override
  void initState() {
    super.initState();
    // 恢复上次停留的功能页
    WorkspaceStore.loadActiveFeature().then((index) {
      if (mounted && index >= 0 && index < 5) {
        setState(() => _selectedIndex = index);
      }
    });
    // 恢复上次的侧栏宽度
    WorkspaceStore.loadRailWidth().then((width) {
      if (mounted && width != null) {
        setState(
          () => _railWidth = width.clamp(_railMinWidth, _railMaxWidth),
        );
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
      // 背景与侧栏 rail 同为 surfaceColor:内容卡片顶左圆角外露处不再露出
      // 异色三角(消除色差),侧栏与内容之间也不再需要竖分隔线。
      backgroundColor: AppTheme.surfaceColor,
      // 参考 superdesk 一体化布局:侧栏 + 内容卡片各自铺到顶,内容整体下移
      // kWindowTitleBarHeight,顶部叠一条透明可拖动区(红绿灯浮于其上),
      // 内容卡片顶左圆角贴住右上,把右侧完整让给内容区。
      body: Stack(
        children: [
          Row(
            children: [
              _buildRail(l10n, updateState),
              _buildRailResizer(),
              Expanded(
                // 内容区顶满上边:页面自绘顶栏直达顶部。顶部透明拖动条为
                // translucent 命中,单击穿透到页面按钮,空白处仍可拖动窗口
                // (与原生 macOS 工具栏一致)。顶左圆角只做卡片收边。
                child: ClipRRect(
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(14),
                  ),
                  child: Navigator(
                    key: _contentNavigatorKey,
                    pages: [
                      MaterialPage(
                        key: const ValueKey('main_shell_content'),
                        child: IndexedStack(
                          index: _selectedIndex,
                          // IndexedStack 的 Visibility(maintainAnimation: true)
                          // 不带 TickerMode:隐藏页的循环动画会一直以满帧率
                          // 驱动整窗重绘(实测 ~115fps、20%+ CPU)。这里显式
                          // 按选中态包 TickerMode,切走的页动画/采样全部停摆。
                          children: [
                            for (final (i, page) in const <Widget>[
                              _FeatureHost(child: TerminalPage()),
                              _FeatureHost(child: RemotePage()),
                              _FeatureHost(child: DatabasePage()),
                              _FeatureHost(child: NotesPage()),
                              _FeatureHost(child: MonitorPage()),
                            ].indexed)
                              TickerMode(
                                enabled: i == _selectedIndex,
                                child: page,
                              ),
                          ],
                        ),
                      ),
                    ],
                    onDidRemovePage: (page) {},
                  ),
                ),
              ),
            ],
          ),
          // 顶部透明拖动条(铺满,含侧栏上方红绿灯区)
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: WindowDragArea(),
          ),
          // 非 macOS:自绘窗口控件叠在右上角
          if (!Platform.isMacOS)
            const Positioned(top: 0, right: 0, child: WindowCaptionButtons()),
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
      (icon: LucideIcons.activity, label: l10n.monitor),
    ];

    return SizedBox(
      width: _railWidth,
      child: Container(
      color: AppTheme.surfaceColor,
      child: NavigationRail(
        backgroundColor: Colors.transparent,
        selectedIndex: _selectedIndex,
        onDestinationSelected: _selectFeature,
        labelType: NavigationRailLabelType.all,
        minWidth: _railMinWidth,
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
        // 顶部留出标题栏高度:让首个导航图标避开浮在左上的红绿灯
        leading: const SizedBox(height: kWindowTitleBarHeight + 8),
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
      ),
    );
  }

  /// 侧栏右缘拖拽条:拖动实时改宽,松手落库
  Widget _buildRailResizer() {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (details) {
          setState(() {
            _railWidth = (_railWidth + details.delta.dx).clamp(
              _railMinWidth,
              _railMaxWidth,
            );
          });
        },
        onHorizontalDragEnd: (_) => WorkspaceStore.saveRailWidth(_railWidth),
        child: const SizedBox(width: 6, height: double.infinity),
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
