import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:termora/app/theme/app_theme.dart';
import 'package:termora/core/services/tray_service.dart';
import 'package:termora/core/services/workspace_store.dart';
import 'package:termora/features/database/view/database_page.dart';
import 'package:termora/features/notes/view/notes_page.dart';
import 'package:termora/features/remote/view/remote_page.dart';
import 'package:termora/features/settings/controller/app_update_controller.dart';
import 'package:termora/features/settings/controller/setting_providers.dart';
import 'package:termora/features/settings/view/settings_dialog.dart';
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

  @override
  Widget build(BuildContext context) {
    // 监听主题/品牌色/多语言变化,保证侧栏配色即时刷新
    ref.watch(appThemeControllerProvider);
    ref.watch(appBrandColorControllerProvider);
    final updateState = ref.watch(appUpdateControllerProvider);
    final locale = ref.watch(appLocaleControllerProvider);
    final l10n = AppL10n.resolve(locale);
    AppL10n.current = l10n;

    return Scaffold(
      backgroundColor: AppTheme.backgroundColor,
      body: Row(
        children: [
          _buildRail(l10n, updateState),
          VerticalDivider(width: 0.5, color: AppTheme.borderColor),
          Expanded(
            child: IndexedStack(
              index: _selectedIndex,
              // ignore: prefer_const_constructors
              children: [
                TerminalPage(),
                RemotePage(),
                DatabasePage(),
                NotesPage(),
              ],
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
                    onPressed: () => showSettingsDialog(context),
                  ),
                  IconButton(
                    tooltip: l10n.settings,
                    icon: Icon(
                      LucideIcons.settings,
                      size: 18,
                      color: AppTheme.subtleTextColor,
                    ),
                    onPressed: () => showSettingsDialog(context),
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
