import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:window_manager/window_manager.dart';

import 'package:termora/app/shell/main_shell.dart';
import 'package:termora/app/theme/app_theme.dart';
import 'package:termora/core/services/update_service.dart';
import 'package:termora/features/splash/controller/splash_controller.dart';
import 'package:termora/core/l10n/app_l10n.dart';

/// 启动页 - 移植并适配自 superdesk
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen>
    with TickerProviderStateMixin {
  late final AnimationController _contentController;
  late final Animation<double> _fadeAnim;
  late final Animation<double> _slideAnim;
  bool _isTransitioning = false;

  @override
  void initState() {
    super.initState();
    _contentController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );

    _fadeAnim = CurvedAnimation(
      parent: _contentController,
      curve: Curves.easeOut,
    );

    _slideAnim = Tween<double>(begin: 20, end: 0).animate(
      CurvedAnimation(parent: _contentController, curve: Curves.easeOut),
    );

    _contentController.forward();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
          await windowManager.setResizable(false);
          await windowManager.setAlignment(Alignment.center);
          await windowManager.setOpacity(1.0);
          await windowManager.setHasShadow(true);
        }
        await windowManager.show();
        await windowManager.focus();
      } catch (e) {
        debugPrint(tr2('显示启动窗口失败: {0}', [e]));
      }
      _startInitialization();
    });
  }

  @override
  void dispose() {
    _contentController.dispose();
    super.dispose();
  }

  Future<void> _startInitialization() async {
    final results = await Future.wait([
      ref.read(splashControllerProvider.notifier).initializeApp(),
      Future.delayed(const Duration(milliseconds: 1000)),
    ]);

    await _handleResult(results[0] as SplashResult?);
  }

  Future<void> _retry() async {
    final result = await ref.read(splashControllerProvider.notifier).retry();
    await _handleResult(result);
  }

  Future<void> _skipUpdate() async {
    final result = ref.read(splashControllerProvider.notifier).skipUpdate();
    await _handleResult(result);
  }

  Future<void> _performUpdate() async {
    final result =
        await ref.read(splashControllerProvider.notifier).performUpdate();
    await _handleResult(result);
  }

  Future<void> _handleResult(SplashResult? result) async {
    if (!mounted || result == null) return;
    switch (result) {
      case SplashResult.navigateToHome:
        await _transitionToHome();
    }
  }

  Future<void> _transitionToHome() async {
    if (!mounted) return;

    setState(() => _isTransitioning = true);

    await Future.delayed(const Duration(milliseconds: 300));

    if (!mounted) return;

    _expandWindow();
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            const MainShell(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
        },
        transitionDuration: const Duration(milliseconds: 350),
      ),
    );
  }

  Future<void> _expandWindow() async {
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      await windowManager.setResizable(true);
      await windowManager.setMinimumSize(const Size(0, 0));
      await windowManager.setMaximumSize(const Size(9999, 9999));

      await windowManager.setAlignment(Alignment.center);
      await Future.delayed(const Duration(milliseconds: 50));

      final currentBounds = await windowManager.getBounds();
      final center = currentBounds.center;
      final newBounds = Rect.fromCenter(
        center: center,
        width: 1180,
        height: 760,
      );

      await windowManager.setBounds(newBounds, animate: true);
      await windowManager.setTitleBarStyle(
        TitleBarStyle.normal,
        windowButtonVisibility: true,
      );

      await Future.delayed(const Duration(milliseconds: 400));
      await windowManager.setMinimumSize(const Size(800, 560));
    }
  }

  /// 发现新版本的升级卡片:版本号 + 体积,立即升级 / 稍后。
  Widget _buildUpdateCard(UpdateInfo update) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              LucideIcons.circleArrowUp300,
              size: 16,
              color: AppTheme.brandColor,
            ),
            const SizedBox(width: 7),
            Text(
              tr2('发现新版本 {0}', [update.tagName]),
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: AppTheme.headingColor,
              ),
            ),
          ],
        ),
        if (update.sizeLabel.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            tr2('安装包 {0} · 下载完成后自动安装并重启', [update.sizeLabel]),
            style: TextStyle(fontSize: 11.5, color: AppTheme.subtleTextColor),
          ),
        ],
        const SizedBox(height: 18),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 34,
              child: FilledButton(
                onPressed: () => _performUpdate(),
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.brandColor,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                child: const Text(
                  '立即升级',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              height: 34,
              child: TextButton(
                onPressed: () => _skipUpdate(),
                style: TextButton.styleFrom(
                  foregroundColor: AppTheme.subtleTextColor,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                ),
                child: Text(tr('稍后'), style: TextStyle(fontSize: 12)),
              ),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final splashState = ref.watch(splashControllerProvider);

    return Scaffold(
      backgroundColor: AppTheme.backgroundColor,
      body: Center(
        child: AnimatedBuilder(
          animation: _contentController,
          builder: (context, child) {
            return Transform.translate(
              offset: Offset(0, _slideAnim.value),
              child: Opacity(opacity: _fadeAnim.value, child: child),
            );
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 品牌 Logo 徽标
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: AppTheme.brandColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: AppTheme.brandColor.withValues(alpha: 0.35),
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.brandColor.withValues(alpha: 0.15),
                      blurRadius: 24,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Center(
                  child: Icon(
                    LucideIcons.squareTerminal300,
                    size: 42,
                    color: AppTheme.brandColor,
                  ),
                ),
              ),
              const SizedBox(height: 32),
              SizedBox(
                height: 220,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: _isTransitioning
                      ? Container(
                          key: const ValueKey('loading'),
                          alignment: Alignment.topCenter,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                tr('正在准备工作空间...'),
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color: AppTheme.bodyColor,
                                  fontWeight: FontWeight.w400,
                                ),
                              ),
                              const SizedBox(height: 16),
                              SizedBox(
                                width: 120,
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(2),
                                  child: const _LaunchProgressBar(),
                                ),
                              ),
                            ],
                          ),
                        )
                      : Container(
                          key: const ValueKey('splash'),
                          alignment: Alignment.topCenter,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                tr('正在启动'),
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 16,
                                  height: 1.15,
                                  fontWeight: FontWeight.w400,
                                  color: AppTheme.headingColor,
                                  letterSpacing: -0.3,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                tr('Termora 智能终端工作平台'),
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 12,
                                  height: 1.45,
                                  color: AppTheme.bodyColor,
                                  fontWeight: FontWeight.w400,
                                ),
                              ),
                              const SizedBox(height: 32),
                              if (splashState.hasError &&
                                  !_isTransitioning) ...[
                                const Icon(
                                  Icons.error_outline,
                                  color: Colors.redAccent,
                                  size: 28,
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  splashState.statusText,
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w400,
                                    color: Colors.redAccent.withValues(
                                      alpha: 0.9,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 20),
                                SizedBox(
                                  height: 36,
                                  child: FilledButton(
                                    onPressed: _retry,
                                    style: FilledButton.styleFrom(
                                      backgroundColor:
                                          Theme.of(context).brightness ==
                                                  Brightness.dark
                                              ? AppTheme.subtleSurfaceColor
                                              : const Color(0xFF111827),
                                      foregroundColor:
                                          Theme.of(context).brightness ==
                                                  Brightness.dark
                                              ? AppTheme.headingColor
                                              : Colors.white,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 20,
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(
                                          999,
                                        ),
                                      ),
                                    ),
                                    child: const Text(
                                      '重试',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                ),
                              ] else if (splashState.updateProgress !=
                                  null) ...[
                                // 升级包下载中:确定进度条 + 百分比
                                SizedBox(
                                  width: 200,
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(2),
                                    child: LinearProgressIndicator(
                                      value: splashState.updateProgress,
                                      minHeight: 4,
                                      backgroundColor:
                                          AppTheme.subtleSurfaceColor,
                                      valueColor:
                                          AlwaysStoppedAnimation<Color>(
                                        AppTheme.brandColor,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 14),
                                Text(
                                  splashState.statusText,
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    color: AppTheme.bodyColor,
                                  ),
                                ),
                              ] else if (splashState.update != null) ...[
                                _buildUpdateCard(splashState.update!),
                              ] else if (!_isTransitioning) ...[
                                SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      AppTheme.bodyColor,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  splashState.statusText,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: AppTheme.bodyColor,
                                  ),
                                ),
                              ],
                            ],
                          ),
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

class _LaunchProgressBar extends StatefulWidget {
  const _LaunchProgressBar();

  @override
  State<_LaunchProgressBar> createState() => _LaunchProgressBarState();
}

class _LaunchProgressBarState extends State<_LaunchProgressBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _travel;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1850),
    )..repeat();

    _travel = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOutCubic,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 3,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final trackWidth = constraints.maxWidth;
          return DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              color: Theme.of(context).brightness == Brightness.dark
                  ? AppTheme.subtleSurfaceColor
                  : const Color(0xFFE8E8E4).withValues(alpha: 0.5),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: AnimatedBuilder(
                animation: _travel,
                builder: (context, _) {
                  const shimmerFactor = 0.3;
                  final shimmerWidth = trackWidth * shimmerFactor;
                  final shimmerLeft =
                      (-shimmerWidth) +
                      ((trackWidth + shimmerWidth) * _travel.value);

                  return Stack(
                    children: [
                      Positioned(
                        left: shimmerLeft,
                        top: 0,
                        bottom: 0,
                        child: Container(
                          width: shimmerWidth,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.centerLeft,
                              end: Alignment.centerRight,
                              colors: Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? [
                                      AppTheme.headingColor.withValues(
                                        alpha: 0,
                                      ),
                                      AppTheme.headingColor.withValues(
                                        alpha: 0.4,
                                      ),
                                      AppTheme.headingColor.withValues(
                                        alpha: 0,
                                      ),
                                    ]
                                  : [
                                      const Color(
                                        0xFF111827,
                                      ).withValues(alpha: 0),
                                      const Color(
                                        0xFF111827,
                                      ).withValues(alpha: 0.7),
                                      const Color(
                                        0xFF111827,
                                      ).withValues(alpha: 0),
                                    ],
                              stops: const [0, 0.5, 1],
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }
}
