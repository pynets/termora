import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:termora/app/theme/app_theme.dart';
import 'package:termora/core/app_version.dart';
import 'package:termora/features/settings/controller/app_update_controller.dart';
import 'package:termora/features/settings/controller/setting_providers.dart';

/// 发现新版本时的轻量更新弹窗 — 与设置里的更新区域共用同一份 controller 状态,
/// 关掉弹窗后下载仍在后台继续,可随时从设置里查看进度
Future<void> showUpdateDialog(BuildContext context) {
  return showDialog(
    context: context,
    useRootNavigator: false,
    barrierColor: Colors.black.withValues(alpha: 0.3),
    builder: (context) => const UpdateDialog(),
  );
}

class UpdateDialog extends ConsumerWidget {
  const UpdateDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appUpdateControllerProvider);
    final locale = ref.watch(appLocaleControllerProvider);
    final l10n = AppL10n.resolve(locale);
    final update = state.update;
    final percent = ((state.progress ?? 0) * 100).floor();
    final isDownloading = state.phase == AppUpdatePhase.downloading;

    final status = switch (state.phase) {
      AppUpdatePhase.downloading => l10n.downloadingUpdate(percent),
      AppUpdatePhase.installing => l10n.installingUpdate,
      AppUpdatePhase.manualInstallOpened => l10n.manualInstallOpened,
      AppUpdatePhase.failed => l10n.updateFailed,
      _ =>
        update == null ? l10n.upToDate : l10n.updateAvailable(update.tagName),
    };

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    LucideIcons.circleArrowUp300,
                    size: 18,
                    color: AppTheme.brandColor,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    l10n.softwareUpdate,
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
              const SizedBox(height: 12),
              Text(
                status,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.bodyColor,
                ),
              ),
              if (update != null) ...[
                const SizedBox(height: 4),
                Text(
                  'v$kAppVersion → ${update.tagName}'
                  '${update.sizeLabel.isEmpty ? '' : ' · ${update.sizeLabel}'}',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: AppTheme.subtleTextColor,
                  ),
                ),
              ],
              if (isDownloading) ...[
                const SizedBox(height: 10),
                LinearProgressIndicator(value: state.progress, minHeight: 4),
              ],
              if (state.phase == AppUpdatePhase.failed &&
                  state.errorMessage != null) ...[
                const SizedBox(height: 4),
                Text(
                  state.errorMessage!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    color: AppTheme.subtleTextColor,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (state.phase == AppUpdatePhase.manualInstallOpened)
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(l10n.close),
                    )
                  else ...[
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(l10n.later),
                    ),
                    const SizedBox(width: 8),
                    if (update != null && update.dmgUrl == null)
                      FilledButton.icon(
                        onPressed: () => ref
                            .read(appUpdateControllerProvider.notifier)
                            .openReleasePage(),
                        icon: const Icon(LucideIcons.externalLink, size: 14),
                        label: Text(l10n.viewRelease),
                      )
                    else
                      FilledButton.icon(
                        onPressed: state.isBusy
                            ? null
                            : () => ref
                                  .read(appUpdateControllerProvider.notifier)
                                  .installUpdate(),
                        icon: const Icon(LucideIcons.download, size: 14),
                        label: Text(l10n.updateNow),
                      ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
