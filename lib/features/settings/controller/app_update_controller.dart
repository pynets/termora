import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:termora/core/services/update_service.dart';
import 'package:termora/core/l10n/app_l10n.dart';

enum AppUpdatePhase {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  installing,
  manualInstallOpened,
  failed,
}

class AppUpdateState {
  const AppUpdateState({
    this.phase = AppUpdatePhase.idle,
    this.update,
    this.progress,
    this.errorMessage,
  });

  final AppUpdatePhase phase;
  final UpdateInfo? update;
  final double? progress;
  final String? errorMessage;

  bool get isBusy => switch (phase) {
    AppUpdatePhase.checking ||
    AppUpdatePhase.downloading ||
    AppUpdatePhase.installing => true,
    _ => false,
  };

  AppUpdateState copyWith({
    AppUpdatePhase? phase,
    UpdateInfo? update,
    double? progress,
    String? errorMessage,
    bool clearUpdate = false,
    bool clearProgress = false,
    bool clearError = false,
  }) {
    return AppUpdateState(
      phase: phase ?? this.phase,
      update: clearUpdate ? null : update ?? this.update,
      progress: clearProgress ? null : progress ?? this.progress,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    );
  }
}

/// 主界面更新流程。启动后静默检查，用户确认后才下载和安装。
class AppUpdateController extends Notifier<AppUpdateState> {
  @override
  AppUpdateState build() => const AppUpdateState();

  Future<void> checkForUpdate() async {
    if (state.isBusy) return;
    state = const AppUpdateState(phase: AppUpdatePhase.checking);
    final update = await UpdateService.checkForUpdate();
    state = update == null
        ? const AppUpdateState(phase: AppUpdatePhase.upToDate)
        : AppUpdateState(phase: AppUpdatePhase.available, update: update);
  }

  Future<void> installUpdate() async {
    final update = state.update;
    if (update == null || state.isBusy) return;
    if (update.dmgUrl == null) {
      state = state.copyWith(
        phase: AppUpdatePhase.failed,
        errorMessage: tr('当前版本没有可下载的安装包'),
      );
      return;
    }

    try {
      state = state.copyWith(
        phase: AppUpdatePhase.downloading,
        progress: 0,
        clearError: true,
      );
      var lastProgress = -1;
      final dmg = await UpdateService.downloadDmg(update, (progress) {
        final percent = (progress * 100).floor();
        if (percent == lastProgress) return;
        lastProgress = percent;
        state = state.copyWith(progress: progress);
      });

      state = state.copyWith(phase: AppUpdatePhase.installing, progress: 1);
      final installed = await UpdateService.installAndRelaunch(dmg);
      if (!installed) {
        await UpdateService.openDmg(dmg);
        state = state.copyWith(
          phase: AppUpdatePhase.manualInstallOpened,
          clearProgress: true,
        );
      }
    } catch (e) {
      if (kDebugMode) debugPrint(tr2('主界面升级失败: {0}', [e]));
      state = state.copyWith(
        phase: AppUpdatePhase.failed,
        clearProgress: true,
        errorMessage: e.toString(),
      );
    }
  }

  Future<void> openReleasePage() async {
    final url = state.update?.htmlUrl;
    if (url == null) return;
    if (Platform.isMacOS) {
      await Process.run('open', [url]);
    } else if (Platform.isWindows) {
      await Process.run('cmd', ['/c', 'start', '', url]);
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', [url]);
    }
  }
}

final appUpdateControllerProvider =
    NotifierProvider<AppUpdateController, AppUpdateState>(
      AppUpdateController.new,
    );
