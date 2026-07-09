import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';

/// 截图贴图浮窗 — 置顶可拖动的截图预览小窗口
/// 由 desktop_multi_window 创建的子窗口
class ScreenshotPinWindow extends StatefulWidget {
  final String imagePath;
  final WindowController windowController;

  const ScreenshotPinWindow({
    super.key,
    required this.imagePath,
    required this.windowController,
  });

  @override
  State<ScreenshotPinWindow> createState() => _ScreenshotPinWindowState();
}

class _ScreenshotPinWindowState extends State<ScreenshotPinWindow> {
  Uint8List? _imageData;
  bool _isLoading = true;
  String? _error;
  bool _isHovering = false;

  static const _channel =
      MethodChannel('com.hxlive.termora/pin_window');

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
          _error = '贴图文件不存在';
          _isLoading = false;
        });
        return;
      }

      final data = await file.readAsBytes();
      // 读取后删除临时文件
      await file.delete().catchError((_) => file);

      setState(() {
        _imageData = data;
        _isLoading = false;
      });

      // 图片加载完成后，请求原生端显示窗口并配置为浮动窗口
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        final pixelRatio = View.of(context).devicePixelRatio;
        try {
          // 解码图片获取尺寸 (物理像素)
          final codec = await ui.instantiateImageCodec(data);
          final frame = await codec.getNextFrame();
          final imgWidth = frame.image.width;
          final imgHeight = frame.image.height;

          // 使用之前计算的逻辑尺寸
          final logicalWidth = imgWidth / pixelRatio;
          final logicalHeight = imgHeight / pixelRatio;

          await _channel.invokeMethod('present', {
            'width': logicalWidth,
            'height': logicalHeight,
          });
        } catch (e) {
          debugPrint('贴图窗口 present 失败: $e');
          // 回退：直接 show
          try {
            await widget.windowController.show();
          } catch (_) {}
        }
      });
    } catch (e) {
      setState(() {
        _error = '加载贴图失败: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _closeWindow() async {
    try {
      await _channel.invokeMethod('close');
    } catch (e) {
      debugPrint('关闭贴图窗口失败: $e');
      try {
        await widget.windowController.hide();
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const SizedBox.shrink();
    }

    if (_error != null || _imageData == null) {
      return Container(
        color: Colors.black87,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 32),
              const SizedBox(height: 8),
              Text(
                _error ?? '未知错误',
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _closeWindow,
                child: const Text('关闭'),
              ),
            ],
          ),
        ),
      );
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovering = true),
      onExit: (_) => setState(() => _isHovering = false),
      child: GestureDetector(
        onPanDown: (_) {
          try {
            _channel.invokeMethod('startDragging');
          } catch (_) {}
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 图片内容
            Image.memory(
              _imageData!,
              fit: BoxFit.contain,
              filterQuality: FilterQuality.high,
            ),

            // 边框 (去除阴影，因为原生窗口已有阴影，且容器阴影会导致整体变暗)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: _isHovering
                          ? const Color(0xFF3B82F6)
                          : Colors.black.withValues(alpha: 0.15),
                      width: _isHovering ? 2.0 : 1.0,
                    ),
                  ),
                ),
              ),
            ),

            // 悬停时的工具栏
            if (_isHovering)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Container(
                  height: 32,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.6),
                        Colors.black.withValues(alpha: 0.0),
                      ],
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      _PinToolButton(
                        icon: Icons.close,
                        tooltip: '关闭贴图',
                        onTap: _closeWindow,
                      ),
                      const SizedBox(width: 4),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 贴图工具栏按钮
class _PinToolButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _PinToolButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  State<_PinToolButton> createState() => _PinToolButtonState();
}

class _PinToolButtonState extends State<_PinToolButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: _hover
                  ? Colors.white.withValues(alpha: 0.3)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(
              widget.icon,
              size: 16,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

/// 启动贴图浮窗入口
Future<void> runPinWindow(WindowController controller) async {
  final args = jsonDecode(controller.arguments) as Map<String, dynamic>;
  final imagePath = args['imagePath'] as String;

  // 注册贴图窗口管理通道（处理原生→Dart 的关闭请求）
  const windowChannel = MethodChannel('com.hxlive.termora/pin_window');
  windowChannel.setMethodCallHandler((call) async {
    switch (call.method) {
      case 'close':
        exit(0);
      default:
        throw MissingPluginException('No handler for ${call.method}');
    }
  });

  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      color: Colors.transparent,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.transparent,
        canvasColor: Colors.transparent,
      ),
      home: ScreenshotPinWindow(
        imagePath: imagePath,
        windowController: controller,
      ),
    ),
  );
}
