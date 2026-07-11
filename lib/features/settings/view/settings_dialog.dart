import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:termora/app/theme/app_theme.dart';
import 'package:termora/core/app_version.dart';
import 'package:termora/features/settings/controller/app_update_controller.dart';
import 'package:termora/features/settings/controller/setting_providers.dart';

/// 打开设置弹窗
Future<void> showSettingsDialog(BuildContext context) {
  return showDialog(
    context: context,
    useRootNavigator: false,
    barrierColor: Colors.black.withValues(alpha: 0.3),
    builder: (context) => const SettingsDialog(),
  );
}

/// 设置分区 — 参考 superdesk 的「左侧分区导航 + 右侧内容面板」布局
enum _SettingsSection { general, appearance, about }

/// 设置弹窗 — 左侧分区导航,右侧对应设置面板,与 superdesk 同一套配色体系
class SettingsDialog extends ConsumerStatefulWidget {
  const SettingsDialog({super.key});

  @override
  ConsumerState<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends ConsumerState<SettingsDialog> {
  _SettingsSection _section = _SettingsSection.general;

  String _sectionLabel(_SettingsSection section, AppL10n l10n) {
    return switch (section) {
      _SettingsSection.general => l10n.settingsGeneral,
      _SettingsSection.appearance => l10n.settingsAppearance,
      _SettingsSection.about => l10n.settingsAbout,
    };
  }

  IconData _sectionIcon(_SettingsSection section) {
    return switch (section) {
      _SettingsSection.general => LucideIcons.settings2,
      _SettingsSection.appearance => LucideIcons.palette,
      _SettingsSection.about => LucideIcons.info,
    };
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appThemeControllerProvider);
    ref.watch(appBrandColorControllerProvider);
    final locale = ref.watch(appLocaleControllerProvider);
    final l10n = AppL10n.resolve(locale);
    final size = MediaQuery.sizeOf(context);
    final dialogHeight = math.min(520.0, size.height * 0.85);

    return Dialog(
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 700,
        height: dialogHeight,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildSidebar(l10n),
            VerticalDivider(width: 0.5, color: AppTheme.borderColor),
            Expanded(child: _buildContent(l10n)),
          ],
        ),
      ),
    );
  }

  Widget _buildSidebar(AppL10n l10n) {
    return Container(
      width: 168,
      color: AppTheme.mutedSurfaceColor,
      padding: const EdgeInsets.fromLTRB(10, 14, 10, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Text(
              l10n.settings,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
                color: AppTheme.subtleTextColor,
              ),
            ),
          ),
          for (final section in _SettingsSection.values) ...[
            _SettingsNavItem(
              icon: _sectionIcon(section),
              label: _sectionLabel(section, l10n),
              isSelected: _section == section,
              onTap: () => setState(() => _section = section),
            ),
            const SizedBox(height: 4),
          ],
        ],
      ),
    );
  }

  Widget _buildContent(AppL10n l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 14, 12, 0),
          child: Row(
            children: [
              Icon(_sectionIcon(_section), size: 16, color: AppTheme.brandColor),
              const SizedBox(width: 8),
              Text(
                _sectionLabel(_section, l10n),
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.headingColor,
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: l10n.close,
                icon: Icon(
                  LucideIcons.x,
                  size: 16,
                  color: AppTheme.subtleTextColor,
                ),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
            child: switch (_section) {
              _SettingsSection.general => _buildGeneralSection(l10n),
              _SettingsSection.appearance => _buildAppearanceSection(l10n),
              _SettingsSection.about => _buildAboutSection(l10n),
            },
          ),
        ),
      ],
    );
  }

  Widget _sectionLabelText(String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: AppTheme.subtleTextColor,
      ),
    );
  }

  // ── 通用:界面语言 ──
  Widget _buildGeneralSection(AppL10n l10n) {
    final locale = ref.watch(appLocaleControllerProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabelText(l10n.language),
        const SizedBox(height: 10),
        _ModernSegmentedBar<AppLocale>(
          selected: locale,
          onChanged: (value) =>
              ref.read(appLocaleControllerProvider.notifier).setLocale(value),
          items: [
            _SegmentItem(
              value: AppLocale.system,
              label: l10n.followSystem,
              icon: LucideIcons.languages,
            ),
            _SegmentItem(value: AppLocale.zh, label: l10n.chinese),
            _SegmentItem(value: AppLocale.en, label: l10n.english),
          ],
        ),
      ],
    );
  }

  // ── 外观:主题模式 + 品牌主色 ──
  Widget _buildAppearanceSection(AppL10n l10n) {
    final themeMode = ref.watch(appThemeControllerProvider);
    final brandColor = ref.watch(appBrandColorControllerProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabelText(l10n.theme),
        const SizedBox(height: 10),
        _ModernSegmentedBar<ThemeMode>(
          selected: themeMode,
          onChanged: (value) =>
              ref.read(appThemeControllerProvider.notifier).setThemeMode(value),
          items: [
            _SegmentItem(
              value: ThemeMode.system,
              label: l10n.followSystem,
              icon: LucideIcons.monitor,
            ),
            _SegmentItem(
              value: ThemeMode.light,
              label: l10n.lightTheme,
              icon: LucideIcons.sun,
            ),
            _SegmentItem(
              value: ThemeMode.dark,
              label: l10n.darkTheme,
              icon: LucideIcons.moon,
            ),
          ],
        ),
        const SizedBox(height: 20),
        _sectionLabelText(l10n.brandColor),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final color in AppBrandColor.values)
              _BrandColorSwatch(
                color: color,
                isDark: isDark,
                selected: color == brandColor,
                onTap: () => ref
                    .read(appBrandColorControllerProvider.notifier)
                    .setColor(color),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          l10n.brandColorDesc,
          style: TextStyle(fontSize: 11, color: AppTheme.subtleTextColor),
        ),
      ],
    );
  }

  // ── 关于:软件更新 + 关于 Termora ──
  Widget _buildAboutSection(AppL10n l10n) {
    final updateState = ref.watch(appUpdateControllerProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildUpdateSection(ref, l10n, updateState, isDark),
        const SizedBox(height: 16),
        _buildAboutCard(l10n, isDark),
      ],
    );
  }

  Widget _buildAboutCard(AppL10n l10n, bool isDark) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.03)
            : Colors.black.withValues(alpha: 0.02),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.info, size: 16, color: AppTheme.brandColor),
              const SizedBox(width: 8),
              Text(
                l10n.aboutTermora,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.headingColor,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppTheme.brandColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'v$kAppVersion+$kAppBuild',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.brandColor,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            l10n.aboutTagline,
            style: TextStyle(
              fontSize: 11.5,
              color: AppTheme.bodyColor,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              // Flexible + 内层 ellipsis:窄对话框下 URL 收缩,
              // 不再把 MIT License 顶出边界(RenderFlex overflow)
              Flexible(
                child: InkWell(
                  borderRadius: BorderRadius.circular(4),
                  onTap: () {
                    if (Platform.isMacOS) {
                      Process.run('open', [
                        'https://github.com/pynets/termora',
                      ]);
                    } else if (Platform.isLinux) {
                      Process.run('xdg-open', [
                        'https://github.com/pynets/termora',
                      ]);
                    } else if (Platform.isWindows) {
                      Process.run('cmd', [
                        '/c',
                        'start',
                        'https://github.com/pynets/termora',
                      ]);
                    }
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          LucideIcons.externalLink,
                          size: 13,
                          color: AppTheme.brandColor,
                        ),
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(
                            'https://github.com/pynets/termora',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: AppTheme.brandColor,
                              decoration: TextDecoration.underline,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const Spacer(),
              Text(
                'MIT License',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: AppTheme.subtleTextColor,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildUpdateSection(
    WidgetRef ref,
    AppL10n l10n,
    AppUpdateState state,
    bool isDark,
  ) {
    final update = state.update;
    final percent = ((state.progress ?? 0) * 100).floor();
    final isDownloading = state.phase == AppUpdatePhase.downloading;
    final status = switch (state.phase) {
      AppUpdatePhase.checking => l10n.checkingForUpdates,
      AppUpdatePhase.upToDate => l10n.upToDate,
      AppUpdatePhase.available => l10n.updateAvailable(update!.tagName),
      AppUpdatePhase.downloading => l10n.downloadingUpdate(percent),
      AppUpdatePhase.installing => l10n.installingUpdate,
      AppUpdatePhase.manualInstallOpened => l10n.manualInstallOpened,
      AppUpdatePhase.failed => l10n.updateFailed,
      AppUpdatePhase.idle => l10n.checkForUpdates,
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.03)
            : Colors.black.withValues(alpha: 0.02),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                LucideIcons.circleArrowUp300,
                size: 16,
                color: AppTheme.brandColor,
              ),
              const SizedBox(width: 8),
              Text(
                l10n.softwareUpdate,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.headingColor,
                ),
              ),
              const Spacer(),
              if (state.phase == AppUpdatePhase.available && update != null)
                Text(
                  update.sizeLabel,
                  style: TextStyle(
                    fontSize: 11,
                    color: AppTheme.subtleTextColor,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            status,
            style: TextStyle(fontSize: 11.5, color: AppTheme.bodyColor),
          ),
          if (isDownloading) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(value: state.progress, minHeight: 4),
          ],
          if (state.phase == AppUpdatePhase.failed &&
              state.errorMessage != null) ...[
            const SizedBox(height: 4),
            Text(
              state.errorMessage!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10.5, color: AppTheme.subtleTextColor),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: state.isBusy
                    ? null
                    : () => ref
                          .read(appUpdateControllerProvider.notifier)
                          .checkForUpdate(),
                icon: const Icon(LucideIcons.refreshCw, size: 14),
                label: Text(l10n.checkForUpdates),
              ),
              const SizedBox(width: 8),
              if (update != null &&
                  state.phase != AppUpdatePhase.manualInstallOpened)
                FilledButton.icon(
                  onPressed: state.isBusy
                      ? null
                      : () => ref
                            .read(appUpdateControllerProvider.notifier)
                            .installUpdate(),
                  icon: const Icon(LucideIcons.download, size: 14),
                  label: Text(l10n.updateNow),
                ),
              if (update != null && update.dmgUrl == null) ...[
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => ref
                      .read(appUpdateControllerProvider.notifier)
                      .openReleasePage(),
                  child: Text(l10n.viewRelease),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// 侧栏分区导航项 — 参考 superdesk 的 hover/选中态(softBrandColor 药丸)
class _SettingsNavItem extends StatefulWidget {
  const _SettingsNavItem({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  State<_SettingsNavItem> createState() => _SettingsNavItemState();
}

class _SettingsNavItemState extends State<_SettingsNavItem> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final isActive = widget.isSelected || _isHovered;
    final foregroundColor = isActive
        ? AppTheme.brandColor
        : AppTheme.subtleTextColor;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: isActive ? AppTheme.softBrandColor : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Icon(widget.icon, size: 14, color: foregroundColor),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: widget.isSelected
                        ? FontWeight.w600
                        : FontWeight.w400,
                    color: isActive
                        ? AppTheme.headingColor
                        : AppTheme.bodyColor,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BrandColorSwatch extends StatelessWidget {
  const _BrandColorSwatch({
    required this.color,
    required this.isDark,
    required this.selected,
    required this.onTap,
  });

  final AppBrandColor color;
  final bool isDark;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final swatch = isDark ? color.darkBrandColor : color.lightBrandColor;

    return Tooltip(
      message: color.label,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          width: 64,
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? swatch : AppTheme.borderColor,
              width: selected ? 1.6 : 1,
            ),
            color: selected
                ? swatch.withValues(alpha: 0.10)
                : Colors.transparent,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: swatch,
                  shape: BoxShape.circle,
                ),
                child: selected
                    ? const Icon(Icons.check, size: 15, color: Colors.white)
                    : null,
              ),
              const SizedBox(height: 6),
              Text(
                // label 形如「青色 (Teal)」,取中文部分显示
                color.label.split(' ').first,
                style: TextStyle(
                  fontSize: 10.5,
                  color: selected ? AppTheme.headingColor : AppTheme.bodyColor,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SegmentItem<T> {
  const _SegmentItem({required this.value, required this.label, this.icon});

  final T value;
  final String label;
  final IconData? icon;
}

class _ModernSegmentedBar<T> extends StatelessWidget {
  const _ModernSegmentedBar({
    required this.items,
    required this.selected,
    required this.onChanged,
  });

  final List<_SegmentItem<T>> items;
  final T selected;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.05)
            : const Color(0xFFEEEEF0),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : const Color(0xFFE2E2E6),
          width: 0.8,
        ),
      ),
      child: Row(
        children: items.map((item) {
          final isSelected = item.value == selected;
          return Expanded(
            child: _ModernSegmentButton<T>(
              item: item,
              isSelected: isSelected,
              isDark: isDark,
              onTap: () => onChanged(item.value),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _ModernSegmentButton<T> extends StatelessWidget {
  const _ModernSegmentButton({
    required this.item,
    required this.isSelected,
    required this.isDark,
    required this.onTap,
  });

  final _SegmentItem<T> item;
  final bool isSelected;
  final bool isDark;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(vertical: 7.5),
        decoration: BoxDecoration(
          color: isSelected
              ? (isDark ? const Color(0xFF38383A) : Colors.white)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(7.5),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.07),
                    blurRadius: 4,
                    offset: const Offset(0, 1.5),
                  ),
                ]
              : null,
          border: isSelected
              ? Border.all(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.12)
                      : Colors.black.withValues(alpha: 0.04),
                  width: 0.5,
                )
              : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (item.icon != null) ...[
              Icon(
                item.icon,
                size: 14,
                color: isSelected
                    ? AppTheme.brandColor
                    : AppTheme.subtleTextColor,
              ),
              const SizedBox(width: 6),
            ],
            Flexible(
              child: Text(
                item.label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                  color: isSelected
                      ? AppTheme.headingColor
                      : AppTheme.bodyColor,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
