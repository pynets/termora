import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

import 'package:termora/core/services/screenshot_service.dart';

import 'screenshot/screenshot_components.dart';
import 'package:toastification/toastification.dart';
import 'package:termora/core/widgets/app_toast.dart';

export 'screenshot/screenshot_components.dart' show DrawingTool, DrawingShape;

/// 截图编辑器 - 微信级全屏覆盖层
class ScreenshotEditor extends StatefulWidget {
  final Uint8List imageData;
  final void Function(Uint8List croppedData)? onComplete;
  final VoidCallback? onCancel;
  final void Function(Uint8List data)? onSave;
  final void Function(Uint8List data)? onOCR;
  final void Function(Uint8List data)? onPin;

  /// 屏幕上可见窗口的边界列表（物理像素坐标）
  final List<Rect> windowBounds;

  const ScreenshotEditor({
    super.key,
    required this.imageData,
    this.onComplete,
    this.onCancel,
    this.onSave,
    this.onOCR,
    this.onPin,
    this.windowBounds = const [],
  });

  @override
  State<ScreenshotEditor> createState() => _ScreenshotEditorState();
}

class _ScreenshotEditorState extends State<ScreenshotEditor> {
  ui.Image? _image;
  bool _isLoading = true;

  img.Image? _pixelBuffer;
  ui.Image? _mosaicImage;

  // 选区
  Rect? _selection;
  bool _isDrawingSelection = false;
  Offset? _selectionStart;

  // 选区拖动
  bool _isDraggingSelection = false;
  Offset? _dragSelectionStart;
  Rect? _dragSelectionOriginal;

  // 调整大小
  HandlePosition? _activeHandle;
  Offset? _dragStartOffset;
  Rect? _dragStartRect;

  // 工具栏
  bool _showToolbar = false;
  DrawingTool _currentTool = DrawingTool.none;
  Color _currentColor = Colors.red;

  // 线宽（影响所有非文字/编号的形状）
  double _currentStrokeWidth = 3.0;
  bool _showStrokePopover = false;

  // 绘图
  final List<DrawingShape> _shapes = [];
  final List<DrawingShape> _redoStack = [];
  DrawingShape? _currentShape;
  bool _isDrawingShape = false;

  // 文字输入
  bool _isEditingText = false;
  Offset? _textPosition;
  final TextEditingController _textController = TextEditingController();
  final FocusNode _textFocusNode = FocusNode();
  final FocusNode _rootFocusNode = FocusNode();

  // 数字编号计数器
  int _nextNumber = 1;

  static const double _mosaicBlockSize = 16.0;

  final ValueNotifier<Offset?> _hoverPosition = ValueNotifier(null);

  // 智能窗口检测
  Rect? _hoveredWindowRect;
  Rect? _pendingWindowRect;
  List<Rect> _logicalWindowBounds = [];

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    _textController.dispose();
    _textFocusNode.dispose();
    _rootFocusNode.dispose();
    _hoverPosition.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _loadImage();
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
  }

  bool _onKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent) {
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        if (_isEditingText) {
          _cancelTextInput();
          return true;
        }
        widget.onCancel?.call();
        return true;
      } else if (event.logicalKey == LogicalKeyboardKey.keyZ &&
          (HardwareKeyboard.instance.isMetaPressed ||
              HardwareKeyboard.instance.isControlPressed)) {
        if (HardwareKeyboard.instance.isShiftPressed) {
          _redo();
        } else {
          _undo();
        }
        return true;
      } else if (event.logicalKey == LogicalKeyboardKey.keyC &&
          (HardwareKeyboard.instance.isMetaPressed ||
              HardwareKeyboard.instance.isControlPressed) &&
          !_isEditingText &&
          _hoverPosition.value != null &&
          _pixelBuffer != null &&
          _image != null) {
        final pos = _hoverPosition.value!;
        final scaleX = _image!.width / MediaQuery.of(context).size.width;
        final scaleY = _image!.height / MediaQuery.of(context).size.height;
        final px = (pos.dx * scaleX).round().clamp(0, _pixelBuffer!.width - 1);
        final py = (pos.dy * scaleY).round().clamp(0, _pixelBuffer!.height - 1);

        final pixel = _pixelBuffer!.getPixel(px, py);
        final hex =
            '#${pixel.r.toInt().toRadixString(16).padLeft(2, '0')}'
                    '${pixel.g.toInt().toRadixString(16).padLeft(2, '0')}'
                    '${pixel.b.toInt().toRadixString(16).padLeft(2, '0')}'
                .toUpperCase();

        Clipboard.setData(ClipboardData(text: hex));
        if (mounted) {
          AppToast.show(
            context: context,
            style: ToastificationStyle.flat,
            applyBlurEffect: true,
            title: Text(
              '已复制色值: $hex',
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w400,
              ),
            ),
            type: ToastificationType.success,
            autoCloseDuration: const Duration(seconds: 1),
          );
        }
        return true;
      }
    }
    return false;
  }

  Future<void> _loadImage() async {
    final codec = await ui.instantiateImageCodec(widget.imageData);
    final frame = await codec.getNextFrame();

    final pixelBuffer = await compute(_decodePixelBuffer, widget.imageData);

    ui.Image? mosaicImg;
    if (pixelBuffer != null) {
      mosaicImg = await _buildMosaicImage(
        pixelBuffer,
        frame.image.width,
        frame.image.height,
      );
    }

    setState(() {
      _image = frame.image;
      _pixelBuffer = pixelBuffer;
      _mosaicImage = mosaicImg;
      _isLoading = false;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _image == null) return;
      final screenSize = MediaQuery.of(context).size;

      if (Platform.isWindows) {
        final scaleX = screenSize.width / _image!.width;
        final scaleY = screenSize.height / _image!.height;
        setState(() {
          _logicalWindowBounds = widget.windowBounds.map((r) {
            return Rect.fromLTWH(
              r.left * scaleX,
              r.top * scaleY,
              r.width * scaleX,
              r.height * scaleY,
            );
          }).toList();
        });
      } else {
        setState(() {
          _logicalWindowBounds = widget.windowBounds
              .where((r) => r.width > 0 && r.height > 0)
              .toList();
        });
      }

      final seen = <String>{};
      _logicalWindowBounds = _logicalWindowBounds.where((r) {
        final key =
            '${r.left.round()},${r.top.round()},${r.width.round()},${r.height.round()}';
        if (seen.contains(key)) return false;
        seen.add(key);
        return true;
      }).toList();

      debugPrint(
        '窗口检测: ${_logicalWindowBounds.length} 个窗口, 屏幕: $screenSize, 图片: ${_image!.width}x${_image!.height}',
      );
    });
  }

  Future<ui.Image> _buildMosaicImage(
    img.Image pixelBuffer,
    int w,
    int h,
  ) async {
    final blockSize = _mosaicBlockSize.toInt();
    final mosaicBytes = await compute(_generateMosaicRGBA, {
      'pixelBuffer': pixelBuffer,
      'width': w,
      'height': h,
      'blockSize': blockSize,
    });

    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      mosaicBytes,
      w,
      h,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  static Uint8List _generateMosaicRGBA(Map<String, dynamic> params) {
    final pixelBuffer = params['pixelBuffer'] as img.Image;
    final w = params['width'] as int;
    final h = params['height'] as int;
    final blockSize = params['blockSize'] as int;

    final bytes = Uint8List(w * h * 4);

    for (int by = 0; by < h; by += blockSize) {
      for (int bx = 0; bx < w; bx += blockSize) {
        final cx = (bx + blockSize ~/ 2).clamp(0, w - 1);
        final cy = (by + blockSize ~/ 2).clamp(0, h - 1);
        final pixel = pixelBuffer.getPixel(cx, cy);
        final r = pixel.r.toInt();
        final g = pixel.g.toInt();
        final b = pixel.b.toInt();
        final a = pixel.a.toInt();

        final bxEnd = (bx + blockSize).clamp(0, w);
        final byEnd = (by + blockSize).clamp(0, h);
        for (int y = by; y < byEnd; y++) {
          for (int x = bx; x < bxEnd; x++) {
            final i = (y * w + x) * 4;
            bytes[i] = r;
            bytes[i + 1] = g;
            bytes[i + 2] = b;
            bytes[i + 3] = a;
          }
        }
      }
    }
    return bytes;
  }

  static img.Image? _decodePixelBuffer(Uint8List pngData) {
    try {
      return img.decodePng(pngData);
    } catch (e) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading || _image == null) {
      return Container(
        color: Colors.transparent,
        child: const Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
      );
    }

    return Focus(
      autofocus: true,
      focusNode: _rootFocusNode,
      child: Material(
        type: MaterialType.transparency,
        child: Stack(
          children: [
            Positioned.fill(
              child: MouseRegion(
                cursor: _getCursorForCurrentState(),
                onEnter: (e) {
                  _hoverPosition.value = e.localPosition;
                  _updateHoveredWindow(e.localPosition);
                },
                onHover: (e) {
                  _hoverPosition.value = e.localPosition;
                  _updateHoveredWindow(e.localPosition);
                },
                onExit: (e) {
                  _hoverPosition.value = null;
                  if (_hoveredWindowRect != null) {
                    setState(() => _hoveredWindowRect = null);
                  }
                },
                child: GestureDetector(
                  onTapDown: (details) {
                    final pos = details.localPosition;
                    if (_isEditingText) {
                      _confirmTextInput();
                      return;
                    }
                    if (_selection != null &&
                        _currentTool == DrawingTool.text) {
                      final rect = _normalizedSelection;
                      if (rect.contains(pos)) {
                        _showTextInputAt(pos);
                        return;
                      }
                    }
                    if (_selection != null &&
                        _currentTool == DrawingTool.number) {
                      final rect = _normalizedSelection;
                      if (rect.contains(pos)) {
                        _addNumberMarker(pos);
                        return;
                      }
                    }
                  },
                  onTapUp: (details) {
                    if (_selection == null && _hoveredWindowRect != null) {
                      setState(() {
                        _selection = _hoveredWindowRect;
                        _hoveredWindowRect = null;
                        _showToolbar = true;
                      });
                    }
                    if (_showStrokePopover) {
                      setState(() => _showStrokePopover = false);
                    }
                  },
                  onPanStart: _onPanStart,
                  onPanUpdate: _onPanUpdate,
                  onPanEnd: _onPanEnd,
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: ScreenshotPainter(
                        image: _image!,
                        pixelBuffer: _pixelBuffer,
                        mosaicImage: _mosaicImage,
                        selection: _selection,
                        shapes: List.of(_shapes),
                        currentShape: _currentShape,
                        hoveredWindowRect: _hoveredWindowRect,
                      ),
                    ),
                  ),
                ),
              ),
            ),

            if (_selection != null &&
                _showToolbar &&
                _currentTool == DrawingTool.none)
              ..._buildResizeHandles(),

            if (_selection != null) _buildSizeIndicator(),

            if (_selection != null && _showToolbar) _buildToolbar(),

            if (_isEditingText && _textPosition != null)
              Positioned(
                left: _textPosition!.dx,
                top: _textPosition!.dy,
                child: _buildTextInput(),
              ),

            ValueListenableBuilder<Offset?>(
              valueListenable: _hoverPosition,
              builder: (context, pos, child) {
                final showMagnifier =
                    pos != null &&
                    (_selection == null ||
                        _isDrawingSelection ||
                        _activeHandle != null);
                if (!showMagnifier) return const SizedBox.shrink();
                return _buildMagnifierWindow(pos);
              },
            ),
          ],
        ),
      ),
    );
  }

  MouseCursor _getCursorForCurrentState() {
    if (_currentTool == DrawingTool.text) {
      return SystemMouseCursors.text;
    }
    if (_currentTool == DrawingTool.number) {
      return SystemMouseCursors.click;
    }
    if (_currentTool != DrawingTool.none) {
      return SystemMouseCursors.precise;
    }
    return SystemMouseCursors.precise;
  }

  Widget _buildMagnifierWindow(Offset pos) {
    if (_image == null || _pixelBuffer == null) return const SizedBox.shrink();

    final screenSize = MediaQuery.of(context).size;
    final scaleX = _image!.width / screenSize.width;
    final scaleY = _image!.height / screenSize.height;

    final px = (pos.dx * scaleX).round().clamp(0, _pixelBuffer!.width - 1);
    final py = (pos.dy * scaleY).round().clamp(0, _pixelBuffer!.height - 1);
    final pixel = _pixelBuffer!.getPixel(px, py);
    final hex =
        '#${pixel.r.toInt().toRadixString(16).padLeft(2, '0')}'
                '${pixel.g.toInt().toRadixString(16).padLeft(2, '0')}'
                '${pixel.b.toInt().toRadixString(16).padLeft(2, '0')}'
            .toUpperCase();

    const boxWidth = 140.0;
    const magSize = 140.0;

    double left = pos.dx + 14;
    double top = pos.dy + 14;

    if (left + boxWidth > screenSize.width) {
      left = pos.dx - boxWidth - 14;
    }
    if (top + 220 > screenSize.height) {
      top = pos.dy - 220 - 14;
    }
    if (left < 0) left = 0;
    if (top < 0) top = 0;

    return Positioned(
      left: left,
      top: top,
      child: IgnorePointer(
        child: RepaintBoundary(
          child: Container(
            width: boxWidth,
            decoration: BoxDecoration(
              color: const Color(0xFFF8F9FA),
              borderRadius: BorderRadius.circular(ScreenshotStyle.radius + 4),
              border: Border.all(color: Colors.grey.withValues(alpha: 0.2)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.15),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.vertical(
                    top: Radius.circular(ScreenshotStyle.radius + 3),
                  ),
                  child: SizedBox(
                    width: magSize,
                    height: magSize,
                    child: CustomPaint(
                      painter: MagnifierPainter(
                        image: _image!,
                        position: pos,
                        scaleX: scaleX,
                        scaleY: scaleY,
                      ),
                    ),
                  ),
                ),
                const Divider(
                  height: 1,
                  thickness: 1,
                  color: Color(0xFFE5E7EB),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _infoRow('坐标', '$px, $py'),
                      const SizedBox(height: 6),
                      _infoRow('色值', hex),
                      const SizedBox(height: 8),
                      const Text(
                        '按 ⌘+C 复制色值',
                        style: TextStyle(
                          fontSize: 10,
                          color: Color(0xFF9CA3AF),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: Color(0xFF4B5563)),
        ),
        Text(
          value,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w400,
            color: Color(0xFF111827),
          ),
        ),
      ],
    );
  }

  Widget _buildTextInput() {
    return Transform.translate(
      offset: const Offset(-12, -10),
      child: IntrinsicWidth(
        child: IntrinsicHeight(
          child: CustomPaint(
            painter: DashedBorderPainter(color: _currentColor),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: TextField(
                controller: _textController,
                focusNode: _textFocusNode,
                autofocus: true,
                maxLines: null,
                keyboardType: TextInputType.multiline,
                cursorColor: _currentColor,
                cursorWidth: 3.0,
                cursorHeight: 28.0,
                style: TextStyle(
                  color: _currentColor,
                  fontSize: 24,
                  fontWeight: FontWeight.w400,
                  height: 1.2,
                  shadows: [
                    Shadow(
                      color: Colors.black.withValues(alpha: 0.6),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                decoration: const InputDecoration(
                  hintText: '输入文字…',
                  hintStyle: TextStyle(
                    color: Color(0x66FFFFFF),
                    fontSize: 22,
                    fontWeight: FontWeight.normal,
                  ),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ─────────────────────── 手势处理 ───────────────────────

  void _updateHoveredWindow(Offset pos) {
    if (_selection != null || _logicalWindowBounds.isEmpty) {
      if (_hoveredWindowRect != null) {
        setState(() => _hoveredWindowRect = null);
      }
      return;
    }

    Rect? best;
    for (int i = 0; i < _logicalWindowBounds.length; i++) {
      final rect = _logicalWindowBounds[i];
      if (rect.contains(pos)) {
        best = rect;
        break;
      }
    }

    if (best != _hoveredWindowRect) {
      setState(() => _hoveredWindowRect = best);
    }
  }

  void _onPanStart(DragStartDetails details) {
    _hoverPosition.value = details.localPosition;
    if (_showStrokePopover) {
      setState(() => _showStrokePopover = false);
    }
    if (_isEditingText) {
      _confirmTextInput();
      return;
    }

    final pos = details.localPosition;

    if (_selection != null &&
        _showToolbar &&
        _currentTool == DrawingTool.none) {
      final handle = _getHandleAtPosition(pos);
      if (handle != null) {
        _activeHandle = handle;
        _dragStartOffset = pos;
        _dragStartRect = _normalizedSelection;
        return;
      }

      final rect = _normalizedSelection;
      if (rect.contains(pos)) {
        _isDraggingSelection = true;
        _dragSelectionStart = pos;
        _dragSelectionOriginal = rect;
        return;
      }
    }

    if (_selection != null && _currentTool != DrawingTool.none) {
      final rect = _normalizedSelection;
      if (rect.contains(pos)) {
        if (_currentTool == DrawingTool.text) {
          _showTextInputAt(pos);
          return;
        }
        if (_currentTool == DrawingTool.number) {
          _addNumberMarker(pos);
          return;
        }
        if (_currentTool == DrawingTool.pen ||
            _currentTool == DrawingTool.mosaic) {
          setState(() {
            _isDrawingShape = true;
            _currentShape = DrawingShape(
              tool: _currentTool,
              start: pos,
              end: pos,
              color: _currentColor,
              strokeWidth: _currentTool == DrawingTool.mosaic
                  ? 28.0
                  : _currentStrokeWidth,
              points: [pos],
            );
          });
          return;
        }
        setState(() {
          _isDrawingShape = true;
          _currentShape = DrawingShape(
            tool: _currentTool,
            start: pos,
            end: pos,
            color: _currentColor,
            strokeWidth: _currentStrokeWidth,
          );
        });
        return;
      }
    }

    _pendingWindowRect = _hoveredWindowRect;
    setState(() {
      _isDrawingSelection = true;
      _selectionStart = pos;
      _selection = Rect.fromPoints(pos, pos);
      _showToolbar = false;
      _shapes.clear();
      _redoStack.clear();
      _currentTool = DrawingTool.none;
      _nextNumber = 1;
    });
  }

  void _onPanUpdate(DragUpdateDetails details) {
    final pos = details.localPosition;
    _hoverPosition.value = pos;

    if (_activeHandle != null && _dragStartRect != null) {
      setState(() {
        _selection = _resizeSelection(
          _dragStartRect!,
          _activeHandle!,
          pos - _dragStartOffset!,
        );
      });
    } else if (_isDraggingSelection &&
        _dragSelectionOriginal != null &&
        _dragSelectionStart != null) {
      final delta = pos - _dragSelectionStart!;
      setState(() {
        _selection = _dragSelectionOriginal!.shift(delta);
      });
    } else if (_isDrawingShape && _currentShape != null) {
      setState(() {
        if (_currentShape!.tool == DrawingTool.pen ||
            _currentShape!.tool == DrawingTool.mosaic) {
          final newPoints = List<Offset>.from(_currentShape!.points)..add(pos);
          _currentShape = _currentShape!.copyWith(end: pos, points: newPoints);
        } else {
          _currentShape = _currentShape!.copyWith(end: pos);
        }
      });
    } else if (_isDrawingSelection && _selectionStart != null) {
      if (_hoveredWindowRect != null) {
        setState(() => _hoveredWindowRect = null);
      }
      setState(() {
        _selection = Rect.fromPoints(_selectionStart!, pos);
      });
    }
  }

  void _onPanEnd(DragEndDetails details) {
    if (_activeHandle != null) {
      _activeHandle = null;
      _dragStartOffset = null;
      _dragStartRect = null;
    } else if (_isDraggingSelection) {
      _isDraggingSelection = false;
      _dragSelectionStart = null;
      _dragSelectionOriginal = null;
    } else if (_isDrawingShape && _currentShape != null) {
      setState(() {
        _shapes.add(_currentShape!);
        _redoStack.clear();
        _currentShape = null;
        _isDrawingShape = false;
      });
    } else if (_isDrawingSelection) {
      _isDrawingSelection = false;

      final sel = _selection;
      final dragDist = (sel != null)
          ? math.sqrt(sel.width * sel.width + sel.height * sel.height)
          : 0.0;

      if (dragDist < 8 && _pendingWindowRect != null) {
        setState(() {
          _selection = _pendingWindowRect;
          _hoveredWindowRect = null;
          _pendingWindowRect = null;
          _showToolbar = true;
        });
      } else if (sel != null && sel.width.abs() > 10 && sel.height.abs() > 10) {
        setState(() {
          _hoveredWindowRect = null;
          _pendingWindowRect = null;
          _showToolbar = true;
        });
      } else {
        setState(() {
          _selection = null;
          _hoveredWindowRect = null;
          _pendingWindowRect = null;
        });
      }

      _selectionStart = null;
    }
  }

  // ─────────────────────── 工具操作 ───────────────────────

  void _undo() {
    if (_shapes.isEmpty) return;
    final removed = _shapes.last;
    setState(() {
      _shapes.removeLast();
      _redoStack.add(removed);
      if (removed.tool == DrawingTool.number) {
        _nextNumber = math.max(1, _nextNumber - 1);
      }
    });
  }

  void _redo() {
    if (_redoStack.isEmpty) return;
    final restored = _redoStack.removeLast();
    setState(() {
      _shapes.add(restored);
      if (restored.tool == DrawingTool.number) {
        _nextNumber++;
      }
    });
  }

  void _clearAll() {
    if (_shapes.isEmpty && _redoStack.isEmpty && _nextNumber == 1) return;
    setState(() {
      _shapes.clear();
      _redoStack.clear();
      _nextNumber = 1;
    });
  }

  void _selectTool(DrawingTool tool) {
    setState(() {
      _currentTool = _currentTool == tool ? DrawingTool.none : tool;
      _showStrokePopover = false;
    });
  }

  void _addNumberMarker(Offset position) {
    setState(() {
      _shapes.add(
        DrawingShape(
          tool: DrawingTool.number,
          start: position,
          end: position,
          color: _currentColor,
          strokeWidth: 3.0,
          numberIndex: _nextNumber,
        ),
      );
      _redoStack.clear();
      _nextNumber++;
    });
  }

  void _showTextInputAt(Offset position) {
    setState(() {
      _isEditingText = true;
      _textPosition = position;
      _textController.clear();
    });
    Future.delayed(const Duration(milliseconds: 100), () {
      _textFocusNode.requestFocus();
    });
  }

  void _confirmTextInput() {
    if (_textController.text.isNotEmpty && _textPosition != null) {
      setState(() {
        _shapes.add(
          DrawingShape(
            tool: DrawingTool.text,
            start: _textPosition!,
            end: _textPosition!,
            color: _currentColor,
            strokeWidth: 24.0,
            text: _textController.text,
          ),
        );
        _redoStack.clear();
      });
    }
    _cancelTextInput();
  }

  void _cancelTextInput() {
    setState(() {
      _isEditingText = false;
      _textPosition = null;
      _textController.clear();
    });
  }

  // ─────────────────────── 选区管理 ───────────────────────

  Rect get _normalizedSelection {
    if (_selection == null) return Rect.zero;
    return Rect.fromLTRB(
      math.min(_selection!.left, _selection!.right),
      math.min(_selection!.top, _selection!.bottom),
      math.max(_selection!.left, _selection!.right),
      math.max(_selection!.top, _selection!.bottom),
    );
  }

  Rect _resizeSelection(Rect original, HandlePosition handle, Offset delta) {
    double left = original.left;
    double top = original.top;
    double right = original.right;
    double bottom = original.bottom;

    switch (handle) {
      case HandlePosition.topLeft:
        left += delta.dx;
        top += delta.dy;
      case HandlePosition.topCenter:
        top += delta.dy;
      case HandlePosition.topRight:
        right += delta.dx;
        top += delta.dy;
      case HandlePosition.middleLeft:
        left += delta.dx;
      case HandlePosition.middleRight:
        right += delta.dx;
      case HandlePosition.bottomLeft:
        left += delta.dx;
        bottom += delta.dy;
      case HandlePosition.bottomCenter:
        bottom += delta.dy;
      case HandlePosition.bottomRight:
        right += delta.dx;
        bottom += delta.dy;
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }

  HandlePosition? _getHandleAtPosition(Offset pos) {
    if (_selection == null) return null;
    const handleSize = 12.0;
    final rect = _normalizedSelection;

    final handles = {
      HandlePosition.topLeft: rect.topLeft,
      HandlePosition.topCenter: Offset(rect.center.dx, rect.top),
      HandlePosition.topRight: rect.topRight,
      HandlePosition.middleLeft: Offset(rect.left, rect.center.dy),
      HandlePosition.middleRight: Offset(rect.right, rect.center.dy),
      HandlePosition.bottomLeft: rect.bottomLeft,
      HandlePosition.bottomCenter: Offset(rect.center.dx, rect.bottom),
      HandlePosition.bottomRight: rect.bottomRight,
    };

    for (final entry in handles.entries) {
      if ((pos - entry.value).distance < handleSize) {
        return entry.key;
      }
    }
    return null;
  }

  // ─────────────────────── UI 构建 ───────────────────────

  List<Widget> _buildResizeHandles() {
    final rect = _normalizedSelection;
    const size = 10.0;

    final positions = [
      (rect.topLeft, HandlePosition.topLeft, SystemMouseCursors.resizeUpLeft),
      (
        Offset(rect.center.dx, rect.top),
        HandlePosition.topCenter,
        SystemMouseCursors.resizeUp,
      ),
      (
        rect.topRight,
        HandlePosition.topRight,
        SystemMouseCursors.resizeUpRight,
      ),
      (
        Offset(rect.left, rect.center.dy),
        HandlePosition.middleLeft,
        SystemMouseCursors.resizeLeft,
      ),
      (
        Offset(rect.right, rect.center.dy),
        HandlePosition.middleRight,
        SystemMouseCursors.resizeRight,
      ),
      (
        rect.bottomLeft,
        HandlePosition.bottomLeft,
        SystemMouseCursors.resizeDownLeft,
      ),
      (
        Offset(rect.center.dx, rect.bottom),
        HandlePosition.bottomCenter,
        SystemMouseCursors.resizeDown,
      ),
      (
        rect.bottomRight,
        HandlePosition.bottomRight,
        SystemMouseCursors.resizeDownRight,
      ),
    ];

    return positions.map((p) {
      return Positioned(
        left: p.$1.dx - size / 2,
        top: p.$1.dy - size / 2,
        child: MouseRegion(
          cursor: p.$3,
          child: GestureDetector(
            onPanStart: (details) {
              _activeHandle = p.$2;
              _dragStartOffset = details.globalPosition;
              _dragStartRect = _normalizedSelection;
            },
            onPanUpdate: (details) {
              if (_activeHandle != null && _dragStartRect != null) {
                setState(() {
                  _selection = _resizeSelection(
                    _dragStartRect!,
                    _activeHandle!,
                    details.globalPosition - _dragStartOffset!,
                  );
                });
              }
            },
            onPanEnd: (_) {
              _activeHandle = null;
              _dragStartOffset = null;
              _dragStartRect = null;
            },
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: ScreenshotStyle.accent, width: 1.5),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
                    blurRadius: 2,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }).toList();
  }

  Widget _buildSizeIndicator() {
    final rect = _normalizedSelection;
    final width = rect.width.toInt();
    final height = rect.height.toInt();

    double top = rect.top - 30;
    if (top < 0) top = rect.bottom + 8;

    return Positioned(
      left: rect.left,
      top: top,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: ScreenshotStyle.toolbarBg,
          borderRadius: BorderRadius.circular(6),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Text(
          '$width × $height',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w400,
            letterSpacing: 0.3,
          ),
        ),
      ),
    );
  }

  /// 需要线宽调节的工具
  bool get _supportsStrokeWidth =>
      _currentTool == DrawingTool.rectangle ||
      _currentTool == DrawingTool.circle ||
      _currentTool == DrawingTool.arrow ||
      _currentTool == DrawingTool.line ||
      _currentTool == DrawingTool.pen;

  Widget _buildToolbar() {
    final rect = _normalizedSelection;
    final screenSize = MediaQuery.of(context).size;

    const gap = 12.0;

    // 动态决定高度预估
    double estimatedHeight = 44.0;
    if (_showStrokePopover && _supportsStrokeWidth) {
      estimatedHeight += 46.0;
    }

    double toolbarTop;
    if (rect.bottom + gap + estimatedHeight <= screenSize.height) {
      toolbarTop = rect.bottom + gap;
    } else if (rect.top - gap - estimatedHeight >= 0) {
      toolbarTop = rect.top - gap - estimatedHeight;
    } else {
      toolbarTop = rect.bottom - gap - estimatedHeight;
    }
    toolbarTop = toolbarTop.clamp(
      gap,
      screenSize.height - estimatedHeight - gap,
    );

    // 动态决定横向对齐方式，彻底消除宽度硬编码导致的溢出问题
    bool isLeftHalf = rect.center.dx < screenSize.width / 2;
    double? leftPos;
    double? rightPos;

    if (isLeftHalf) {
      leftPos = rect.left;
      if (leftPos < gap) leftPos = gap;
    } else {
      rightPos = screenSize.width - rect.right;
      if (rightPos < gap) rightPos = gap;
    }

    return Positioned(
      left: leftPos,
      right: rightPos,
      top: toolbarTop,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: screenSize.width - 2 * gap),
        child: Column(
          crossAxisAlignment: isLeftHalf
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.end,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: ScreenshotStyle.toolbarBg,
                borderRadius: BorderRadius.circular(ScreenshotStyle.radius),
                border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.45),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ToolButton(
                      icon: Icons.crop_square_outlined,
                      tooltip: '矩形 (R)',
                      isSelected: _currentTool == DrawingTool.rectangle,
                      onTap: () => _selectTool(DrawingTool.rectangle),
                    ),
                    ToolButton(
                      icon: Icons.radio_button_unchecked,
                      tooltip: '圆形 (O)',
                      isSelected: _currentTool == DrawingTool.circle,
                      onTap: () => _selectTool(DrawingTool.circle),
                    ),
                    ToolButton(
                      icon: Icons.north_east,
                      tooltip: '箭头 (A)',
                      isSelected: _currentTool == DrawingTool.arrow,
                      onTap: () => _selectTool(DrawingTool.arrow),
                    ),
                    ToolButton(
                      icon: Icons.horizontal_rule,
                      tooltip: '线条 (L)',
                      isSelected: _currentTool == DrawingTool.line,
                      onTap: () => _selectTool(DrawingTool.line),
                    ),
                    ToolButton(
                      icon: Icons.edit_outlined,
                      tooltip: '画笔 (P)',
                      isSelected: _currentTool == DrawingTool.pen,
                      onTap: () => _selectTool(DrawingTool.pen),
                    ),
                    ToolButton(
                      icon: Icons.blur_on,
                      tooltip: '马赛克 (M)',
                      isSelected: _currentTool == DrawingTool.mosaic,
                      onTap: () => _selectTool(DrawingTool.mosaic),
                    ),
                    ToolButton(
                      icon: Icons.title,
                      tooltip: '文字 (T)',
                      isSelected: _currentTool == DrawingTool.text,
                      onTap: () => _selectTool(DrawingTool.text),
                    ),
                    ToolButton(
                      icon: Icons.pin,
                      tooltip: '编号 $_nextNumber (N)',
                      isSelected: _currentTool == DrawingTool.number,
                      onTap: () => _selectTool(DrawingTool.number),
                    ),
                    const ToolDivider(),
                    // 线宽调节
                    ToolButton(
                      icon: Icons.line_weight,
                      tooltip: '线宽 ${_currentStrokeWidth.toStringAsFixed(0)}',
                      isEnabled: _supportsStrokeWidth,
                      isSelected: _showStrokePopover,
                      onTap: () => setState(
                        () => _showStrokePopover = !_showStrokePopover,
                      ),
                    ),
                    const ToolDivider(),
                    for (final c in [
                      Colors.red,
                      const Color(0xFFFF6B35),
                      const Color(0xFFFACC15),
                      const Color(0xFF22C55E),
                      const Color(0xFF3B82F6),
                      Colors.white,
                    ])
                      ColorButton(
                        color: c,
                        isSelected: _currentColor == c,
                        onTap: () => setState(() => _currentColor = c),
                      ),
                    const ToolDivider(),
                    ToolButton(
                      icon: Icons.undo,
                      tooltip: '撤销 (⌘Z)',
                      onTap: _shapes.isNotEmpty ? _undo : null,
                      isEnabled: _shapes.isNotEmpty,
                    ),
                    ToolButton(
                      icon: Icons.redo,
                      tooltip: '重做 (⌘⇧Z)',
                      onTap: _redoStack.isNotEmpty ? _redo : null,
                      isEnabled: _redoStack.isNotEmpty,
                    ),
                    ToolButton(
                      icon: Icons.delete_outline,
                      tooltip: '清空所有标注',
                      onTap: _shapes.isNotEmpty ? _clearAll : null,
                      isEnabled: _shapes.isNotEmpty,
                    ),
                    const ToolDivider(),
                    ToolButton(
                      icon: Icons.push_pin_outlined,
                      tooltip: '贴图 - 置顶浮窗',
                      onTap: _pinToScreen,
                    ),
                    ToolButton(
                      icon: Icons.document_scanner_outlined,
                      tooltip: 'OCR 文字识别',
                      onTap: _performOCR,
                    ),
                    ToolButton(
                      icon: Icons.content_copy,
                      tooltip: '复制到剪贴板',
                      onTap: _copyToClipboard,
                    ),
                    ToolButton(
                      icon: Icons.save_alt,
                      tooltip: '保存到桌面',
                      onTap: _saveToDesktop,
                    ),
                    const ToolDivider(),
                    ToolButton(
                      icon: Icons.close,
                      tooltip: '取消 (Esc)',
                      onTap: widget.onCancel,
                      color: ScreenshotStyle.danger,
                    ),
                    ToolButton(
                      icon: Icons.check,
                      tooltip: '确认 (Enter)',
                      onTap: _confirmSelection,
                      color: ScreenshotStyle.success,
                    ),
                  ],
                ),
              ),
            ),
            if (_showStrokePopover && _supportsStrokeWidth)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: StrokeWidthPopover(
                  value: _currentStrokeWidth,
                  onChanged: (v) => setState(() => _currentStrokeWidth = v),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ─────────────────────── 操作回调 ───────────────────────

  void _flushPendingEdits() {
    if (_isEditingText) {
      _confirmTextInput();
    }
  }

  Future<void> _confirmSelection() async {
    _flushPendingEdits();
    final cropped = await _cropImage();
    if (cropped != null) {
      widget.onComplete?.call(cropped);
    }
  }

  Future<void> _saveToDesktop() async {
    _flushPendingEdits();
    final cropped = await _cropImage();
    if (cropped != null) {
      widget.onSave?.call(cropped);
    }
  }

  Future<void> _performOCR() async {
    _flushPendingEdits();
    final cropped = await _cropImage();
    if (cropped != null) {
      widget.onOCR?.call(cropped);
    }
  }

  Future<void> _pinToScreen() async {
    _flushPendingEdits();
    final cropped = await _cropImage();
    if (cropped != null) {
      widget.onPin?.call(cropped);
    }
  }

  Future<void> _copyToClipboard() async {
    _flushPendingEdits();
    final cropped = await _cropImage();
    if (cropped == null) return;

    final success = await ScreenshotService().copyImageToClipboard(cropped);
    if (success && mounted) {
      AppToast.show(
        context: context,
        style: ToastificationStyle.flat,
        applyBlurEffect: true,
        title: const Text(
          '已复制到剪贴板',
          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w400),
        ),
        type: ToastificationType.success,
        autoCloseDuration: const Duration(seconds: 1),
      );
    }
  }

  // ─────────────────────── 图像裁剪 ───────────────────────

  Future<Uint8List?> _cropImage() async {
    if (_image == null || _selection == null) return null;

    final rect = _normalizedSelection;
    final size = MediaQuery.of(context).size;

    final imageWidth = _image!.width.toDouble();
    final imageHeight = _image!.height.toDouble();
    final scaleX = imageWidth / size.width;
    final scaleY = imageHeight / size.height;

    final srcRect = Rect.fromLTRB(
      rect.left * scaleX,
      rect.top * scaleY,
      rect.right * scaleX,
      rect.bottom * scaleY,
    );

    if (_pixelBuffer != null) {
      try {
        final result = await _cropWithImagePackage(
          srcRect,
          rect,
          scaleX,
          scaleY,
        );
        if (result != null) return result;
      } catch (_) {}
    }

    return _cropWithCanvas(srcRect, rect, scaleX, scaleY);
  }

  Future<Uint8List?> _cropWithImagePackage(
    Rect srcRect,
    Rect selectionRect,
    double scaleX,
    double scaleY,
  ) async {
    final mosaicPng = await compute(_cropInIsolate, {
      'pixelBuffer': _pixelBuffer!,
      'srcRect': [srcRect.left, srcRect.top, srcRect.right, srcRect.bottom],
      'selectionRect': [
        selectionRect.left,
        selectionRect.top,
        selectionRect.right,
        selectionRect.bottom,
      ],
      'scaleX': scaleX,
      'scaleY': scaleY,
      'shapes': _shapes
          .map(
            (s) => {
              'tool': s.tool.index,
              'points': s.points.map((p) => [p.dx, p.dy]).toList(),
              'strokeWidth': s.strokeWidth,
            },
          )
          .toList(),
      'mosaicBlockSize': _mosaicBlockSize,
    });

    if (mosaicPng == null) return null;

    final hasNonMosaicShapes = _shapes.any((s) => s.tool != DrawingTool.mosaic);
    if (!hasNonMosaicShapes) {
      return mosaicPng;
    }

    final codec = await ui.instantiateImageCodec(mosaicPng);
    final frame = await codec.getNextFrame();
    final baseImage = frame.image;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    canvas.drawImage(baseImage, Offset.zero, Paint());

    for (final shape in _shapes) {
      if (shape.tool == DrawingTool.mosaic) continue;
      _drawShapeOnCanvas(canvas, shape, selectionRect, scaleX, scaleY);
    }

    final picture = recorder.endRecording();
    final finalImage = await picture.toImage(baseImage.width, baseImage.height);

    final byteData = await finalImage.toByteData(
      format: ui.ImageByteFormat.png,
    );
    return byteData?.buffer.asUint8List();
  }

  static Uint8List? _cropInIsolate(Map<String, dynamic> params) {
    final pixelBuffer = params['pixelBuffer'] as img.Image;
    final srcRectList = params['srcRect'] as List<double>;
    final selRectList = params['selectionRect'] as List<double>;
    final scaleX = params['scaleX'] as double;
    final scaleY = params['scaleY'] as double;
    final shapesData = params['shapes'] as List<dynamic>;
    final mosaicBlockSize = params['mosaicBlockSize'] as double;

    final srcLeft = srcRectList[0].round().clamp(0, pixelBuffer.width - 1);
    final srcTop = srcRectList[1].round().clamp(0, pixelBuffer.height - 1);
    final srcWidth = (srcRectList[2] - srcRectList[0]).round().clamp(
      1,
      pixelBuffer.width - srcLeft,
    );
    final srcHeight = (srcRectList[3] - srcRectList[1]).round().clamp(
      1,
      pixelBuffer.height - srcTop,
    );

    var cropped = img.copyCrop(
      pixelBuffer,
      x: srcLeft,
      y: srcTop,
      width: srcWidth,
      height: srcHeight,
    );

    final processedBlocks = <int>{};
    for (final shapeData in shapesData) {
      final toolIndex = shapeData['tool'] as int;
      if (toolIndex != DrawingTool.mosaic.index) continue;

      final points = shapeData['points'] as List<dynamic>;
      final strokeW = (shapeData['strokeWidth'] as double) * scaleX;
      final halfStroke = strokeW / 2;
      final blockSize = (mosaicBlockSize * scaleX).round().clamp(4, 50);

      for (final pt in points) {
        final pList = pt as List<dynamic>;
        final px = ((pList[0] as double) - selRectList[0]) * scaleX;
        final py = ((pList[1] as double) - selRectList[1]) * scaleY;

        final bxMin = ((px - halfStroke) / blockSize).floor();
        final byMin = ((py - halfStroke) / blockSize).floor();
        final bxMax = ((px + halfStroke) / blockSize).ceil();
        final byMax = ((py + halfStroke) / blockSize).ceil();

        for (int by = byMin; by < byMax; by++) {
          for (int bx = bxMin; bx < bxMax; bx++) {
            final key = by * 100000 + bx;
            if (!processedBlocks.add(key)) continue;

            final x0 = (bx * blockSize).clamp(0, cropped.width - 1);
            final y0 = (by * blockSize).clamp(0, cropped.height - 1);
            final x1 = ((bx + 1) * blockSize).clamp(0, cropped.width);
            final y1 = ((by + 1) * blockSize).clamp(0, cropped.height);
            if (x0 >= x1 || y0 >= y1) continue;

            final scx = ((x0 + x1) ~/ 2).clamp(0, cropped.width - 1);
            final scy = ((y0 + y1) ~/ 2).clamp(0, cropped.height - 1);
            final pixel = cropped.getPixel(scx, scy);

            for (int dy = y0; dy < y1; dy++) {
              for (int dx = x0; dx < x1; dx++) {
                cropped.setPixel(dx, dy, pixel);
              }
            }
          }
        }
      }
    }

    return img.encodePng(cropped);
  }

  Future<Uint8List?> _cropWithCanvas(
    Rect srcRect,
    Rect selectionRect,
    double scaleX,
    double scaleY,
  ) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    canvas.drawImageRect(
      _image!,
      srcRect,
      Rect.fromLTWH(0, 0, srcRect.width, srcRect.height),
      Paint(),
    );

    for (final shape in _shapes) {
      _drawShapeOnCanvas(canvas, shape, selectionRect, scaleX, scaleY);
    }

    final picture = recorder.endRecording();
    final croppedImage = await picture.toImage(
      srcRect.width.toInt(),
      srcRect.height.toInt(),
    );

    final byteData = await croppedImage.toByteData(
      format: ui.ImageByteFormat.png,
    );
    return byteData?.buffer.asUint8List();
  }

  void _drawShapeOnCanvas(
    Canvas canvas,
    DrawingShape shape,
    Rect selectionRect,
    double scaleX,
    double scaleY,
  ) {
    final paint = Paint()
      ..color = shape.color
      ..style = PaintingStyle.stroke
      ..strokeWidth = shape.strokeWidth * scaleX
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final start = Offset(
      (shape.start.dx - selectionRect.left) * scaleX,
      (shape.start.dy - selectionRect.top) * scaleY,
    );
    final end = Offset(
      (shape.end.dx - selectionRect.left) * scaleX,
      (shape.end.dy - selectionRect.top) * scaleY,
    );

    switch (shape.tool) {
      case DrawingTool.rectangle:
        canvas.drawRect(Rect.fromPoints(start, end), paint);
      case DrawingTool.circle:
        canvas.drawOval(Rect.fromPoints(start, end), paint);
      case DrawingTool.line:
        canvas.drawLine(start, end, paint);
      case DrawingTool.arrow:
        drawArrow(
          canvas,
          start,
          end,
          shape.color,
          shape.strokeWidth * scaleX,
          scale: scaleX,
        );
      case DrawingTool.pen:
        _drawPenOnCanvas(canvas, shape, selectionRect, scaleX, scaleY, paint);
      case DrawingTool.number:
        drawNumberMarker(
          canvas,
          start,
          shape.numberIndex ?? 0,
          shape.color,
          scale: scaleX,
        );
      case DrawingTool.text:
        if (shape.text != null && shape.text!.isNotEmpty) {
          drawText(
            canvas,
            start,
            shape.text!,
            shape.color,
            shape.strokeWidth * scaleX,
          );
        }
      case DrawingTool.mosaic:
      case DrawingTool.none:
        break;
    }
  }

  void _drawPenOnCanvas(
    Canvas canvas,
    DrawingShape shape,
    Rect selectionRect,
    double scaleX,
    double scaleY,
    Paint paint,
  ) {
    if (shape.points.length < 2) return;
    paint.style = PaintingStyle.stroke;
    paint.strokeCap = StrokeCap.round;
    paint.strokeJoin = StrokeJoin.round;

    final path = Path();
    final first = Offset(
      (shape.points[0].dx - selectionRect.left) * scaleX,
      (shape.points[0].dy - selectionRect.top) * scaleY,
    );
    path.moveTo(first.dx, first.dy);

    for (int i = 1; i < shape.points.length; i++) {
      final p = Offset(
        (shape.points[i].dx - selectionRect.left) * scaleX,
        (shape.points[i].dy - selectionRect.top) * scaleY,
      );
      path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(path, paint);
  }
}
