import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

// ═════════════════════════ 数据模型 ═════════════════════════

/// 绘图工具类型
enum DrawingTool {
  none,
  rectangle,
  circle,
  arrow,
  line,
  pen,
  mosaic,
  text,
  number,
}

/// 选区调整手柄位置
enum HandlePosition {
  topLeft,
  topCenter,
  topRight,
  middleLeft,
  middleRight,
  bottomLeft,
  bottomCenter,
  bottomRight,
}

/// 绘制的形状
class DrawingShape {
  final DrawingTool tool;
  final Offset start;
  final Offset end;
  final Color color;
  final double strokeWidth;
  final String? text;

  /// 自由画笔的路径点
  final List<Offset> points;

  /// 数字编号标记的序号
  final int? numberIndex;

  DrawingShape({
    required this.tool,
    required this.start,
    required this.end,
    this.color = Colors.red,
    this.strokeWidth = 2.0,
    this.text,
    this.points = const [],
    this.numberIndex,
  });

  DrawingShape copyWith({Offset? end, List<Offset>? points}) {
    return DrawingShape(
      tool: tool,
      start: start,
      end: end ?? this.end,
      color: color,
      strokeWidth: strokeWidth,
      text: text,
      points: points ?? this.points,
      numberIndex: numberIndex,
    );
  }
}

// ═════════════════════════ 样式常量 ═════════════════════════

class ScreenshotStyle {
  static const Color accent = Color(0xFF3B82F6);
  static const Color danger = Color(0xFFEF4444);
  static const Color success = Color(0xFF22C55E);
  static const Color toolbarBg = Color(0xF2262626);
  static const Color toolbarBgHover = Color(0x1AFFFFFF);
  static const Color toolbarDivider = Color(0x33FFFFFF);
  static const double radius = 8.0;
}

// ═════════════════════════ Painter ═════════════════════════

/// 截图绘制器 — 支持真实马赛克
class ScreenshotPainter extends CustomPainter {
  final ui.Image image;
  final img.Image? pixelBuffer;
  final ui.Image? mosaicImage;
  final Rect? selection;
  final List<DrawingShape> shapes;
  final DrawingShape? currentShape;
  final Rect? hoveredWindowRect;

  ScreenshotPainter({
    required this.image,
    this.pixelBuffer,
    this.mosaicImage,
    this.selection,
    this.shapes = const [],
    this.currentShape,
    this.hoveredWindowRect,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final srcRect = Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    final dstRect = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.drawImageRect(image, srcRect, dstRect, Paint());

    final overlayPaint = Paint()..color = Colors.black.withValues(alpha: 0.5);

    if (selection != null) {
      final rect = Rect.fromLTRB(
        math.min(selection!.left, selection!.right),
        math.min(selection!.top, selection!.bottom),
        math.max(selection!.left, selection!.right),
        math.max(selection!.top, selection!.bottom),
      );

      final path = Path()
        ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
        ..addRect(rect)
        ..fillType = PathFillType.evenOdd;
      canvas.drawPath(path, overlayPaint);

      final borderPaint = Paint()
        ..color = ScreenshotStyle.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      canvas.drawRect(rect, borderPaint);

      for (final shape in shapes) {
        _drawShape(canvas, shape, size);
      }
      if (currentShape != null) {
        _drawShape(canvas, currentShape!, size);
      }
    } else if (hoveredWindowRect != null) {
      final windowRect = hoveredWindowRect!.intersect(dstRect);

      final path = Path()
        ..addRect(dstRect)
        ..addRect(windowRect)
        ..fillType = PathFillType.evenOdd;
      canvas.drawPath(path, overlayPaint);

      final borderPaint = Paint()
        ..color = ScreenshotStyle.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5;
      canvas.drawRect(windowRect, borderPaint);
    } else {
      canvas.drawRect(dstRect, overlayPaint);
    }
  }

  void _drawShape(Canvas canvas, DrawingShape shape, Size canvasSize) {
    final paint = Paint()
      ..color = shape.color
      ..style = PaintingStyle.stroke
      ..strokeWidth = shape.strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    switch (shape.tool) {
      case DrawingTool.rectangle:
        canvas.drawRect(Rect.fromPoints(shape.start, shape.end), paint);
      case DrawingTool.circle:
        canvas.drawOval(Rect.fromPoints(shape.start, shape.end), paint);
      case DrawingTool.line:
        canvas.drawLine(shape.start, shape.end, paint);
      case DrawingTool.arrow:
        drawArrow(
          canvas,
          shape.start,
          shape.end,
          shape.color,
          shape.strokeWidth,
        );
      case DrawingTool.pen:
        _drawPen(canvas, shape, paint);
      case DrawingTool.mosaic:
        _drawMosaic(canvas, shape, canvasSize);
      case DrawingTool.number:
        drawNumberMarker(
          canvas,
          shape.start,
          shape.numberIndex ?? 0,
          shape.color,
        );
      case DrawingTool.text:
        if (shape.text != null && shape.text!.isNotEmpty) {
          drawText(
            canvas,
            shape.start,
            shape.text!,
            shape.color,
            shape.strokeWidth,
          );
        }
      case DrawingTool.none:
        break;
    }
  }

  void _drawPen(Canvas canvas, DrawingShape shape, Paint paint) {
    if (shape.points.length < 2) return;
    paint.style = PaintingStyle.stroke;
    paint.strokeCap = StrokeCap.round;
    paint.strokeJoin = StrokeJoin.round;

    final path = Path();
    path.moveTo(shape.points[0].dx, shape.points[0].dy);
    for (int i = 1; i < shape.points.length; i++) {
      path.lineTo(shape.points[i].dx, shape.points[i].dy);
    }
    canvas.drawPath(path, paint);
  }

  void _drawMosaic(Canvas canvas, DrawingShape shape, Size canvasSize) {
    if (shape.points.isEmpty) return;

    const blockSize = 16.0;
    final halfStroke = shape.strokeWidth / 2;

    final drawn = <int>{};
    final rects = <Rect>[];

    for (final pt in shape.points) {
      final bxMin = ((pt.dx - halfStroke) / blockSize).floor();
      final byMin = ((pt.dy - halfStroke) / blockSize).floor();
      final bxMax = ((pt.dx + halfStroke) / blockSize).ceil();
      final byMax = ((pt.dy + halfStroke) / blockSize).ceil();

      for (int by = byMin; by < byMax; by++) {
        for (int bx = bxMin; bx < bxMax; bx++) {
          final key = by * 100000 + bx;
          if (!drawn.add(key)) continue;
          rects.add(
            Rect.fromLTWH(bx * blockSize, by * blockSize, blockSize, blockSize),
          );
        }
      }
    }

    if (rects.isEmpty) return;

    if (mosaicImage != null) {
      final scaleX = mosaicImage!.width.toDouble() / canvasSize.width;
      final scaleY = mosaicImage!.height.toDouble() / canvasSize.height;
      final paint = Paint()..filterQuality = FilterQuality.none;

      for (final rect in rects) {
        final srcRect = Rect.fromLTWH(
          rect.left * scaleX,
          rect.top * scaleY,
          rect.width * scaleX,
          rect.height * scaleY,
        );
        canvas.drawImageRect(mosaicImage!, srcRect, rect, paint);
      }
    } else if (pixelBuffer != null) {
      final scaleX = image.width.toDouble() / canvasSize.width;
      final scaleY = image.height.toDouble() / canvasSize.height;
      for (final rect in rects) {
        final cx = (rect.center.dx * scaleX).round().clamp(
          0,
          pixelBuffer!.width - 1,
        );
        final cy = (rect.center.dy * scaleY).round().clamp(
          0,
          pixelBuffer!.height - 1,
        );
        final pixel = pixelBuffer!.getPixel(cx, cy);
        canvas.drawRect(
          rect,
          Paint()
            ..color = Color.fromARGB(
              pixel.a.toInt(),
              pixel.r.toInt(),
              pixel.g.toInt(),
              pixel.b.toInt(),
            ),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant ScreenshotPainter oldDelegate) => true;
}

// ═════════════════════════ 共享绘制辅助 ═════════════════════════

/// 箭头 — 带填充三角尖端（Snipaste/微信风格）
void drawArrow(
  Canvas canvas,
  Offset start,
  Offset end,
  Color color,
  double strokeWidth, {
  double scale = 1.0,
}) {
  final length = (end - start).distance;
  if (length < 2) return;

  final angle = (end - start).direction;
  // 尖端大小根据线宽自适应
  final headLength = math.max(14.0 * scale, strokeWidth * 3.2);
  final headWidth = math.max(10.0 * scale, strokeWidth * 2.4);

  // 尖端不超过总长度
  final actualHeadLen = math.min(headLength, length * 0.7);

  // 线段：从起点画到「尖端底部」，留出空间给三角形
  final lineEnd =
      start + Offset.fromDirection(angle, length - actualHeadLen * 0.6);

  final linePaint = Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = strokeWidth
    ..strokeCap = StrokeCap.round;
  canvas.drawLine(start, lineEnd, linePaint);

  // 填充三角箭头
  final baseCenter = end - Offset.fromDirection(angle, actualHeadLen);
  final perpAngle = angle + math.pi / 2;
  final leftBase = baseCenter + Offset.fromDirection(perpAngle, headWidth / 2);
  final rightBase = baseCenter - Offset.fromDirection(perpAngle, headWidth / 2);

  final path = Path()
    ..moveTo(end.dx, end.dy)
    ..lineTo(leftBase.dx, leftBase.dy)
    ..lineTo(rightBase.dx, rightBase.dy)
    ..close();

  final fillPaint = Paint()
    ..color = color
    ..style = PaintingStyle.fill
    ..isAntiAlias = true;
  canvas.drawPath(path, fillPaint);
}

/// 数字编号圆标（带阴影、白色外环）
void drawNumberMarker(
  Canvas canvas,
  Offset center,
  int number,
  Color color, {
  double scale = 1.0,
}) {
  final radius = 14.0 * scale;

  // 阴影
  canvas.drawCircle(
    center.translate(0, 1.5 * scale),
    radius,
    Paint()
      ..color = Colors.black.withValues(alpha: 0.25)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 3 * scale),
  );

  // 实心底
  canvas.drawCircle(
    center,
    radius,
    Paint()
      ..color = color
      ..style = PaintingStyle.fill,
  );

  // 白色外环
  canvas.drawCircle(
    center,
    radius,
    Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0 * scale,
  );

  final tp = TextPainter(
    text: TextSpan(
      text: '$number',
      style: TextStyle(
        color: Colors.white,
        fontSize: 14.0 * scale,
        fontWeight: FontWeight.w400,
        height: 1.0,
      ),
    ),
    textDirection: TextDirection.ltr,
  );
  tp.layout();
  tp.paint(canvas, Offset(center.dx - tp.width / 2, center.dy - tp.height / 2));
}

void drawText(
  Canvas canvas,
  Offset position,
  String text,
  Color color,
  double fontSize,
) {
  final tp = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        color: color,
        fontSize: fontSize,
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
    ),
    textDirection: TextDirection.ltr,
  );
  tp.layout();
  tp.paint(canvas, position);
}

/// 文字输入框的虚线边框 + 圆形控制点
class DashedBorderPainter extends CustomPainter {
  final Color color;

  DashedBorderPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.35)
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;
    canvas.drawRect(rect, shadowPaint);

    final dashPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.9)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    const dashLen = 6.0;
    const gapLen = 4.0;

    _drawDashedLine(
      canvas,
      rect.topLeft,
      rect.topRight,
      dashPaint,
      dashLen,
      gapLen,
    );
    _drawDashedLine(
      canvas,
      rect.topRight,
      rect.bottomRight,
      dashPaint,
      dashLen,
      gapLen,
    );
    _drawDashedLine(
      canvas,
      rect.bottomRight,
      rect.bottomLeft,
      dashPaint,
      dashLen,
      gapLen,
    );
    _drawDashedLine(
      canvas,
      rect.bottomLeft,
      rect.topLeft,
      dashPaint,
      dashLen,
      gapLen,
    );

    const handleRadius = 2.5;
    final handleFill = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    final handleStroke = Paint()
      ..color = Colors.black.withValues(alpha: 0.3)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    final handles = [
      rect.topLeft,
      Offset(rect.center.dx, rect.top),
      rect.topRight,
      Offset(rect.left, rect.center.dy),
      Offset(rect.right, rect.center.dy),
      rect.bottomLeft,
      Offset(rect.center.dx, rect.bottom),
      rect.bottomRight,
    ];

    for (final pt in handles) {
      canvas.drawCircle(pt, handleRadius, handleFill);
      canvas.drawCircle(pt, handleRadius, handleStroke);
    }
  }

  void _drawDashedLine(
    Canvas canvas,
    Offset p1,
    Offset p2,
    Paint paint,
    double dashLen,
    double gapLen,
  ) {
    final dx = p2.dx - p1.dx;
    final dy = p2.dy - p1.dy;
    final totalLen = math.sqrt(dx * dx + dy * dy);
    if (totalLen == 0) return;

    final ux = dx / totalLen;
    final uy = dy / totalLen;

    double drawn = 0;
    bool isDash = true;
    while (drawn < totalLen) {
      final segLen = isDash ? dashLen : gapLen;
      final end = math.min(drawn + segLen, totalLen);
      if (isDash) {
        canvas.drawLine(
          Offset(p1.dx + ux * drawn, p1.dy + uy * drawn),
          Offset(p1.dx + ux * end, p1.dy + uy * end),
          paint,
        );
      }
      drawn = end;
      isDash = !isDash;
    }
  }

  @override
  bool shouldRepaint(DashedBorderPainter oldDelegate) =>
      oldDelegate.color != color;
}

class MagnifierPainter extends CustomPainter {
  final ui.Image image;
  final Offset position;
  final double scaleX;
  final double scaleY;

  MagnifierPainter({
    required this.image,
    required this.position,
    required this.scaleX,
    required this.scaleY,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const srcSize = 40.0;
    final cx = position.dx * scaleX;
    final cy = position.dy * scaleY;

    final srcRect = Rect.fromCenter(
      center: Offset(cx, cy),
      width: srcSize,
      height: srcSize,
    );
    final dstRect = Rect.fromLTWH(0, 0, size.width, size.height);

    final paint = Paint()..filterQuality = FilterQuality.none;
    canvas.drawImageRect(image, srcRect, dstRect, paint);

    final crossPaint = Paint()
      ..color = const Color(0xFF00C957)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    canvas.drawLine(
      Offset(size.width / 2, 0),
      Offset(size.width / 2, size.height),
      crossPaint,
    );
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      crossPaint,
    );
  }

  @override
  bool shouldRepaint(covariant MagnifierPainter old) {
    return old.position != position || old.image != image;
  }
}

// ═════════════════════════ UI 组件 ═════════════════════════

/// 工具栏按钮 — 带 hover 高亮
class ToolButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final Color? color;
  final bool isSelected;
  final bool isEnabled;

  const ToolButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onTap,
    this.color,
    this.isSelected = false,
    this.isEnabled = true,
  });

  @override
  State<ToolButton> createState() => _ToolButtonState();
}

class _ToolButtonState extends State<ToolButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final baseColor = widget.color ?? Colors.white;
    final iconColor = widget.isEnabled
        ? baseColor
        : baseColor.withValues(alpha: 0.32);

    Color bg;
    if (widget.isSelected) {
      bg = ScreenshotStyle.accent.withValues(alpha: 0.85);
    } else if (_hover && widget.isEnabled) {
      bg = ScreenshotStyle.toolbarBgHover;
    } else {
      bg = Colors.transparent;
    }

    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: widget.isEnabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.isEnabled ? widget.onTap : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(
              widget.icon,
              size: 18,
              color: widget.isSelected ? Colors.white : iconColor,
            ),
          ),
        ),
      ),
    );
  }
}

/// 颜色选择按钮 — 选中时白色外环 + 内填色
class ColorButton extends StatelessWidget {
  final Color color;
  final bool isSelected;
  final VoidCallback? onTap;

  const ColorButton({
    super.key,
    required this.color,
    this.isSelected = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 22,
          height: 22,
          margin: const EdgeInsets.symmetric(horizontal: 3),
          padding: EdgeInsets.all(isSelected ? 3 : 0),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: isSelected ? Colors.white : Colors.white24,
              width: isSelected ? 2 : 1,
            ),
          ),
          child: Container(
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: isSelected
                  ? [
                      BoxShadow(
                        color: color.withValues(alpha: 0.6),
                        blurRadius: 6,
                      ),
                    ]
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}

class ToolDivider extends StatelessWidget {
  const ToolDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 18,
      margin: const EdgeInsets.symmetric(horizontal: 6),
      color: ScreenshotStyle.toolbarDivider,
    );
  }
}

/// 线宽调节弹出滑块
class StrokeWidthPopover extends StatelessWidget {
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  const StrokeWidthPopover({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 1.0,
    this.max = 12.0,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 160,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: ScreenshotStyle.toolbarBg,
        borderRadius: BorderRadius.circular(ScreenshotStyle.radius),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.line_weight, size: 16, color: Colors.white70),
          const SizedBox(width: 6),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                activeTrackColor: ScreenshotStyle.accent,
                inactiveTrackColor: Colors.white24,
                thumbColor: Colors.white,
                overlayShape: SliderComponentShape.noOverlay,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              ),
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                onChanged: onChanged,
              ),
            ),
          ),
          const SizedBox(width: 4),
          SizedBox(
            width: 22,
            child: Text(
              value.toStringAsFixed(0),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w400,
              ),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}
