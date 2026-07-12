import 'package:flutter/material.dart';

/// 单条柱状数据项。
class BarItem {
  const BarItem({
    required this.label,
    required this.value,
    required this.valueLabel,
    this.tooltip,
  });

  /// 左侧标签文本。
  final String label;

  /// 用于计算柱长的数值（应 >= 0）。
  final double value;

  /// 右侧对齐展示的文本，例如 "12.4 MB"。
  final String valueLabel;

  /// 可选的悬浮提示;为空时回退到 "label · valueLabel"。
  final String? tooltip;
}

/// 交互式水平柱状图 —— 密集排布、可悬浮高亮、可点击。
///
/// 每行布局:[标签(labelWidth,省略号)] [间隔] [圆角轨道+渐变柱] [间隔] [数值(右对齐)]。
/// 柱长按 value/maxValue 比例绘制;所有颜色由外部传入以适配明暗主题。
class InteractiveBarChart extends StatefulWidget {
  const InteractiveBarChart({
    super.key,
    required this.items,
    this.onTap,
    this.barColor,
    this.trackColor,
    this.textColor,
    this.subtleTextColor,
    this.hoverColor,
    this.labelWidth = 150,
    this.rowHeight = 22,
  });

  /// 数据项;渲染顺序即调用方给定顺序(降序排序由调用方负责)。
  final List<BarItem> items;

  /// 行点击回调,携带下标。
  final void Function(int index)? onTap;

  /// 柱体基色(会派生出左右渐变透明度)。
  final Color? barColor;

  /// 柱体背景轨道色。
  final Color? trackColor;

  /// 主文本色。
  final Color? textColor;

  /// 次要文本色(数值文本)。
  final Color? subtleTextColor;

  /// 行悬浮高亮色。
  final Color? hoverColor;

  /// 左侧标签区宽度。
  final double labelWidth;

  /// 单行高度。
  final double rowHeight;

  @override
  State<InteractiveBarChart> createState() => _InteractiveBarChartState();
}

class _InteractiveBarChartState extends State<InteractiveBarChart> {
  int _hoveredIndex = -1;

  /// 计算最大值,过滤 NaN/Infinity/负数;若无有效值返回 0。
  double get _maxValue {
    var maxV = 0.0;
    for (final item in widget.items) {
      final v = item.value;
      if (v.isFinite && v > maxV) {
        maxV = v;
      }
    }
    return maxV;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) {
      return const SizedBox.shrink();
    }

    final barColor = widget.barColor ?? const Color(0xFF4F8CFF);
    final trackColor =
        widget.trackColor ?? barColor.withValues(alpha: 0.12);
    final textColor = widget.textColor ?? const Color(0xFF1A1A1A);
    final subtleTextColor =
        widget.subtleTextColor ?? textColor.withValues(alpha: 0.55);
    final hoverColor =
        widget.hoverColor ?? barColor.withValues(alpha: 0.08);

    final maxValue = _maxValue;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < widget.items.length; i++)
          _buildRow(
            index: i,
            item: widget.items[i],
            maxValue: maxValue,
            barColor: barColor,
            trackColor: trackColor,
            textColor: textColor,
            subtleTextColor: subtleTextColor,
            hoverColor: hoverColor,
          ),
      ],
    );
  }

  Widget _buildRow({
    required int index,
    required BarItem item,
    required double maxValue,
    required Color barColor,
    required Color trackColor,
    required Color textColor,
    required Color subtleTextColor,
    required Color hoverColor,
  }) {
    final hovered = _hoveredIndex == index;
    final clickable = widget.onTap != null;
    final tooltipMessage =
        item.tooltip ?? '${item.label} · ${item.valueLabel}';

    // 归一化比例,防止除零、NaN、Infinity 与越界。
    var fraction = 0.0;
    if (maxValue > 0 && item.value.isFinite && item.value > 0) {
      fraction = (item.value / maxValue).clamp(0.0, 1.0);
    }

    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: SizedBox(
        height: widget.rowHeight,
        child: Row(
          children: [
            SizedBox(
              width: widget.labelWidth,
              child: Text(
                item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: textColor),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: CustomPaint(
                painter: _BarPainter(
                  fraction: fraction,
                  barColor: barColor,
                  trackColor: trackColor,
                ),
                child: const SizedBox.expand(),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 90,
              child: Text(
                item.valueLabel,
                textAlign: TextAlign.right,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: subtleTextColor),
              ),
            ),
          ],
        ),
      ),
    );

    return MouseRegion(
      cursor: clickable ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hoveredIndex = index),
      onExit: (_) =>
          setState(() => _hoveredIndex = _hoveredIndex == index ? -1 : _hoveredIndex),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: clickable ? () => widget.onTap!(index) : null,
        child: Tooltip(
          message: tooltipMessage,
          waitDuration: const Duration(milliseconds: 400),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: hovered ? hoverColor : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            child: row,
          ),
        ),
      ),
    );
  }
}

/// 单条柱体绘制器 —— 圆角轨道 + 左到右渐变填充柱。
class _BarPainter extends CustomPainter {
  const _BarPainter({
    required this.fraction,
    required this.barColor,
    required this.trackColor,
  });

  /// 归一化后的柱长比例,范围 [0, 1]。
  final double fraction;
  final Color barColor;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) {
      return;
    }

    // 轨道高度略小于行高,垂直居中,保持密集观感。
    final barHeight = size.height * 0.62;
    final top = (size.height - barHeight) / 2;
    final radius = Radius.circular(barHeight / 2);

    final trackRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, top, size.width, barHeight),
      radius,
    );
    canvas.drawRRect(trackRect, Paint()..color = trackColor);

    final safeFraction = fraction.isFinite ? fraction.clamp(0.0, 1.0) : 0.0;
    final fillWidth = size.width * safeFraction;
    if (fillWidth <= 0) {
      return;
    }

    final fillRect = Rect.fromLTWH(0, top, fillWidth, barHeight);
    final gradient = LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: [
        barColor.withValues(alpha: 0.85),
        barColor.withValues(alpha: 0.55),
      ],
    );
    final fillPaint = Paint()..shader = gradient.createShader(fillRect);
    canvas.drawRRect(
      RRect.fromRectAndRadius(fillRect, radius),
      fillPaint,
    );
  }

  @override
  bool shouldRepaint(_BarPainter oldDelegate) {
    return oldDelegate.fraction != fraction ||
        oldDelegate.barColor != barColor ||
        oldDelegate.trackColor != trackColor;
  }
}
