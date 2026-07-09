import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:termora/core/services/tray_service.dart';

/// 启动页状态
class SplashState {
  final String statusText;
  final bool hasError;

  const SplashState({
    this.statusText = '正在初始化...',
    this.hasError = false,
  });

  SplashState copyWith({
    String? statusText,
    bool? hasError,
  }) {
    return SplashState(
      statusText: statusText ?? this.statusText,
      hasError: hasError ?? this.hasError,
    );
  }
}

/// 启动页初始化结果
enum SplashResult { navigateToHome }

class SplashController extends Notifier<SplashState> {
  @override
  SplashState build() => const SplashState();

  /// 执行应用初始化流程
  Future<SplashResult?> initializeApp() async {
    try {
      state = state.copyWith(statusText: '正在初始化系统基础服务...');
      await Future.delayed(const Duration(milliseconds: 200));

      state = state.copyWith(statusText: '正在加载系统托盘与快捷键...');
      await TrayService.instance.initialize();

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

  /// 异常重试
  Future<SplashResult?> retry() async {
    state = const SplashState(statusText: '正在重新尝试初始化...');
    return initializeApp();
  }
}

final splashControllerProvider =
    NotifierProvider<SplashController, SplashState>(SplashController.new);
