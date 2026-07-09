import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:termora/core/services/tray_service.dart';
import 'package:termora/core/services/update_service.dart';

/// 启动页状态
class SplashState {
  final String statusText;
  final bool hasError;

  /// 检测到的可用升级;非空时启动页显示升级卡片等待用户选择
  final UpdateInfo? update;

  /// 升级包下载进度 0..1;非空表示正在下载
  final double? updateProgress;

  const SplashState({
    this.statusText = '正在初始化...',
    this.hasError = false,
    this.update,
    this.updateProgress,
  });

  SplashState copyWith({
    String? statusText,
    bool? hasError,
    UpdateInfo? update,
    double? updateProgress,
    bool clearUpdate = false,
    bool clearProgress = false,
  }) {
    return SplashState(
      statusText: statusText ?? this.statusText,
      hasError: hasError ?? this.hasError,
      update: clearUpdate ? null : update ?? this.update,
      updateProgress:
          clearProgress ? null : updateProgress ?? this.updateProgress,
    );
  }
}

/// 启动页初始化结果
enum SplashResult { navigateToHome }

class SplashController extends Notifier<SplashState> {
  @override
  SplashState build() => const SplashState();

  /// 执行应用初始化流程。检测到新版本时返回 null 留在启动页,
  /// 由用户在升级卡片上选择「立即升级 / 稍后」。
  Future<SplashResult?> initializeApp() async {
    try {
      state = state.copyWith(statusText: '正在初始化系统基础服务...');
      await Future.delayed(const Duration(milliseconds: 200));

      state = state.copyWith(statusText: '正在加载系统托盘与快捷键...');
      await TrayService.instance.initialize();

      state = state.copyWith(statusText: '正在检查更新...');
      // 3 秒内查 GitHub Release;网络失败/超时静默跳过,不挡启动
      final update = await UpdateService.checkForUpdate();
      if (update != null) {
        state = state.copyWith(update: update, statusText: '发现新版本');
        return null; // 停在启动页等用户选择
      }

      state = state.copyWith(statusText: '正在准备工作空间...');
      await Future.delayed(const Duration(milliseconds: 200));

      return SplashResult.navigateToHome;
    } catch (e) {
      if (kDebugMode) debugPrint('SplashController 初始化失败: $e');
      state = SplashState(
        statusText: '初始化系统服务异常: $e',
        hasError: true,
      );
      return null;
    }
  }

  /// 跳过本次升级,继续进入应用。
  SplashResult skipUpdate() {
    state = state.copyWith(clearUpdate: true, statusText: '正在准备工作空间...');
    return SplashResult.navigateToHome;
  }

  /// 下载并安装升级。成功时应用自动重启(不返回);
  /// 自动替换失败回退为打开 dmg 手动安装,然后照常进入应用。
  Future<SplashResult?> performUpdate() async {
    final update = state.update;
    if (update == null) return SplashResult.navigateToHome;
    if (update.dmgUrl == null) {
      // 没有 dmg 资产:无从下载,直接进应用(设置页仍可跳 Release 页)
      return skipUpdate();
    }
    try {
      state = state.copyWith(
        updateProgress: 0,
        statusText: '正在下载 ${update.tagName}...',
      );
      var lastShown = -1;
      final dmg = await UpdateService.downloadDmg(update, (p) {
        final pct = (p * 100).floor();
        if (pct != lastShown) {
          lastShown = pct;
          state = state.copyWith(
            updateProgress: p,
            statusText: '正在下载 ${update.tagName}... $pct%',
          );
        }
      });

      state = state.copyWith(updateProgress: 1, statusText: '正在安装更新...');
      final ok = await UpdateService.installAndRelaunch(dmg);
      // 走到这里说明自动替换没成功(成功时进程已重启退出)
      if (!ok) {
        await UpdateService.openDmg(dmg);
        state = state.copyWith(
          clearUpdate: true,
          clearProgress: true,
          statusText: '已打开安装包,请手动拖入 Applications 完成升级',
        );
        await Future.delayed(const Duration(milliseconds: 1200));
      }
      return SplashResult.navigateToHome;
    } catch (e) {
      if (kDebugMode) debugPrint('升级失败: $e');
      state = state.copyWith(
        clearUpdate: true,
        clearProgress: true,
        statusText: '升级失败,已跳过:$e',
      );
      await Future.delayed(const Duration(milliseconds: 1200));
      return SplashResult.navigateToHome;
    }
  }

  /// 异常重试
  Future<SplashResult?> retry() async {
    state = const SplashState(statusText: '正在重新尝试初始化...');
    return initializeApp();
  }
}

final splashControllerProvider =
    NotifierProvider<SplashController, SplashState>(SplashController.new);
