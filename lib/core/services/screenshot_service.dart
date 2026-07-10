import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:screen_capturer/screen_capturer.dart';
import 'package:termora/core/l10n/app_l10n.dart';

/// 截屏服务
/// macOS: 使用原生 CGWindowListCreateImage + NSPasteboard
/// Windows: 使用 screen_capturer 作为后备
class ScreenshotService {
  static final ScreenshotService _instance = ScreenshotService._internal();
  factory ScreenshotService() => _instance;
  ScreenshotService._internal();

  /// 原生截屏通道
  static const _channel = MethodChannel('com.hxlive.termora/screen_capture');

  /// 截屏并保存到临时文件（多窗口模式）
  /// 返回临时文件路径，供截屏编辑器窗口读取
  Future<String?> captureScreenToFile() async {
    if (!Platform.isMacOS) {
      // 非 macOS 回退：截全屏后手动保存
      final data = await captureFullScreenSilent();
      if (data == null) return null;
      final tempPath =
          '${Directory.systemTemp.path}/screenshot_${DateTime.now().millisecondsSinceEpoch}.png';
      await File(tempPath).writeAsBytes(data);
      return tempPath;
    }

    try {
      debugPrint(tr('截屏并保存到临时文件'));
      final result = await _channel.invokeMethod<String>('captureScreenToFile');
      if (result != null) {
        debugPrint(tr2('截屏已保存到: {0}', [result]));
      }
      return result;
    } on PlatformException catch (e) {
      if (e.code == 'PERMISSION_DENIED') {
        throw ScreenshotPermissionException(tr('未赋予屏幕录制权限，无法截屏'));
      }
      debugPrint(tr2('原生截屏失败，回退: {0}', [e]));
      final data = await captureFullScreenSilent();
      if (data == null) return null;
      final tempPath =
          '${Directory.systemTemp.path}/screenshot_${DateTime.now().millisecondsSinceEpoch}.png';
      await File(tempPath).writeAsBytes(data);
      return tempPath;
    } catch (e) {
      debugPrint(tr2('原生截屏异常: {0}', [e]));
      return null;
    }
  }

  /// 将图片复制到系统剪贴板 — 原生 NSPasteboard API
  /// macOS: 原生 API，支持 PNG + TIFF，兼容所有应用
  /// Windows: 使用 PowerShell 后备方案
  Future<bool> copyImageToClipboard(Uint8List pngData) async {
    if (Platform.isMacOS) {
      try {
        final result = await _channel.invokeMethod<bool>(
          'copyImageToClipboard',
          pngData,
        );
        debugPrint(tr('已复制截图到剪贴板 (原生 NSPasteboard)'));
        return result ?? false;
      } catch (e) {
        debugPrint(tr2('原生剪贴板复制失败: {0}', [e]));
        return false;
      }
    }

    if (Platform.isWindows) {
      try {
        final tempDir = Directory.systemTemp;
        final tempFile = File(
          '${tempDir.path}\\screenshot_clipboard_${DateTime.now().millisecondsSinceEpoch}.png',
        );
        await tempFile.writeAsBytes(pngData);

        await Process.run('powershell', [
          '-command',
          'Add-Type -AssemblyName System.Windows.Forms; '
              '[System.Windows.Forms.Clipboard]::SetImage('
              '[System.Drawing.Image]::FromFile("${tempFile.path}"))',
        ]);

        await tempFile.delete().catchError((_) => tempFile);
        debugPrint(tr('已复制截图到剪贴板 (Windows PowerShell)'));
        return true;
      } catch (e) {
        debugPrint(tr2('Windows 剪贴板复制失败: {0}', [e]));
        return false;
      }
    }

    return false;
  }

  /// 区域截图（旧接口，保持兼容）
  Future<Uint8List?> captureRegion() async {
    if (Platform.isWindows) {
      try {
        Directory directory = await getTemporaryDirectory();
        String imageName =
            'screenshot_${DateTime.now().millisecondsSinceEpoch}.png';
        String imagePath = '${directory.path}/$imageName';

        CapturedData? capturedData = await ScreenCapturer.instance.capture(
          mode: CaptureMode.region,
          imagePath: imagePath,
        );

        if (capturedData != null && capturedData.imageBytes != null) {
          return capturedData.imageBytes;
        }
        return null;
      } catch (e) {
        debugPrint(tr2('Windows 区域截屏异常: {0}', [e]));
        return null;
      }
    }

    if (!Platform.isMacOS) {
      debugPrint(tr('截屏功能不支持此平台'));
      return null;
    }

    try {
      final directory = await getTemporaryDirectory();
      final imagePath =
          '${directory.path}/screenshot_${DateTime.now().millisecondsSinceEpoch}.png';

      final result = await Process.run('screencapture', ['-i', imagePath]);

      if (result.exitCode == 0) {
        final file = File(imagePath);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          await file.delete();
          return bytes;
        }
      } else {
        final stderr = result.stderr.toString();
        if (stderr.contains('could not create image from rect')) {
          throw ScreenshotPermissionException(tr('未赋予屏幕录制权限或未选择区域'));
        }
      }
    } catch (e) {
      if (e is ScreenshotPermissionException) rethrow;
      debugPrint(tr2('区域截屏异常: {0}', [e]));
    }
    return null;
  }

  /// 全屏截图
  Future<Uint8List?> captureScreen() async {
    if (Platform.isMacOS) {
      return _captureScreenNative();
    }

    if (Platform.isWindows) {
      return _captureScreenWindows();
    }

    return null;
  }

  /// 静默全屏截图 — 无 UI 弹出
  Future<Uint8List?> captureFullScreenSilent() async {
    if (Platform.isMacOS) {
      return _captureScreenNative();
    }

    if (Platform.isWindows) {
      return _captureScreenWindows();
    }

    return null;
  }

  /// Windows 静默截屏 — 使用 PowerShell + .NET System.Drawing
  /// 完全无 UI 弹出，不触发 Windows 截屏工具
  Future<Uint8List?> _captureScreenWindows() async {
    try {
      final tempPath =
          '${Directory.systemTemp.path}\\screenshot_silent_${DateTime.now().millisecondsSinceEpoch}.png';

      final result = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        '''
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class DpiHelper {
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
}
"@
[DpiHelper]::SetProcessDPIAware()
\$screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
\$bitmap = New-Object System.Drawing.Bitmap(\$screen.Width, \$screen.Height)
\$graphics = [System.Drawing.Graphics]::FromImage(\$bitmap)
\$graphics.CopyFromScreen(\$screen.Location, [System.Drawing.Point]::Empty, \$screen.Size)
\$bitmap.Save("$tempPath", [System.Drawing.Imaging.ImageFormat]::Png)
\$graphics.Dispose()
\$bitmap.Dispose()
''',
      ]);

      if (result.exitCode == 0) {
        final file = File(tempPath);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          await file.delete().catchError((_) => file);
          return bytes;
        }
      }
      debugPrint(tr2('Windows 静默截图失败: {0}', [result.stderr]));
    } catch (e) {
      debugPrint(tr2('Windows 静默截图异常: {0}', [e]));
    }
    return null;
  }

  /// macOS 原生截图 — CGWindowListCreateImage
  /// 比 screencapture CLI 快约 10 倍，无声音，无文件 IO
  Future<Uint8List?> _captureScreenNative() async {
    try {
      final result = await _channel.invokeMethod<Uint8List>('captureScreen');
      if (result != null) {
        debugPrint(tr2('原生截图成功，大小: {0} bytes', [result.length]));
      }
      return result;
    } catch (e) {
      debugPrint(tr2('原生截图失败，回退到 screencapture CLI: {0}', [e]));
      // 回退到 CLI
      return _captureScreenCLI();
    }
  }

  /// screencapture CLI 后备方案
  Future<Uint8List?> _captureScreenCLI() async {
    try {
      final directory = await getTemporaryDirectory();
      final imagePath =
          '${directory.path}/screenshot_${DateTime.now().millisecondsSinceEpoch}.png';

      final result = await Process.run('screencapture', ['-x', imagePath]);

      if (result.exitCode == 0) {
        final file = File(imagePath);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          await file.delete();
          return bytes;
        }
      }
    } catch (e) {
      debugPrint(tr2('screencapture CLI 截图失败: {0}', [e]));
    }
    return null;
  }

  /// 窗口截图
  Future<Uint8List?> captureWindow() async {
    if (Platform.isWindows) {
      return captureRegion();
    }
    if (!Platform.isMacOS) {
      return null;
    }

    try {
      final directory = await getTemporaryDirectory();
      final imagePath =
          '${directory.path}/screenshot_${DateTime.now().millisecondsSinceEpoch}.png';

      final result = await Process.run('screencapture', [
        '-i',
        '-w',
        imagePath,
      ]);

      if (result.exitCode == 0) {
        final file = File(imagePath);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          await file.delete();
          return bytes;
        }
      }
    } catch (e) {
      debugPrint(tr2('窗口截屏失败: {0}', [e]));
    }
    return null;
  }

  /// 保存截图到桌面
  Future<String?> saveScreenshot(Uint8List imageData) async {
    try {
      String desktopPath = '';
      if (Platform.isWindows) {
        final userProfile = Platform.environment['USERPROFILE'];
        if (userProfile != null) {
          desktopPath = '$userProfile\\Desktop';
        } else {
          desktopPath = (await getApplicationDocumentsDirectory()).path;
        }
      } else if (Platform.isMacOS) {
        final home = Platform.environment['HOME'] ?? '';
        desktopPath = '$home/Desktop';
      } else {
        debugPrint(tr('截屏保存仅支持 macOS/Windows'));
        return null;
      }

      final fileName =
          'screenshot_${DateTime.now().millisecondsSinceEpoch}.png';
      final filePath = '$desktopPath${Platform.pathSeparator}$fileName';

      final file = File(filePath);
      await file.writeAsBytes(imageData);

      debugPrint(tr2('截图已保存到: {0}', [filePath]));
      return filePath;
    } catch (e) {
      debugPrint(tr2('保存截图失败: {0}', [e]));
      return null;
    }
  }

  /// 获取当前屏幕上所有可见窗口的边界列表
  /// 用于截屏编辑器的智能窗口检测
  Future<List<WindowBounds>> getWindowList() async {
    try {
      final result = await _channel.invokeMethod<List<dynamic>>(
        'getWindowList',
      );
      if (result == null) return [];

      return result.map((item) {
        final map = Map<String, dynamic>.from(item as Map);
        return WindowBounds(
          rect: Rect.fromLTWH(
            (map['x'] as num).toDouble(),
            (map['y'] as num).toDouble(),
            (map['width'] as num).toDouble(),
            (map['height'] as num).toDouble(),
          ),
          title: map['title'] as String? ?? '',
          ownerName: map['ownerName'] as String? ?? '',
        );
      }).toList();
    } catch (e) {
      debugPrint(tr2('获取窗口列表失败: {0}', [e]));
      return [];
    }
  }
}

/// 窗口边界数据
class WindowBounds {
  final Rect rect;
  final String title;
  final String ownerName;

  const WindowBounds({
    required this.rect,
    this.title = '',
    this.ownerName = '',
  });

  @override
  String toString() => 'WindowBounds($ownerName: $title, $rect)';
}

class ScreenshotPermissionException implements Exception {
  final String message;
  ScreenshotPermissionException(this.message);
  @override
  String toString() => message;
}
