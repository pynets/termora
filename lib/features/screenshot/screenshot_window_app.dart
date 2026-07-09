import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';

import 'package:termora/features/screenshot/screenshot_editor.dart';

/// 截屏编辑器独立窗口应用
/// 由 desktop_multi_window 创建的子窗口，运行截屏编辑器
/// ⚠️ 子窗口没有 window_manager 插件，使用原生 MethodChannel 管理窗口
class ScreenshotWindowApp extends StatefulWidget {
  final String imagePath;
  final WindowController windowController;
  final List<Rect> windowBounds;

  const ScreenshotWindowApp({
    super.key,
    required this.imagePath,
    required this.windowController,
    this.windowBounds = const [],
  });

  @override
  State<ScreenshotWindowApp> createState() => _ScreenshotWindowAppState();
}

class _ScreenshotWindowAppState extends State<ScreenshotWindowApp> {
  Uint8List? _imageData;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  Future<void> _loadImage() async {
    try {
      final file = File(widget.imagePath);
      if (!await file.exists()) {
        setState(() {
          _error = '截图文件不存在: ${widget.imagePath}';
          _isLoading = false;
        });
        _presentWindowAfterFirstFrame();
        return;
      }

      final data = await file.readAsBytes();
      // 读取后删除临时文件
      await file.delete().catchError((_) => file);

      setState(() {
        _imageData = data;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = '加载截图失败: $e';
        _isLoading = false;
      });
    }
    // 渲染完承载图片的首帧后，再请求 native 端真正"亮起"编辑器窗口。
    // 这样用户从按下快捷键到看到编辑器之间无"透明空窗期"。
    _presentWindowAfterFirstFrame();
  }

  bool _presented = false;
  void _presentWindowAfterFirstFrame() {
    if (_presented) return;
    _presented = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (Platform.isMacOS) {
        const channel = MethodChannel('com.hxlive.termora/screenshot_window');
        try {
          await channel.invokeMethod('presentEditor');
        } catch (e) {
          debugPrint('presentEditor 调用失败，回退到 controller.show(): $e');
          try {
            await widget.windowController.show();
          } catch (_) {}
        }
      } else {
        // 非 macOS 走原来的 controller.show()
        try {
          await widget.windowController.show();
        } catch (_) {}
      }
    });
  }

  /// 关闭截屏窗口
  Future<void> _closeWindow() async {
    try {
      // 1. 先将窗口隐藏，避免在 engine 销毁时 VSync 继续触发导致底层的 clamping frame time 报错
      await widget.windowController.hide();
    } catch (e) {
      debugPrint('隐藏截屏窗口失败: $e');
    }

    try {
      // 2. 原生通道关闭并恢复焦点
      const channel = MethodChannel('com.hxlive.termora/screenshot_window');
      await channel.invokeMethod('close');
    } catch (e) {
      debugPrint('原生通道关闭截屏窗口失败: $e');
    }
  }

  /// 发送结果给主窗口
  Future<void> _sendResult(String action, Uint8List? data) async {
    try {
      // 如果有数据，先保存到临时文件，传路径（避免 IPC 大数据）
      String? resultPath;
      if (data != null) {
        final tempPath =
            '${Directory.systemTemp.path}/screenshot_result_${DateTime.now().millisecondsSinceEpoch}.png';
        await File(tempPath).writeAsBytes(data);
        resultPath = tempPath;
      }

      final channel = const WindowMethodChannel('screenshot_result');
      await channel.invokeMethod(action, resultPath);
    } catch (e) {
      debugPrint('发送截屏结果失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Container(
        color: Colors.transparent,
        child: const Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
      );
    }

    if (_error != null || _imageData == null) {
      return Container(
        color: Colors.transparent,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 48),
              const SizedBox(height: 16),
              Text(
                _error ?? '未知错误',
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
              const SizedBox(height: 16),
              ElevatedButton(onPressed: _closeWindow, child: const Text('关闭')),
            ],
          ),
        ),
      );
    }

    return ScreenshotEditor(
      imageData: _imageData!,
      windowBounds: widget.windowBounds,
      onComplete: (croppedData) async {
        await _sendResult('complete', croppedData);
        await _closeWindow();
      },
      onCancel: () async {
        await _sendResult('cancel', null);
        await _closeWindow();
      },
      onSave: (data) async {
        await _sendResult('save', data);
        await _closeWindow();
      },
      onOCR: (data) async {
        await _sendResult('ocr', data);
        await _closeWindow();
      },
      onPin: (data) async {
        await _sendResult('pin', data);
        await _closeWindow();
      },
    );
  }
}

/// 启动截屏编辑器窗口入口
/// ⚠️ 不使用 window_manager（子窗口没注册该插件）
/// 窗口配置通过原生 MethodChannel 完成
Future<void> runScreenshotWindow(WindowController controller) async {
  // 解析参数
  final args = jsonDecode(controller.arguments) as Map<String, dynamic>;
  final imagePath = args['imagePath'] as String;

  // 解析窗口边界列表（用于智能窗口检测）
  final List<Rect> windowBounds = [];
  if (args['windowBounds'] is List) {
    for (final item in args['windowBounds'] as List) {
      final map = Map<String, dynamic>.from(item as Map);
      final rect = Rect.fromLTWH(
        (map['x'] as num).toDouble(),
        (map['y'] as num).toDouble(),
        (map['width'] as num).toDouble(),
        (map['height'] as num).toDouble(),
      );
      windowBounds.add(rect);
      debugPrint('  解析窗口: ${map['ownerName'] ?? '?'} → $rect');
    }
  }

  // 注册原生截屏窗口管理通道（用于关闭窗口等）
  const windowChannel = MethodChannel('com.hxlive.termora/screenshot_window');
  windowChannel.setMethodCallHandler((call) async {
    switch (call.method) {
      case 'close':
        exit(0);
      default:
        throw MissingPluginException('No handler for ${call.method}');
    }
  });

  if (Platform.isWindows) {
    // Windows: Start Flutter rendering FIRST, then configure the window.
    // The C++ callback no longer modifies the window — it only registers the
    // channel. We must call runApp() before configureFullscreen so that
    // Flutter's rendering pipeline and the plugin's internal WM_SIZE handler
    // are ready when we resize the window to fullscreen.
    runApp(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        color: Colors.transparent,
        theme: ThemeData.dark().copyWith(
          scaffoldBackgroundColor: Colors.transparent,
          canvasColor: Colors.transparent,
        ),
        home: ScreenshotWindowApp(
          imagePath: imagePath,
          windowController: controller,
          windowBounds: windowBounds,
        ),
      ),
    );

    // Wait for the first frame to be rendered, then configure and show
    await Future.delayed(const Duration(milliseconds: 100));
    try {
      await windowChannel.invokeMethod('configureFullscreen');
    } catch (e) {
      debugPrint('configureFullscreen failed: $e');
      // Fallback: just try to show the window normally
      try {
        await controller.show();
      } catch (_) {}
    }
  } else {
    // macOS / Linux: 启动 Flutter 渲染。窗口的真正显示推迟到 _loadImage 完成、
    // 首帧渲染好之后由 ScreenshotWindowApp 通过 channel 调 presentEditor，
    // 这样从用户视角是"按下快捷键 → 编辑器带着截图直接出现"，无空窗期。
    runApp(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        color: Colors.transparent,
        theme: ThemeData.dark().copyWith(
          scaffoldBackgroundColor: Colors.transparent,
          canvasColor: Colors.transparent,
        ),
        home: ScreenshotWindowApp(
          imagePath: imagePath,
          windowController: controller,
          windowBounds: windowBounds,
        ),
      ),
    );
    // Linux 没有 presentEditor 通道，回退到原来的"等一帧再 show"逻辑
    if (!Platform.isMacOS) {
      await Future.delayed(const Duration(milliseconds: 50));
      try {
        await controller.show();
      } catch (_) {}
    }
  }
}
