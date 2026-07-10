// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:window_manager/window_manager.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:termora/core/services/screenshot_service.dart';
import 'package:termora/core/l10n/app_l10n.dart';

/// 系统托盘服务(常驻小羊图标)
///
/// 截屏全局快捷键使用 ⌥+Shift+X,刻意与 superdesk 的 ⌘+Shift+X 区分,
/// 两个应用可以同时常驻运行互不冲突。
class TrayService with TrayListener, WindowListener {
  static final TrayService _instance = TrayService._internal();
  static TrayService get instance => _instance;

  TrayService._internal();

  bool _isInitialized = false;
  bool _launchAtStartup = false;
  bool _supportsLaunchAtStartup = true;
  bool _alwaysOnTop = false;

  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  /// 截屏完成回调 (返回截图路径)
  void Function(String? path)? onScreenshotComplete;

  /// 截屏数据就绪回调 (用于多窗口截屏编辑器)
  void Function(Uint8List imageData)? onScreenshotReady;

  /// 截屏编辑完成回调 — 一次性回调,使用后自动清除
  void Function(Uint8List editedData)? onScreenshotEdited;

  /// 截屏快捷键
  HotKey? _screenshotHotKey;

  /// 当前截屏窗口控制器
  WindowController? _screenshotWindowController;

  /// 贴图浮窗控制器列表
  final List<WindowController> _pinWindows = [];

  /// 初始化托盘
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      await windowManager.ensureInitialized();

      await _initNotifications();

      // 添加窗口监听器（用于关闭时最小化到托盘）
      windowManager.addListener(this);
      await windowManager.setPreventClose(true);

      // 初始化开机自启动（失败不阻断托盘初始化）
      try {
        await _initLaunchAtStartup();
      } catch (e) {
        _supportsLaunchAtStartup = false;
        if (kDebugMode) {
          debugPrint(tr2('LaunchAtStartup 不可用，已自动禁用该功能: {0}', [e]));
        }
      }

      await trayManager.setIcon(_getTrayIconPath(), isTemplate: true);
      await trayManager.setToolTip('Termora');

      await _updateTrayMenu();

      trayManager.addListener(this);
      await _registerScreenshotHotKey();

      _registerScreenshotResultChannel();

      _isInitialized = true;
      if (kDebugMode) debugPrint('TrayService initialized');
    } catch (e) {
      if (kDebugMode) debugPrint('TrayService initialize failed: $e');
    }
  }

  bool get isInitialized => _isInitialized;

  /// 注册截屏结果通道 — 接收截屏编辑器窗口的回调
  void _registerScreenshotResultChannel() {
    const channel = WindowMethodChannel(
      'screenshot_result',
      mode: ChannelMode.unidirectional,
    );
    channel.setMethodCallHandler((call) async {
      if (kDebugMode) debugPrint(tr2('收到截屏结果: {0}', [call.method]));
      _screenshotWindowController = null;

      Uint8List? resultData;
      if (call.arguments is String) {
        final resultPath = call.arguments as String;
        final file = File(resultPath);
        if (await file.exists()) {
          resultData = await file.readAsBytes();
          await file.delete().catchError((_) => file);
        }
      }

      switch (call.method) {
        case 'complete':
          if (resultData != null) {
            final editedCallback = onScreenshotEdited;
            if (editedCallback != null) {
              onScreenshotEdited = null;
              editedCallback(resultData);
            } else {
              // 默认：复制到系统剪贴板
              await ScreenshotService().copyImageToClipboard(resultData);
            }
          }
          break;
        case 'save':
          if (resultData != null) {
            await saveEditedScreenshot(resultData);
          }
          break;
        case 'ocr':
          if (resultData != null) {
            onScreenshotEdited = null;
            onScreenshotReady?.call(resultData);
          }
          break;
        case 'pin':
          if (resultData != null) {
            onScreenshotEdited = null;
            await _createPinWindow(resultData);
          }
          break;
        case 'cancel':
          onScreenshotEdited = null;
          break;
      }
    });
  }

  Future<void> _initLaunchAtStartup() async {
    if (!(Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
      _supportsLaunchAtStartup = false;
      return;
    }

    launchAtStartup.setup(
      appName: 'Termora',
      appPath: Platform.executable,
    );
    try {
      _launchAtStartup = await launchAtStartup.isEnabled();
      _supportsLaunchAtStartup = true;
    } on MissingPluginException {
      _supportsLaunchAtStartup = false;
      _launchAtStartup = false;
    }
  }

  Future<void> _updateTrayMenu() async {
    final items = <MenuItem>[
      MenuItem(key: 'show_window', label: tr('显示窗口')),
      MenuItem.separator(),
      MenuItem(key: 'screenshot', label: tr('截屏 (⌥+Shift+X)')),
      MenuItem.separator(),
      MenuItem.checkbox(
        key: 'always_on_top',
        label: tr('窗口置顶'),
        checked: _alwaysOnTop,
      ),
    ];

    if (_supportsLaunchAtStartup) {
      items.add(
        MenuItem.checkbox(
          key: 'launch_at_startup',
          label: tr('开机自启动'),
          checked: _launchAtStartup,
        ),
      );
    }

    items
      ..add(MenuItem.separator())
      ..add(MenuItem(key: 'quit', label: tr('退出')));

    final menu = Menu(items: items);
    await trayManager.setContextMenu(menu);
  }

  /// 注册全局截屏快捷键 — ⌥+Shift+X(避免与 superdesk 的 ⌘+Shift+X 冲突)
  Future<void> _registerScreenshotHotKey() async {
    try {
      // 先清理旧的快捷键注册（热重启后可能残留）
      await hotKeyManager.unregisterAll();

      _screenshotHotKey = HotKey(
        key: LogicalKeyboardKey.keyX,
        modifiers: [HotKeyModifier.alt, HotKeyModifier.shift],
        scope: HotKeyScope.system,
      );

      await hotKeyManager.register(
        _screenshotHotKey!,
        keyDownHandler: (hotKey) {
          if (kDebugMode) debugPrint(tr('截屏快捷键触发'));
          // 清空键盘状态记录，防止全局快捷键(修饰键)触发时导致 Flutter 键盘状态不同步报错
          HardwareKeyboard.instance.clearState();
          takeScreenshot();
        },
      );
      if (kDebugMode) {
        debugPrint(tr2('截屏快捷键注册成功: ⌥+Shift+X ({0})', [_screenshotHotKey!.debugName]));
      }
    } catch (e) {
      if (kDebugMode) debugPrint(tr2('注册截屏快捷键失败: {0}', [e]));
    }
  }

  /// 执行截屏 — 多窗口模式
  /// 截图 → 保存到临时文件 → 创建独立截屏编辑器窗口
  /// 主窗口完全不受影响
  Future<void> takeScreenshot() async {
    // 防止重复创建截屏窗口（健壮检查：确认窗口是否真的还存在）
    if (_screenshotWindowController != null) {
      try {
        final allWindows = await WindowController.getAll();
        final stillExists = allWindows.any(
          (w) => w.windowId == _screenshotWindowController!.windowId,
        );
        if (stillExists) {
          if (kDebugMode) debugPrint(tr('截屏窗口已存在，跳过'));
          return;
        }
      } catch (_) {}
      // 窗口已不存在，清理引用继续创建新窗口
      _screenshotWindowController = null;
    }

    try {
      final screenshotService = ScreenshotService();

      // Step 1: 截屏并保存到临时文件 + 并行获取窗口列表
      final results = await Future.wait([
        screenshotService.captureScreenToFile(),
        screenshotService.getWindowList(),
      ]);

      final imagePath = results[0] as String?;
      final windowList = results[1] as List<WindowBounds>;

      if (kDebugMode) debugPrint(tr2('窗口列表获取完成: {0} 个窗口', [windowList.length]));

      if (imagePath == null) {
        if (kDebugMode) debugPrint(tr('截屏失败: 无法获取截图'));
        return;
      }

      // Step 2: 创建独立的截屏编辑器窗口
      final windowBoundsJson = windowList
          .map(
            (w) => {
              'x': w.rect.left,
              'y': w.rect.top,
              'width': w.rect.width,
              'height': w.rect.height,
              'ownerName': w.ownerName,
            },
          )
          .toList();

      final args = jsonEncode({
        'businessId': 'screenshot',
        'imagePath': imagePath,
        'windowBounds': windowBoundsJson,
      });

      final controller = await WindowController.create(
        WindowConfiguration(hiddenAtLaunch: true, arguments: args),
      );

      _screenshotWindowController = controller;

      if (kDebugMode) debugPrint(tr2('截屏编辑器窗口已创建: {0}', [controller.windowId]));
    } on ScreenshotPermissionException catch (e) {
      debugPrint(tr2('截屏权限异常: {0}', [e]));
      await showMessageNotification(
        title: tr('需要屏幕录制权限'),
        body: tr('请在“系统设置 > 隐私与安全性 > 屏幕录制”中允许本应用，以捕获其他窗口。'),
      );
    } catch (e) {
      if (kDebugMode) debugPrint(tr2('截屏失败: {0}', [e]));
      _screenshotWindowController = null;
    }
  }

  /// 保存编辑后的截图
  Future<void> saveEditedScreenshot(Uint8List imageData) async {
    try {
      final screenshotService = ScreenshotService();
      final path = await screenshotService.saveScreenshot(imageData);
      if (kDebugMode) debugPrint(tr2('编辑后截图已保存: {0}', [path]));

      await showMessageNotification(title: 'Termora', body: tr('截图已保存'));

      onScreenshotComplete?.call(path);
    } catch (e) {
      if (kDebugMode) debugPrint(tr2('保存截图失败: {0}', [e]));
    }
  }

  /// 创建贴图浮窗子窗口
  Future<void> _createPinWindow(Uint8List imageData) async {
    try {
      final tempPath =
          '${Directory.systemTemp.path}${Platform.pathSeparator}pin_${DateTime.now().millisecondsSinceEpoch}.png';
      await File(tempPath).writeAsBytes(imageData);

      final args = jsonEncode({
        'businessId': 'screenshot_pin',
        'imagePath': tempPath,
      });

      final controller = await WindowController.create(
        WindowConfiguration(hiddenAtLaunch: true, arguments: args),
      );

      _pinWindows.add(controller);

      if (kDebugMode) debugPrint(tr2('贴图浮窗已创建: {0}', [controller.windowId]));
    } catch (e) {
      if (kDebugMode) debugPrint(tr2('创建贴图浮窗失败: {0}', [e]));
    }
  }

  /// 设置开机自启动
  Future<void> setLaunchAtStartup(bool enabled) async {
    if (!_supportsLaunchAtStartup) return;
    try {
      if (enabled) {
        await launchAtStartup.enable();
      } else {
        await launchAtStartup.disable();
      }
      _launchAtStartup = enabled;
      await _updateTrayMenu();
    } catch (e) {
      if (kDebugMode) debugPrint(tr2('设置开机自启动失败 (调试模式下正常): {0}', [e]));
    }
  }

  /// 获取开机自启动状态
  bool get isLaunchAtStartup => _launchAtStartup;

  /// 设置窗口置顶
  Future<void> setAlwaysOnTop(bool enabled) async {
    await windowManager.setAlwaysOnTop(enabled);
    _alwaysOnTop = enabled;
    await _updateTrayMenu();
  }

  /// 获取窗口置顶状态
  bool get isAlwaysOnTop => _alwaysOnTop;

  Future<void> _initNotifications() async {
    const DarwinInitializationSettings darwinSettings =
        DarwinInitializationSettings(
          requestAlertPermission: true,
          requestBadgePermission: true,
          requestSoundPermission: true,
        );

    const LinuxInitializationSettings linuxSettings =
        LinuxInitializationSettings(defaultActionName: 'Open');

    const WindowsInitializationSettings windowsSettings =
        WindowsInitializationSettings(
          appName: 'Termora',
          appUserModelId: 'com.hxlive.termora',
          guid: 'bc68f9b4-abea-4ca0-9e95-fbfbbdc32fa6',
        );

    final InitializationSettings initSettings = InitializationSettings(
      macOS: darwinSettings,
      linux: linuxSettings,
      windows: windowsSettings,
    );

    await _notificationsPlugin.initialize(
      settings: initSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        if (kDebugMode) debugPrint(tr2('通知被点击: {0}', [response.payload]));
        _showWindow();
      },
    );
  }

  String _getTrayIconPath() {
    if (Platform.isMacOS) {
      // macOS: trayManager 会使用 rootBundle.load 加载，这里必须返回 asset key
      return 'assets/icons/tray_iconTemplate.png';
    } else if (Platform.isWindows) {
      return p.join(
        p.dirname(Platform.resolvedExecutable),
        'data',
        'flutter_assets',
        'assets',
        'icons',
        'tray_iconTemplate.ico',
      );
    }
    return 'assets/icons/tray_iconTemplate.png';
  }

  /// 显示窗口
  Future<void> _showWindow() async {
    try {
      await windowManager.show();
      await windowManager.focus();
      await cancelAllNotifications();
    } catch (e) {
      if (kDebugMode) debugPrint('Show window failed: $e');
    }
  }

  /// 最小化到托盘
  Future<void> minimizeToTray() async {
    await windowManager.hide();
  }

  /// 显示通知
  Future<void> showMessageNotification({
    required String title,
    required String body,
  }) async {
    const notificationDetails = NotificationDetails(
      macOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        presentBanner: true,
        presentList: true,
        sound: 'default',
      ),
      linux: LinuxNotificationDetails(),
      windows: WindowsNotificationDetails(),
    );

    await _notificationsPlugin.show(
      id: DateTime.now().millisecondsSinceEpoch % 100000,
      title: title,
      body: body,
      notificationDetails: notificationDetails,
    );
  }

  /// 清除所有通知
  Future<void> cancelAllNotifications() async {
    try {
      await _notificationsPlugin.cancelAll();
    } catch (e) {
      if (kDebugMode) debugPrint(tr2('清除通知失败: {0}', [e]));
    }
  }

  // WindowListener: 窗口获得焦点时清除通知
  @override
  void onWindowFocus() async {
    await cancelAllNotifications();
  }

  // WindowListener: 关闭时最小化到托盘
  @override
  void onWindowClose() async {
    await minimizeToTray();
  }

  @override
  void onTrayIconMouseDown() {
    _showWindow();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show_window':
        _showWindow();
        break;
      case 'screenshot':
        takeScreenshot();
        break;
      case 'always_on_top':
        setAlwaysOnTop(!_alwaysOnTop);
        break;
      case 'launch_at_startup':
        if (_supportsLaunchAtStartup) {
          setLaunchAtStartup(!_launchAtStartup);
        }
        break;
      case 'quit':
        windowManager.destroy();
        exit(0);
      default:
        break;
    }
  }

  Future<void> dispose() async {
    if (_screenshotHotKey != null) {
      await hotKeyManager.unregister(_screenshotHotKey!);
    }
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    await trayManager.destroy();
  }
}
