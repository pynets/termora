import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 一条折线序列。[values] 按时间顺序排列,null 表示断点(此处不画点、折线断开)。
class LineSeries {
  const LineSeries({
    required this.label,
    required this.color,
    required this.values,
  });

  /// 图例与提示框中显示的名称。
  final String label;

  /// 折线与图例圆点的颜色。
  final Color color;

  /// 时间序列数据;null 表示缺口(不绘制点,折线断开)。
  final List<double?> values;
}

/// 实时多序列折线图 —— 面向数据密集的仪表盘,支持悬停十字准星与提示框。
///
/// X 轴为样本下标(各序列以自身下标从左向右排列,最新样本在最右侧)。
/// Y 轴自所有非 null 值自动缩放,可用 [minY]/[maxY] 覆盖。
class LiveLineChart extends StatefulWidget {
  const LiveLineChart({
    super.key,
    required this.series,
    this.height = 120,
    this.yFormat,
    this.gridColor,
    this.textColor,
    this.tooltipBg,
    this.surfaceColor,
    this.minY,
    this.maxY,
  });

  /// 待绘制的折线序列集合。
  final List<LineSeries> series;

  /// 图表高度。
  final double height;

  /// 数值 -> 标签(用于提示框与 Y 轴);默认保留 0~1 位小数。
  final String Function(double value)? yFormat;

  /// 网格线与坐标轴的淡色。
  final Color? gridColor;

  /// 坐标轴与提示框文字颜色。
  final Color? textColor;

  /// 提示框背景色。
  final Color? tooltipBg;

  /// 图表背景填充色(可选)。
  final Color? surfaceColor;

  /// Y 轴下限覆盖(可选)。
  final double? minY;

  /// Y 轴上限覆盖(可选)。
  final double? maxY;

  @override
  State<LiveLineChart> createState() => _LiveLineChartState();
}

class _LiveLineChartState extends State<LiveLineChart> {
  /// 当前悬停命中的样本下标;null 表示未悬停。
  int? _hoverIndex;

  /// 当前指针的本地坐标,用于定位提示框。
  Offset? _hoverPos;

  /// 各序列中最长的长度,即 X 轴样本总数。
  int get _sampleCount {
    var n = 0;
    for (final s in widget.series) {
      if (s.values.length > n) n = s.values.length;
    }
    return n;
  }

  /// 左侧 Y 轴标签预留宽度。
  static const double _leftPad = 34;

  /// 顶部图例预留高度。
  static const double _topPad = 16;

  /// 底部预留高度。
  static const double _bottomPad = 6;

  void _updateHover(Offset local, Size size) {
    final count = _sampleCount;
    final plotLeft = _leftPad;
    final plotRight = size.width - 6;
    final plotW = plotRight - plotLeft;
    if (count <= 0 || plotW <= 0) {
      if (_hoverIndex != null || _hoverPos != null) {
        setState(() {
          _hoverIndex = null;
          _hoverPos = null;
        });
      }
      return;
    }
    final clampedX = local.dx.clamp(plotLeft, plotRight);
    int idx;
    if (count == 1) {
      idx = 0;
    } else {
      final frac = (clampedX - plotLeft) / plotW;
      idx = (frac * (count - 1)).round().clamp(0, count - 1);
    }
    if (idx != _hoverIndex || local != _hoverPos) {
      setState(() {
        _hoverIndex = idx;
        _hoverPos = local;
      });
    }
  }

  void _clearHover() {
    if (_hoverIndex != null || _hoverPos != null) {
      setState(() {
        _hoverIndex = null;
        _hoverPos = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final gridColor =
        widget.gridColor ?? const Color(0xFF9E9E9E).withValues(alpha: 0.25);
    final textColor =
        widget.textColor ?? const Color(0xFF9E9E9E).withValues(alpha: 0.9);
    final tooltipBg = widget.tooltipBg ?? const Color(0xFF2A2A2A);
    final yFormat = widget.yFormat ?? _defaultFormat;

    return SizedBox(
      height: widget.height,
      width: double.infinity,
      child: MouseRegion(
        onHover: (e) {
          final box = context.findRenderObject() as RenderBox?;
          if (box == null || !box.hasSize) return;
          _updateHover(box.globalToLocal(e.position), box.size);
        },
        onExit: (_) => _clearHover(),
        child: CustomPaint(
          painter: _LineChartPainter(
            series: widget.series,
            sampleCount: _sampleCount,
            gridColor: gridColor,
            textColor: textColor,
            tooltipBg: tooltipBg,
            surfaceColor: widget.surfaceColor,
            minYOverride: widget.minY,
            maxYOverride: widget.maxY,
            yFormat: yFormat,
            hoverIndex: _hoverIndex,
            hoverPos: _hoverPos,
            leftPad: _leftPad,
            topPad: _topPad,
            bottomPad: _bottomPad,
          ),
        ),
      ),
    );
  }

  /// 默认数值格式:绝对值 >= 100 时不留小数,否则保留 1 位。
  static String _defaultFormat(double v) {
    if (!v.isFinite) return '—';
    return v.abs() >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
  }
}

/// 负责实际绘制的画笔。
class _LineChartPainter extends CustomPainter {
  _LineChartPainter({
    required this.series,
    required this.sampleCount,
    required this.gridColor,
    required this.textColor,
    required this.tooltipBg,
    required this.surfaceColor,
    required this.minYOverride,
    required this.maxYOverride,
    required this.yFormat,
    required this.hoverIndex,
    required this.hoverPos,
    required this.leftPad,
    required this.topPad,
    required this.bottomPad,
  });

  final List<LineSeries> series;
  final int sampleCount;
  final Color gridColor;
  final Color textColor;
  final Color tooltipBg;
  final Color? surfaceColor;
  final double? minYOverride;
  final double? maxYOverride;
  final String Function(double) yFormat;
  final int? hoverIndex;
  final Offset? hoverPos;
  final double leftPad;
  final double topPad;
  final double bottomPad;

  @override
  void paint(Canvas canvas, Size size) {
    final plotLeft = leftPad;
    final plotTop = topPad;
    final plotRight = size.width - 6;
    final plotBottom = size.height - bottomPad;
    final plotW = plotRight - plotLeft;
    final plotH = plotBottom - plotTop;
    if (plotW <= 0 || plotH <= 0) return;
    final plotRect = Rect.fromLTRB(plotLeft, plotTop, plotRight, plotBottom);

    // 背景填充。
    if (surfaceColor != null) {
      canvas.drawRect(plotRect, Paint()..color = surfaceColor!);
    }

    // 图例始终绘制(即便无数据)。
    _paintLegend(canvas, size);

    // 计算 Y 轴范围。
    final range = _computeYRange();
    final minY = range.$1;
    final maxY = range.$2;
    final span = maxY - minY;

    double yToPx(double v) {
      if (span <= 0) return plotTop + plotH / 2;
      final t = (v - minY) / span;
      return plotBottom - t * plotH;
    }

    double xToPx(int i) {
      if (sampleCount <= 1) return plotRight;
      return plotLeft + plotW * (i / (sampleCount - 1));
    }

    // 网格线 + Y 标签。
    const lines = 4;
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (var i = 0; i < lines; i++) {
      final t = i / (lines - 1);
      final y = plotTop + plotH * t;
      canvas.drawLine(Offset(plotLeft, y), Offset(plotRight, y), gridPaint);
      final value = maxY - span * t;
      _paintText(
        canvas,
        yFormat(value),
        Offset(plotLeft - 4, y),
        textColor,
        8,
        alignRight: true,
        vCenter: true,
      );
    }

    // 若无有效样本,仅保留网格与图例。
    if (sampleCount <= 0) return;

    // 首个序列的区域填充。
    if (series.isNotEmpty) {
      _paintAreaFill(canvas, series.first, xToPx, yToPx, plotBottom, plotRect);
    }

    // 各序列折线。
    for (final s in series) {
      _paintPolyline(canvas, s, xToPx, yToPx);
    }

    // 各序列最新点圆点。
    for (final s in series) {
      final latest = _latestNonNullIndex(s);
      if (latest != null) {
        final v = s.values[latest]!;
        canvas.drawCircle(
          Offset(xToPx(latest), yToPx(v)),
          2.6,
          Paint()..color = s.color,
        );
      }
    }

    // 悬停十字准星与提示框。
    _paintHover(canvas, size, xToPx, yToPx, plotRect);
  }

  /// 计算 Y 轴范围,处理覆盖值、全相等与无数据。
  (double, double) _computeYRange() {
    double? lo;
    double? hi;
    for (final s in series) {
      for (final v in s.values) {
        if (v == null || !v.isFinite) continue;
        if (lo == null || v < lo) lo = v;
        if (hi == null || v > hi) hi = v;
      }
    }
    var minY = minYOverride ?? lo ?? 0;
    var maxY = maxYOverride ?? hi ?? 1;
    if (!minY.isFinite) minY = 0;
    if (!maxY.isFinite) maxY = minY + 1;
    if (maxY < minY) {
      final t = maxY;
      maxY = minY;
      minY = t;
    }
    if (maxY - minY <= 0) {
      // 全相等:围绕该值形成对称区间,折线居中。
      final pad = minY.abs() < 1e-9 ? 1.0 : minY.abs() * 0.1;
      minY -= pad;
      maxY += pad;
    }
    return (minY, maxY);
  }

  /// 返回序列中最右侧的非 null 下标。
  int? _latestNonNullIndex(LineSeries s) {
    for (var i = s.values.length - 1; i >= 0; i--) {
      final v = s.values[i];
      if (v != null && v.isFinite) return i;
    }
    return null;
  }

  void _paintPolyline(
    Canvas canvas,
    LineSeries s,
    double Function(int) xToPx,
    double Function(double) yToPx,
  ) {
    final paint = Paint()
      ..color = s.color
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    Path? path;
    var pending = false; // path 中是否只有一个孤立点
    Offset? lonePoint;
    for (var i = 0; i < s.values.length; i++) {
      final v = s.values[i];
      if (v == null || !v.isFinite) {
        if (path != null && !pending) canvas.drawPath(path, paint);
        if (pending && lonePoint != null) {
          _paintDot(canvas, lonePoint, s.color);
        }
        path = null;
        pending = false;
        lonePoint = null;
        continue;
      }
      final p = Offset(xToPx(i), yToPx(v));
      if (path == null) {
        path = Path()..moveTo(p.dx, p.dy);
        pending = true;
        lonePoint = p;
      } else {
        path.lineTo(p.dx, p.dy);
        pending = false;
        lonePoint = null;
      }
    }
    if (path != null && !pending) canvas.drawPath(path, paint);
    if (pending && lonePoint != null) _paintDot(canvas, lonePoint, s.color);
  }

  void _paintDot(Canvas canvas, Offset p, Color color) {
    canvas.drawCircle(p, 1.6, Paint()..color = color);
  }

  void _paintAreaFill(
    Canvas canvas,
    LineSeries s,
    double Function(int) xToPx,
    double Function(double) yToPx,
    double baseline,
    Rect plotRect,
  ) {
    final fill = Paint()
      ..color = s.color.withValues(alpha: 0.10)
      ..style = PaintingStyle.fill;
    // 逐段填充(遇 null 断开)。
    Path? path;
    double? startX;
    double? lastX;
    void close() {
      final p = path;
      final sx = startX;
      final lx = lastX;
      if (p != null && sx != null && lx != null) {
        p
          ..lineTo(lx, baseline)
          ..lineTo(sx, baseline)
          ..close();
        canvas.save();
        canvas.clipRect(plotRect);
        canvas.drawPath(p, fill);
        canvas.restore();
      }
      path = null;
      startX = null;
      lastX = null;
    }

    for (var i = 0; i < s.values.length; i++) {
      final v = s.values[i];
      if (v == null || !v.isFinite) {
        close();
        continue;
      }
      final x = xToPx(i);
      final y = yToPx(v);
      if (path == null) {
        path = Path()..moveTo(x, y);
        startX = x;
      } else {
        path!.lineTo(x, y);
      }
      lastX = x;
    }
    close();
  }

  void _paintHover(
    Canvas canvas,
    Size size,
    double Function(int) xToPx,
    double Function(double) yToPx,
    Rect plotRect,
  ) {
    final idx = hoverIndex;
    final pos = hoverPos;
    if (idx == null || pos == null || idx < 0 || idx >= sampleCount) return;
    final x = xToPx(idx);

    // 十字准星竖线。
    canvas.drawLine(
      Offset(x, plotRect.top),
      Offset(x, plotRect.bottom),
      Paint()
        ..color = textColor.withValues(alpha: 0.5)
        ..strokeWidth = 1,
    );

    // 命中点高亮。
    for (final s in series) {
      if (idx < s.values.length) {
        final v = s.values[idx];
        if (v != null && v.isFinite) {
          canvas.drawCircle(Offset(x, yToPx(v)), 2.4, Paint()..color = s.color);
        }
      }
    }

    _paintTooltip(canvas, size, idx, pos, plotRect);
  }

  void _paintTooltip(
    Canvas canvas,
    Size size,
    int idx,
    Offset pos,
    Rect plotRect,
  ) {
    if (series.isEmpty) return;
    const rowH = 13.0;
    const padH = 6.0;
    const padV = 5.0;
    const dotR = 2.5;
    const gap = 5.0;
    const fontSize = 9.0;

    // 预先测量每行文字,得到内容宽度。
    final painters = <TextPainter>[];
    var contentW = 0.0;
    for (final s in series) {
      final v = idx < s.values.length ? s.values[idx] : null;
      final valStr = (v != null && v.isFinite) ? yFormat(v) : '—';
      final tp = TextPainter(
        text: TextSpan(
          text: '${s.label}  $valStr',
          style: TextStyle(color: textColor, fontSize: fontSize),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      painters.add(tp);
      final w = dotR * 2 + gap + tp.width;
      if (w > contentW) contentW = w;
    }
    final boxW = contentW + padH * 2;
    final boxH = series.length * rowH + padV * 2;

    // 定位:优先放在光标右侧,越界则翻转/夹紧。
    var left = pos.dx + 12;
    var top = pos.dy + 12;
    if (left + boxW > size.width - 2) left = pos.dx - 12 - boxW;
    if (left < 2) left = 2;
    if (left + boxW > size.width - 2) left = size.width - 2 - boxW;
    if (top + boxH > size.height - 2) top = pos.dy - 12 - boxH;
    if (top < 2) top = 2;
    if (top + boxH > size.height - 2) top = size.height - 2 - boxH;

    final rect = Rect.fromLTWH(left, top, boxW, boxH);
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(4));
    canvas.drawRRect(
      rrect,
      Paint()..color = tooltipBg.withValues(alpha: 0.95),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = gridColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    for (var i = 0; i < series.length; i++) {
      final rowY = top + padV + i * rowH + rowH / 2;
      canvas.drawCircle(
        Offset(left + padH + dotR, rowY),
        dotR,
        Paint()..color = series[i].color,
      );
      final tp = painters[i];
      tp.paint(
        canvas,
        Offset(left + padH + dotR * 2 + gap, rowY - tp.height / 2),
      );
    }
  }

  void _paintLegend(Canvas canvas, Size size) {
    if (series.isEmpty) return;
    var x = leftPad;
    const y = 2.0;
    const dotR = 3.0;
    const gap = 4.0;
    const spacing = 10.0;
    for (final s in series) {
      if (x > size.width - 20) break;
      canvas.drawCircle(
        Offset(x + dotR, y + 5),
        dotR,
        Paint()..color = s.color,
      );
      final tp = TextPainter(
        text: TextSpan(
          text: s.label,
          style: TextStyle(color: textColor, fontSize: 9),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: math.max(0, size.width - x - dotR * 2 - gap - 4));
      tp.paint(canvas, Offset(x + dotR * 2 + gap, y));
      x += dotR * 2 + gap + tp.width + spacing;
    }
  }

  void _paintText(
    Canvas canvas,
    String text,
    Offset anchor,
    Color color,
    double fontSize, {
    bool alignRight = false,
    bool vCenter = false,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: color, fontSize: fontSize),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    var dx = anchor.dx;
    var dy = anchor.dy;
    if (alignRight) dx -= tp.width;
    if (vCenter) dy -= tp.height / 2;
    tp.paint(canvas, Offset(dx, dy));
  }

  @override
  bool shouldRepaint(_LineChartPainter old) {
    return old.series != series ||
        old.sampleCount != sampleCount ||
        old.hoverIndex != hoverIndex ||
        old.hoverPos != hoverPos ||
        old.gridColor != gridColor ||
        old.textColor != textColor ||
        old.tooltipBg != tooltipBg ||
        old.surfaceColor != surfaceColor ||
        old.minYOverride != minYOverride ||
        old.maxYOverride != maxYOverride;
  }
}
