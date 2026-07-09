import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:termora/app/theme/app_theme.dart';
import 'package:termora/features/settings/controller/setting_providers.dart';

/// 打开设置弹窗
Future<void> showSettingsDialog(BuildContext context) {
  return showDialog(
    context: context,
    builder: (context) => const SettingsDialog(),
  );
}

/// 设置弹窗 — 外观(主题模式 + 品牌主色),与 superdesk 同一套配色体系
class SettingsDialog extends ConsumerWidget {
  const SettingsDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(appThemeControllerProvider);
    final brandColor = ref.watch(appBrandColorControllerProvider);
    final locale = ref.watch(appLocaleControllerProvider);
    final l10n = AppL10n.resolve(locale);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(LucideIcons.settings, size: 18, color: AppTheme.brandColor),
                  const SizedBox(width: 8),
                  Text(
                    l10n.settings,
                    style: TextStyle(
                      fontSize: 16,
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
              const SizedBox(height: 16),

              // ── 界面语言 ──
              Text(
                l10n.language,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.subtleTextColor,
                ),
              ),
              const SizedBox(height: 10),
              _ModernSegmentedBar<AppLocale>(
                selected: locale,
                onChanged: (value) => ref
                    .read(appLocaleControllerProvider.notifier)
                    .setLocale(value),
                items: [
                  _SegmentItem(
                    value: AppLocale.system,
                    label: l10n.followSystem,
                    icon: LucideIcons.languages,
                  ),
                  _SegmentItem(
                    value: AppLocale.zh,
                    label: l10n.chinese,
                  ),
                  _SegmentItem(
                    value: AppLocale.en,
                    label: l10n.english,
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // ── 主题模式 ──
              Text(
                l10n.theme,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.subtleTextColor,
                ),
              ),
              const SizedBox(height: 10),
              _ModernSegmentedBar<ThemeMode>(
                selected: themeMode,
                onChanged: (value) => ref
                    .read(appThemeControllerProvider.notifier)
                    .setThemeMode(value),
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

              // ── 品牌主色 ──
              Text(
                l10n.brandColor,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.subtleTextColor,
                ),
              ),
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

              const SizedBox(height: 20),
              Divider(height: 1, color: AppTheme.borderColor),
              const SizedBox(height: 16),

              // ── 关于 Termora (About) ──
              Container(
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
                            'v0.0.1+1',
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
                        Icon(LucideIcons.externalLink, size: 13, color: AppTheme.subtleTextColor),
                        const SizedBox(width: 5),
                        Text(
                          'https://github.com/pynets/termora',
                          style: TextStyle(
                            fontSize: 11,
                            color: AppTheme.subtleTextColor,
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
                decoration: BoxDecoration(color: swatch, shape: BoxShape.circle),
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
  const _SegmentItem({
    required this.value,
    required this.label,
    this.icon,
  });

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
                  )
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

