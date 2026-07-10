import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// 「按住垂直滑动」区间多选 + 单击 toggle 的通用手势层。
///
/// 用法:
/// - 列表外包 [SlideSelectArea](Listener,不进手势竞技场,与行内
///   Draggable/InkWell 并存);
/// - 每行包 [SlideSelectItem](hitTest 标记,行高可变也能精确命中);
/// - 宿主 listen [SlideSelectController] 刷新选中高亮与批量操作条。
///
/// 手势语义(桌面):
/// - 主键按下 + 垂直滑过其他行 → anchor..当前行 区间并入选择;
/// - 原地按下抬起(位移 < 阈值) → toggle 该行;
/// - 水平为主的拖动不触发多选(留给行级 Draggable 拖文件);
///   行级拖拽可查 [SlideSelectController.verticalIntent] 决定是否让路。
class SlideSelectController<K> extends ChangeNotifier {
  final Set<K> _selected = <K>{};
  Set<K> _base = const {};
  int? _anchorIndex;
  bool _extended = false;
  bool _verticalIntent = false;

  Set<K> get selected => _selected;
  bool get hasSelection => _selected.isNotEmpty;

  /// 本次按压是否已发生垂直滑选(拖出到 Finder 等行级拖拽应据此让路)
  bool get verticalIntent => _verticalIntent;

  bool contains(K key) => _selected.contains(key);

  void _beginPress(int index) {
    _anchorIndex = index;
    _extended = false;
    _verticalIntent = false;
    _base = Set.of(_selected);
  }

  void _extendTo(int index, List<K> items) {
    final anchor = _anchorIndex;
    if (anchor == null || items.isEmpty) return;
    _extended = true;
    final a = anchor.clamp(0, items.length - 1);
    final b = index.clamp(0, items.length - 1);
    final lo = a < b ? a : b;
    final hi = a < b ? b : a;
    _selected
      ..clear()
      ..addAll(_base)
      ..addAll([for (var i = lo; i <= hi; i++) items[i]]);
    notifyListeners();
  }

  void _endPress() {
    _anchorIndex = null;
    _extended = false;
    _verticalIntent = false;
    _base = const {};
  }

  void toggle(K key) {
    _selected.contains(key) ? _selected.remove(key) : _selected.add(key);
    notifyListeners();
  }

  void selectAll(Iterable<K> keys) {
    _selected
      ..clear()
      ..addAll(keys);
    notifyListeners();
  }

  void clear() {
    if (_selected.isEmpty && _anchorIndex == null) return;
    _selected.clear();
    _base = const {};
    _endPress();
    notifyListeners();
  }

  /// 目录刷新后清掉已不存在的条目
  void retainWhere(bool Function(K key) test) {
    final before = _selected.length;
    _selected.retainWhere(test);
    if (_selected.length != before) notifyListeners();
  }
}

/// 行标记数据:挂在 [MetaData] 上被 [SlideSelectArea] 的 hitTest 捞出
@immutable
class _SlideSelectTag {
  const _SlideSelectTag(this.owner, this.index);

  final SlideSelectController<Object?> owner;
  final int index;
}

/// 包在每行外面的命中标记(不改变布局与手势)
class SlideSelectItem<K> extends StatelessWidget {
  const SlideSelectItem({
    super.key,
    required this.controller,
    required this.index,
    required this.child,
  });

  final SlideSelectController<K> controller;
  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MetaData(
      metaData: _SlideSelectTag(controller, index),
      behavior: HitTestBehavior.translucent,
      child: child,
    );
  }
}

/// 包在列表外面的手势层
class SlideSelectArea<K> extends StatefulWidget {
  const SlideSelectArea({
    super.key,
    required this.controller,
    required this.items,
    required this.child,
  });

  final SlideSelectController<K> controller;

  /// 当前列表顺序对应的 key 序列(与行 index 对齐)
  final List<K> Function() items;

  final Widget child;

  @override
  State<SlideSelectArea<K>> createState() => _SlideSelectAreaState<K>();
}

class _SlideSelectAreaState<K> extends State<SlideSelectArea<K>> {
  static const _kMoveSlop = 6.0;

  Offset? _downPosition;
  int? _downIndex;
  bool _moved = false;

  int? _hitRowIndex(Offset globalPosition) {
    final result = HitTestResult();
    RendererBinding.instance.hitTestInView(
      result,
      globalPosition,
      View.of(context).viewId,
    );
    for (final entry in result.path) {
      final target = entry.target;
      if (target is RenderMetaData) {
        final data = target.metaData;
        if (data is _SlideSelectTag &&
            identical(data.owner, widget.controller)) {
          return data.index;
        }
      }
    }
    return null;
  }

  void _handleDown(PointerDownEvent event) {
    if (event.kind == PointerDeviceKind.mouse &&
        event.buttons != kPrimaryMouseButton) {
      return;
    }
    final index = _hitRowIndex(event.position);
    if (index == null) return;
    _downPosition = event.position;
    _downIndex = index;
    _moved = false;
    widget.controller._beginPress(index);
  }

  void _handleMove(PointerMoveEvent event) {
    final down = _downPosition;
    if (down == null) return;
    final delta = event.position - down;
    if (!_moved && delta.distance > _kMoveSlop) _moved = true;
    // 垂直意图判定:纵向位移主导才进入滑选,横向留给行级拖拽
    if (!widget.controller._verticalIntent) {
      if (delta.dy.abs() > _kMoveSlop && delta.dy.abs() > delta.dx.abs()) {
        widget.controller._verticalIntent = true;
      } else {
        return;
      }
    }
    final index = _hitRowIndex(event.position);
    if (index != null) {
      widget.controller._extendTo(index, widget.items());
    }
  }

  void _handleUp(PointerUpEvent event) {
    final controller = widget.controller;
    final downIndex = _downIndex;
    if (downIndex != null && !_moved && !controller._extended) {
      final items = widget.items();
      if (downIndex >= 0 && downIndex < items.length) {
        controller.toggle(items[downIndex]);
      }
    }
    controller._endPress();
    _downPosition = null;
    _downIndex = null;
    _moved = false;
  }

  void _handleCancel(PointerCancelEvent event) {
    widget.controller._endPress();
    _downPosition = null;
    _downIndex = null;
    _moved = false;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _handleDown,
      onPointerMove: _handleMove,
      onPointerUp: _handleUp,
      onPointerCancel: _handleCancel,
      child: widget.child,
    );
  }
}
