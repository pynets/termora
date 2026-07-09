import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:termora/app/theme/app_theme.dart';

class _GlassMenuLayoutDelegate extends SingleChildLayoutDelegate {
  final Offset position;
  _GlassMenuLayoutDelegate(this.position);

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints.loose(constraints.biggest);
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    double x = position.dx;
    double y = position.dy;
    if (x + childSize.width > size.width) {
      x = size.width - childSize.width - 8;
    }
    if (x < 8) x = 8;
    if (y + childSize.height > size.height) {
      y = size.height - childSize.height - 8;
    }
    if (y < 8) y = 8;
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(covariant _GlassMenuLayoutDelegate oldDelegate) {
    return oldDelegate.position != position;
  }
}

Future<T?> showGlassMenu<T>({
  required BuildContext context,
  required Offset position,
  required List<PopupMenuEntry<T>> items,
  double elevation = 8,
  BoxConstraints? constraints,
}) {
  if (items.isEmpty) return Future.value(null);
  final dk = Theme.of(context).brightness == Brightness.dark;
  final bgColor = dk
      ? AppTheme.surfaceColor.withValues(alpha: 0.70)
      : AppTheme.surfaceColor.withValues(alpha: 0.80);
  final borderColor = dk
      ? AppTheme.surfaceColor.withValues(alpha: 0.20)
      : AppTheme.headingColor.withValues(alpha: 0.10);

  return showGeneralDialog<T>(
    context: context,
    barrierColor: Colors.transparent,
    barrierDismissible: true,
    barrierLabel: 'GlassMenu',
    transitionDuration: const Duration(milliseconds: 150),
    pageBuilder: (context, animation, secondaryAnimation) {
      return CustomSingleChildLayout(
        delegate: _GlassMenuLayoutDelegate(position),
        child: Material(
          color: Colors.transparent,
          child: FadeTransition(
            opacity: animation,
            child: ConstrainedBox(
              constraints: constraints ??
                  const BoxConstraints(minWidth: 120, maxWidth: 480),
              child: IntrinsicWidth(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      decoration: BoxDecoration(
                        color: bgColor,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: borderColor, width: 0.5),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x22000000),
                            blurRadius: 16,
                            offset: Offset(0, 4),
                          ),
                        ],
                      ),
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: items,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class GlassPopupMenuButton<T> extends StatelessWidget {
  const GlassPopupMenuButton({
    super.key,
    required this.itemBuilder,
    this.onSelected,
    this.icon,
    this.child,
    this.tooltip,
    this.enabled = true,
    this.padding = const EdgeInsets.all(8.0),
    this.splashRadius,
    this.iconSize,
    this.constraints,
    this.position = PopupMenuPosition.under,
    this.offset = Offset.zero,
    this.color,
    this.shape,
  });

  final List<PopupMenuEntry<T>> Function(BuildContext) itemBuilder;
  final ValueChanged<T>? onSelected;
  final Widget? icon;
  final Widget? child;
  final String? tooltip;
  final bool enabled;
  final EdgeInsetsGeometry padding;
  final double? splashRadius;
  final double? iconSize;
  final BoxConstraints? constraints;
  final PopupMenuPosition position;
  final Offset offset;
  final Color? color;
  final ShapeBorder? shape;

  @override
  Widget build(BuildContext context) {
    if (icon != null) {
      return IconButton(
        icon: icon!,
        tooltip: tooltip,
        iconSize: iconSize ?? 24,
        padding: padding,
        splashRadius: splashRadius,
        onPressed: enabled ? () => _show(context) : null,
      );
    }
    Widget result = InkWell(
      onTap: enabled ? () => _show(context) : null,
      child: child,
    );
    if (tooltip != null) {
      result = Tooltip(message: tooltip!, child: result);
    }
    return result;
  }

  void _show(BuildContext context) async {
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final pos = renderBox.localToGlobal(Offset.zero);
    final top = position == PopupMenuPosition.under
        ? pos.dy + renderBox.size.height + 2
        : pos.dy;
    final items = itemBuilder(context);
    if (items.isEmpty) return;
    final value = await showGlassMenu<T>(
      context: context,
      position: Offset(pos.dx + offset.dx, top + offset.dy),
      items: items,
      constraints: constraints,
    );
    if (value != null && onSelected != null && context.mounted) {
      onSelected!(value);
    }
  }
}

class GlassDropdownMenuItem<T> {
  const GlassDropdownMenuItem({
    required this.value,
    required this.child,
  });

  final T value;
  final Widget child;
}

class GlassDropdownButton<T> extends StatelessWidget {
  const GlassDropdownButton({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final T value;
  final List<GlassDropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    final currentItem = items.firstWhere(
      (item) => item.value == value,
      orElse: () => items.first,
    );

    return InkWell(
      onTap: () async {
        final renderBox = context.findRenderObject() as RenderBox?;
        if (renderBox == null) return;
        final pos = renderBox.localToGlobal(Offset.zero);
        final selected = await showGlassMenu<T>(
          context: context,
          position: Offset(pos.dx, pos.dy + renderBox.size.height + 2),
          constraints: BoxConstraints(minWidth: renderBox.size.width),
          items: [
            for (final item in items)
              PopupMenuItem<T>(
                value: item.value,
                height: 36,
                child: item.child,
              ),
          ],
        );
        if (selected != null) {
          onChanged(selected);
        }
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.borderColor),
        ),
        child: Row(
          children: [
            Expanded(child: currentItem.child),
            Icon(Icons.arrow_drop_down, size: 18, color: AppTheme.subtleTextColor),
          ],
        ),
      ),
    );
  }
}
