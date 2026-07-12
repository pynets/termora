import 'package:flutter/material.dart';

/// 迷你趋势折线 —— 用于统计卡片内的内联 sparkline。
///
/// 无坐标轴、无标签,自动按非空数据做 y 轴缩放;
/// null 视为断点,折线在此处断开;可选在折线下方绘制淡淡的面积填充,
/// 并在最新一个非空点上标记一个小圆点。
class Sparkline extends StatelessWidget {
  const Sparkline({
    super.key,
    required this.values,
    required this.color,
    this.width = 64,
    this.height = 22,
    this.strokeWidth = 1.4,
    this.fill = true,
  });

  /// 按时间顺序排列的数据点;null 表示缺口(折线在此断开)。
  final List<double?> values;

  /// 折线、圆点与面积填充所用的颜色(由调用方按明暗主题传入)。
  final Color color;

  /// 组件宽度。
  final double width;

  /// 组件高度。
  final double height;

  /// 折线描边宽度。
  final double strokeWidth;

  /// 是否在折线下方绘制淡淡的面积填充。
  final bool fill;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: CustomPaint(
        painter: _SparklinePainter(
          values: values,
          color: color,
          strokeWidth: strokeWidth,
          fill: fill,
        ),
      ),
    );
  }
}

/// sparkline 的实际绘制逻辑。
class _SparklinePainter extends CustomPainter {
  const _SparklinePainter({
    required this.values,
    required this.color,
    required this.strokeWidth,
    required this.fill,
  });

  final List<double?> values;
  final Color color;
  final double strokeWidth;
  final bool fill;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    // 收集有效(有限)数据点及其原始索引。
    final points = <_Sample>[];
    for (var i = 0; i < values.length; i++) {
      final v = values[i];
      if (v != null && v.isFinite) {
        points.add(_Sample(i, v));
      }
    }
    // 空数据 / 全为 null / 单点无法成线 —— 优雅地什么都不画。
    if (points.length < 2) return;

    // 计算数据范围,若全部相等则退化为居中水平线,避免除零。
    var minV = points.first.value;
    var maxV = points.first.value;
    for (final p in points) {
      if (p.value < minV) minV = p.value;
      if (p.value > maxV) maxV = p.value;
    }
    final span = maxV - minV;

    // 折线绘制留出描边余量,避免顶点被裁切。
    final pad = strokeWidth;
    final usableH = size.height - pad * 2;
    final maxIndex = values.length - 1;

    double dx(int index) {
      if (maxIndex <= 0) return size.width / 2;
      return index / maxIndex * size.width;
    }

    double dy(double value) {
      if (span <= 0) return size.height / 2;
      final t = (value - minV) / span;
      // 值越大越靠上。
      return pad + (1 - t) * usableH;
    }

    // 按 null 缺口拆分为多段折线。
    final segments = <List<Offset>>[];
    var current = <Offset>[];
    var cursor = 0; // points 列表中的游标
    for (var i = 0; i < values.length; i++) {
      final v = values[i];
      final isGap = v == null || !v.isFinite;
      if (isGap) {
        if (current.isNotEmpty) {
          segments.add(current);
          current = <Offset>[];
        }
      } else {
        current.add(Offset(dx(i), dy(points[cursor].value)));
        cursor++;
      }
    }
    if (current.isNotEmpty) segments.add(current);

    // 面积填充(仅对含 2 个及以上点的段绘制)。
    if (fill) {
      final fillPaint = Paint()
        ..style = PaintingStyle.fill
        ..color = color.withValues(alpha: 0.12);
      final baseline = size.height;
      for (final seg in segments) {
        if (seg.length < 2) continue;
        final path = Path()..moveTo(seg.first.dx, baseline);
        for (final o in seg) {
          path.lineTo(o.dx, o.dy);
        }
        path
          ..lineTo(seg.last.dx, baseline)
          ..close();
        canvas.drawPath(path, fillPaint);
      }
    }

    // 折线描边。
    final linePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;
    for (final seg in segments) {
      if (seg.length < 2) continue;
      final path = Path()..moveTo(seg.first.dx, seg.first.dy);
      for (var i = 1; i < seg.length; i++) {
        path.lineTo(seg[i].dx, seg[i].dy);
      }
      canvas.drawPath(path, linePaint);
    }

    // 最新一个非空点上的小实心圆点。
    final last = points.last;
    final dotCenter = Offset(dx(last.index), dy(last.value));
    final dotPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = color;
    canvas.drawCircle(dotCenter, strokeWidth * 1.4, dotPaint);
  }

  @override
  bool shouldRepaint(_SparklinePainter oldDelegate) {
    return oldDelegate.values != values ||
        oldDelegate.color != color ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.fill != fill;
  }
}

/// 单个有效数据点:原始索引 + 数值。
class _Sample {
  const _Sample(this.index, this.value);

  final int index;
  final double value;
}
