import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 环形仪表盘：绘制 270 度的背景轨道与按比例填充的前景弧,
/// 中心可显示数值文本,下方可显示小号标签,整体紧凑小巧。
class RingGauge extends StatelessWidget {
  const RingGauge({
    super.key,
    required this.value,
    required this.color,
    required this.trackColor,
    this.size = 66,
    this.strokeWidth = 7,
    this.centerText,
    this.centerTextColor,
    this.label,
    this.labelColor,
  });

  /// 归一化数值,范围 [0,1],超出会被截断,NaN/Infinity 视为 0。
  final double value;

  /// 前景弧颜色。
  final Color color;

  /// 背景轨道颜色。
  final Color trackColor;

  /// 环的直径。
  final double size;

  /// 弧线粗细。
  final double strokeWidth;

  /// 中心文本,如 "98.7%"。
  final String? centerText;

  /// 中心文本颜色。
  final Color? centerTextColor;

  /// 环下方的小号标签。
  final String? label;

  /// 标签颜色。
  final Color? labelColor;

  /// 将输入数值规整到 [0,1],并对 NaN/Infinity 做保护。
  double get _safeValue {
    final v = value;
    if (v.isNaN || v.isInfinite) return 0;
    return v.clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final ring = SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _RingGaugePainter(
          value: _safeValue,
          color: color,
          trackColor: trackColor,
          strokeWidth: strokeWidth,
        ),
        child: centerText == null
            ? null
            : Center(
                child: Text(
                  centerText!,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w300,
                    color: centerTextColor,
                    height: 1,
                  ),
                ),
              ),
      ),
    );

    if (label == null) return ring;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        ring,
        const SizedBox(height: 4),
        Text(
          label!,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 10,
            color: labelColor,
            height: 1,
          ),
        ),
      ],
    );
  }
}

/// 负责绘制环形轨道与前景弧的画笔。
class _RingGaugePainter extends CustomPainter {
  _RingGaugePainter({
    required this.value,
    required this.color,
    required this.trackColor,
    required this.strokeWidth,
  });

  final double value;
  final Color color;
  final Color trackColor;
  final double strokeWidth;

  /// 起始角度:从左下方开始(135 度)。
  static const double _startAngle = 135 * math.pi / 180;

  /// 弧线总跨度:270 度。
  static const double _sweepAngle = 270 * math.pi / 180;

  @override
  void paint(Canvas canvas, Size size) {
    final side = math.min(size.width, size.height);
    if (side <= 0) return;

    final stroke = strokeWidth.clamp(0.0, side / 2);
    final radius = (side - stroke) / 2;
    if (radius <= 0) return;

    final center = Offset(size.width / 2, size.height / 2);
    final rect = Rect.fromCircle(center: center, radius: radius);

    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = trackColor;

    canvas.drawArc(rect, _startAngle, _sweepAngle, false, trackPaint);

    if (value <= 0) return;

    final foregroundPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = color;

    canvas.drawArc(rect, _startAngle, _sweepAngle * value, false, foregroundPaint);
  }

  @override
  bool shouldRepaint(_RingGaugePainter oldDelegate) {
    return oldDelegate.value != value ||
        oldDelegate.color != color ||
        oldDelegate.trackColor != trackColor ||
        oldDelegate.strokeWidth != strokeWidth;
  }
}
