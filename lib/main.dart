import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:toastification/toastification.dart';
import 'package:window_manager/window_manager.dart';

import 'package:termora/app/theme/app_theme.dart';
import 'package:termora/features/screenshot/screenshot_pin_window.dart';
import 'package:termora/features/screenshot/screenshot_window_app.dart';
import 'package:termora/features/settings/controller/setting_providers.dart';
import 'package:termora/features/splash/view/splash_screen.dart';

/// Toast 通知显示在顶部居中，距顶部留出一定间距
EdgeInsetsGeometry _toastMarginBuilder(
  BuildContext context,
  AlignmentGeometry alignment,
) {
  return const EdgeInsets.only(top: 30);
}

void main() async {
  // 拦截并忽略 Flutter 框架中已知且无害的硬件键盘状态同步断言错误
  // （由于桌面端原生全局快捷键和多窗口机制经常导致 KeyUp/KeyDown 事件与 Flutter 预期不符）
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    if (error is AssertionError &&
        error.toString().contains('hardware_keyboard.dart')) {
      return true;
    }
    return false;
  };

  final originalOnError = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    final error = details.exception;
    if (error is AssertionError &&
        error.toString().contains('hardware_keyboard.dart')) {
      return;
    }
    if (originalOnError != null) {
      originalOnError(details);
    } else {
      FlutterError.presentError(details);
    }
  };

  WidgetsFlutterBinding.ensureInitialized();

  // 检查是否是子窗口（由 desktop_multi_window 创建）
  // ⚠️ 必须在 windowManager.ensureInitialized() 之前！子窗口没有 window_manager 插件
  if (Platform.isMacOS || Platform.isLinux || Platform.isWindows) {
    try {
      final controller = await WindowController.fromCurrentEngine();
      final args = jsonDecode(controller.arguments) as Map<String, dynamic>;
      final businessId = args['businessId'] as String?;

      if (businessId == 'screenshot') {
        await runScreenshotWindow(controller);
        return;
      }

      if (businessId == 'screenshot_pin') {
        await runPinWindow(controller);
        return;
      }
    } catch (_) {
      // 不是子窗口，继续正常启动
    }
  }

  // ═══ 主窗口正常启动流程 ═══
  if (Platform.isMacOS || Platform.isLinux || Platform.isWindows) {
    try {
      await windowManager.ensureInitialized();
    } catch (e) {
      // 子窗口在 hot restart 后丢失多窗口参数流转到此处，直接停止渲染主应用 UI
      return;
    }

    await windowManager.hide();

    const windowOptions = WindowOptions(
      size: Size(560, 560),
      center: true,
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.hidden,
      title: 'Termora',
    );

    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      // 不在这里显示窗口，让 Splash 在首帧渲染完成后再显示
      // 这样可以避免字体加载和窗口位置调整导致的闪烁
    });
  }

  runApp(const ProviderScope(child: TermoraApp()));
}

class TermoraApp extends ConsumerStatefulWidget {
  const TermoraApp({super.key});

  @override
  ConsumerState<TermoraApp> createState() => _TermoraAppState();
}

class _TermoraAppState extends ConsumerState<TermoraApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    if (mounted) {
      setState(() {});
    }
  }

  /// 已应用的窗口标题栏亮度，避免每帧重复调用原生通道
  Brightness? _appliedWindowBrightness;

  void _syncWindowBrightness(Brightness brightness) {
    if (_appliedWindowBrightness == brightness) return;
    _appliedWindowBrightness = brightness;
    if (Platform.isMacOS || Platform.isWindows) {
      // fire-and-forget：设置原生窗口外观(含标题栏)跟随应用主题
      windowManager.setBrightness(brightness);
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(appThemeControllerProvider);
    final brandColor = ref.watch(appBrandColorControllerProvider);

    final isDark =
        themeMode == ThemeMode.dark ||
        (themeMode == ThemeMode.system &&
            PlatformDispatcher.instance.platformBrightness == Brightness.dark);

    // 同步静态主题配置，供组件树内同步读取(与 superdesk 同一套主题)
    AppTheme.useBrightness(isDark ? Brightness.dark : Brightness.light);
    AppTheme.useBrandColor(brandColor);

    // 同步原生窗口标题栏明暗(否则深色模式下 macOS 标题栏仍是白条)
    _syncWindowBrightness(isDark ? Brightness.dark : Brightness.light);

    return ToastificationConfigProvider(
      config: ToastificationConfig(
        alignment: Alignment.topCenter,
        marginBuilder: _toastMarginBuilder,
      ),
      child: MaterialApp(
        builder: (context, child) {
          return ToastificationWrapper(child: child!);
        },
        title: 'Termora',
        debugShowCheckedModeBanner: false,
        color: AppTheme.backgroundColor,
        theme: AppTheme.lightTheme,
        darkTheme: AppTheme.darkTheme,
        themeMode: themeMode,
        home: const SplashScreen(),
      ),
    );
  }
}
