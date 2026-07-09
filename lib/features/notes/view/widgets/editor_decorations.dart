import 'package:flutter/material.dart';

import 'package:termora/app/theme/app_theme.dart';
import 'package:termora/features/notes/domain/markdown_source_highlighter.dart';
import 'package:termora/features/notes/view/widgets/markdown_editing_controller.dart';

/// 编辑器装饰层(marktext 渲染方式)— 画在 TextField 之下:
/// 无序列表圆点、任务勾选框、引用竖条、分隔横线、代码/公式块底色。
/// 对应字符由控制器转成透明占位,几何用 RenderEditable 的选区盒计算,
/// 光标所在行不画(那一行回退成可编辑的源码)。
class EditorDecorations extends StatefulWidget {
  const EditorDecorations({
    super.key,
    required this.controller,
    required this.scrollController,
    required this.editableFinder,
    this.sidePadding = 0,
  });

  final MarkdownEditingController controller;
  final ScrollController scrollController;

  /// 找到编辑器的 EditableTextState(几何来源)
  final EditableTextState? Function() editableFinder;
  final double sidePadding;

  @override
  State<EditorDecorations> createState() => _EditorDecorationsState();
}

class _EditorDecorationsState extends State<EditorDecorations> {
  /// painter 里定位自身 RenderBox 用(与 renderEditable 坐标互转)
  final GlobalKey _paintKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: CustomPaint(
        key: _paintKey,
        painter: _DecorationsPainter(
          controller: widget.controller,
          editableFinder: widget.editableFinder,
          selfBoxFinder: () =>
              _paintKey.currentContext?.findRenderObject() as RenderBox?,
          sidePadding: widget.sidePadding,
          repaint: Listenable.merge([
            widget.controller,
            widget.scrollController,
          ]),
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

/// 计算需要画整块底色的代码/公式分组,返回每组的(首个, 末个)内容 token。
///
/// 分组规则:严格按源码行相邻——下一 token 起点必须等于上一 token 终点 + 1。
/// 围栏行(隐藏的整行 syntax)和围栏内空行(零宽占位)维持链不断;
/// 隔了任何其他内容(普通段落无 token 造成的空隙)立即断组,
/// 避免两个代码块之间的正文被同一块底色吞掉。
@visibleForTesting
List<(MdSourceToken, MdSourceToken)> blockBackgroundGroups(
  List<MdSourceToken> tokens,
) {
  final groups = <(MdSourceToken, MdSourceToken)>[];
  MdSourceToken? chainEnd;
  MdSourceToken? first;
  MdSourceToken? last;
  MdSourceKind? kind;

  void flush() {
    if (first != null && last != null) groups.add((first!, last!));
    chainEnd = null;
    first = null;
    last = null;
    kind = null;
  }

  for (final t in tokens) {
    final isFence = t.kind == MdSourceKind.syntax && t.concealable;
    final isContent =
        t.kind == MdSourceKind.codeBlock || t.kind == MdSourceKind.math;
    if (!isFence && !isContent) {
      flush();
      continue;
    }
    if (chainEnd != null && t.start != chainEnd!.end + 1) flush();
    if (isContent && kind != null && kind != t.kind) flush();
    chainEnd = t;
    if (isContent) {
      kind = t.kind;
      // 零宽占位(围栏内空行)只延链,不参与矩形边界
      if (t.start < t.end) {
        first ??= t;
        last = t;
      }
    }
  }
  flush();
  return groups;
}

class _DecorationsPainter extends CustomPainter {
  _DecorationsPainter({
    required this.controller,
    required this.editableFinder,
    required this.selfBoxFinder,
    required this.sidePadding,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final MarkdownEditingController controller;
  final EditableTextState? Function() editableFinder;
  final RenderBox? Function() selfBoxFinder;
  final double sidePadding;

  /// 块级底色的水平内缩(编辑器 contentPadding 是 24,底色略宽于文字)
  double get _blockInset => 14 + sidePadding;

  static final _taskMarkerRe = RegExp(r'\[[xX]\]');

  @override
  void paint(Canvas canvas, Size size) {
    final editable = editableFinder();
    final selfBox = selfBoxFinder();
    if (editable == null || selfBox == null || !selfBox.attached) return;
    final render = editable.renderEditable;
    if (!render.attached) return;

    final text = controller.value.text;
    if (text.isEmpty) return;
    final tokens = controller.tokensFor(text);
    if (tokens.isEmpty) return;

    var activeStart = -1;
    var activeEnd = -1;
    final selection = controller.value.selection;
    if (selection.isValid) {
      (activeStart, activeEnd) = MarkdownSourceHighlighter.activeLineRange(
        text,
        selection.start,
        selection.end,
      );
    }
    bool isActive(MdSourceToken t) =>
        t.start <= activeEnd && t.end > activeStart;

    Offset toLocal(Offset editableLocal) =>
        selfBox.globalToLocal(render.localToGlobal(editableLocal));

    /// token 覆盖区域的首个选区盒(单行 token 就是整行内的那段)
    Rect? boxOf(int start, int end) {
      final boxes = render.getBoxesForSelection(
        TextSelection(baseOffset: start, extentOffset: end),
      );
      if (boxes.isEmpty) return null;
      final r = boxes.first.toRect();
      return Rect.fromPoints(toLocal(r.topLeft), toLocal(r.bottomRight));
    }

    _paintBlockBackgrounds(canvas, size, tokens, boxOf);
    _paintMarkers(canvas, text, tokens, isActive, boxOf);
  }

  /// 代码块/公式块的整块圆角底色(围栏行已隐藏,底色即块的边界)
  void _paintBlockBackgrounds(
    Canvas canvas,
    Size size,
    List<MdSourceToken> tokens,
    Rect? Function(int, int) boxOf,
  ) {
    for (final (first, last) in blockBackgroundGroups(tokens)) {
      final top = boxOf(first.start, first.end);
      final bottom = identical(first, last) ? top : boxOf(last.start, last.end);
      if (top == null || bottom == null) continue;
      final rect = Rect.fromLTRB(
        _blockInset,
        top.top - 6,
        size.width - _blockInset,
        bottom.bottom + 6,
      );
      final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(10));
      canvas.drawRRect(rrect, Paint()..color = AppTheme.mutedSurfaceColor);
      canvas.drawRRect(
        rrect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.6
          ..color = AppTheme.borderColor,
      );
    }
  }

  /// 列表圆点/任务勾选框/引用竖条/分隔横线(光标所在行不画)
  void _paintMarkers(
    Canvas canvas,
    String text,
    List<MdSourceToken> tokens,
    bool Function(MdSourceToken) isActive,
    Rect? Function(int, int) boxOf,
  ) {
    for (final t in tokens) {
      if (isActive(t)) continue;
      if (!MarkdownEditingController.isReplacedByDecoration(t, text)) continue;
      final rect = boxOf(t.start, t.end);
      if (rect == null || rect.height < 4) continue;

      switch (t.kind) {
        case MdSourceKind.listMarker:
          final marker = text.substring(t.start, t.end);
          if (marker.contains('[')) {
            _paintCheckbox(canvas, rect, _taskMarkerRe.hasMatch(marker));
          } else {
            canvas.drawCircle(
              Offset(rect.left + rect.width * 0.3, rect.center.dy + 1),
              2.4,
              Paint()..color = AppTheme.bodyColor,
            );
          }
        case MdSourceKind.quote:
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(rect.left + 1, rect.top, 3, rect.height),
              const Radius.circular(1.5),
            ),
            Paint()..color = AppTheme.brandColor.withValues(alpha: 0.55),
          );
        case MdSourceKind.divider:
          canvas.drawLine(
            Offset(_blockInset, rect.center.dy),
            Offset(
              (selfBoxFinder()?.size.width ?? rect.right) - _blockInset,
              rect.center.dy,
            ),
            Paint()
              ..strokeWidth = 1
              ..color = AppTheme.borderColor,
          );
        default:
          break;
      }
    }
  }

  void _paintCheckbox(Canvas canvas, Rect markerRect, bool checked) {
    const side = 13.0;
    final box = Rect.fromCenter(
      center: Offset(
        markerRect.left + markerRect.width * 0.55,
        markerRect.center.dy + 1,
      ),
      width: side,
      height: side,
    );
    final rrect = RRect.fromRectAndRadius(box, const Radius.circular(3.5));
    if (checked) {
      canvas.drawRRect(rrect, Paint()..color = AppTheme.brandColor);
      final check = Path()
        ..moveTo(box.left + 3, box.center.dy + 0.5)
        ..lineTo(box.center.dx - 0.5, box.bottom - 3.5)
        ..lineTo(box.right - 3, box.top + 3.5);
      canvas.drawPath(
        check,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..strokeCap = StrokeCap.round
          ..color = Colors.white,
      );
    } else {
      canvas.drawRRect(
        rrect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = AppTheme.subtleTextColor,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DecorationsPainter oldDelegate) =>
      oldDelegate.controller != controller ||
      oldDelegate.sidePadding != sidePadding;
}
