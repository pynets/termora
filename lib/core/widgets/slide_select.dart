import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

/// 文件列表的「框选」多选手势层。
///
/// 用法:
/// - 列表外包 [SlideSelectArea](Listener,不进手势竞技场,与行内
///   Draggable/InkWell 并存);
/// - 每行包 [SlideSelectItem](hitTest 标记,行高可变也能精确命中);
/// - 宿主 listen [SlideSelectController] 刷新选中高亮,批量操作放右键菜单。
///
/// 手势语义(对齐 Finder):
/// - 按下(行上或空白)+ 纵向拖出选框 → 框到的行选中(替换式;
///   按住 ⌘/Ctrl 拖 = 在已有选择上追加);
/// - 原地单击行 = 只选中该行;⌘/Ctrl+单击 = 追加/移除该行;
/// - 单击空白 = 清空选择;
/// - 横向为主的拖动不启动框选(留给行级 Draggable 拖文件);
///   行级拖拽可查 [SlideSelectController.verticalIntent] 决定是否让路。
class SlideSelectController<K> extends ChangeNotifier {
  final Set<K> _selected = <K>{};
  Set<K> _base = const {};
  bool _marqueeActive = false;
  bool _verticalIntent = false;

  Set<K> get selected => _selected;
  bool get hasSelection => _selected.isNotEmpty;

  /// 本次按压是否已进入纵向框选(拖出到 Finder 等行级拖拽应据此让路)
  bool get verticalIntent => _verticalIntent;

  bool contains(K key) => _selected.contains(key);

  void _beginPress() {
    _marqueeActive = false;
    _verticalIntent = false;
    _base = Set.of(_selected);
  }

  /// 进入框选:非追加模式下丢弃按下前的选择(替换式框选)
  void _activateMarquee({required bool additive}) {
    _marqueeActive = true;
    if (!additive) _base = const {};
  }

  /// 框选区间更新:选择 = base ∪ items[lo..hi]
  void _applyRange(int a, int b, List<K> items) {
    if (items.isEmpty) return;
    final lo = (a < b ? a : b).clamp(0, items.length - 1);
    final hi = (a < b ? b : a).clamp(0, items.length - 1);
    final next = <K>{..._base, for (var i = lo; i <= hi; i++) items[i]};
    if (next.length == _selected.length && next.containsAll(_selected)) return;
    _selected
      ..clear()
      ..addAll(next);
    notifyListeners();
  }

  void _endPress() {
    _marqueeActive = false;
    _verticalIntent = false;
    _base = const {};
  }

  void toggle(K key) {
    _selected.contains(key) ? _selected.remove(key) : _selected.add(key);
    notifyListeners();
  }

  /// 单击行:替换为只选中该项
  void replaceWith(K key) {
    if (_selected.length == 1 && _selected.contains(key)) return;
    _selected
      ..clear()
      ..add(key);
    notifyListeners();
  }

  void selectAll(Iterable<K> keys) {
    _selected
      ..clear()
      ..addAll(keys);
    notifyListeners();
  }

  void clear() {
    if (_selected.isEmpty && !_marqueeActive) return;
    _selected.clear();
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

/// 包在列表外面的手势层 + 选框绘制
class SlideSelectArea<K> extends StatefulWidget {
  const SlideSelectArea({
    super.key,
    required this.controller,
    required this.items,
    required this.child,
    this.marqueeColor,
  });

  final SlideSelectController<K> controller;

  /// 当前列表顺序对应的 key 序列(与行 index 对齐)
  final List<K> Function() items;

  /// 选框颜色(默认取主题色)
  final Color? marqueeColor;

  final Widget child;

  @override
  State<SlideSelectArea<K>> createState() => _SlideSelectAreaState<K>();
}

class _SlideSelectAreaState<K> extends State<SlideSelectArea<K>> {
  static const _kMoveSlop = 6.0;

  Offset? _downGlobal;
  Offset? _currentGlobal;
  int? _downIndex;

  /// 框选锚点行(按下点在空白时,取拖动中首个命中的行)
  int? _anchorIndex;
  bool _marquee = false;
  bool _moved = false;

  bool get _additive =>
      HardwareKeyboard.instance.isMetaPressed ||
      HardwareKeyboard.instance.isControlPressed;

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
    _downGlobal = event.position;
    _currentGlobal = event.position;
    _downIndex = _hitRowIndex(event.position);
    _anchorIndex = _downIndex;
    _marquee = false;
    _moved = false;
    widget.controller._beginPress();
  }

  void _handleMove(PointerMoveEvent event) {
    final down = _downGlobal;
    if (down == null) return;
    _currentGlobal = event.position;
    final delta = event.position - down;
    if (!_moved && delta.distance > _kMoveSlop) _moved = true;
    if (!_marquee) {
      // 纵向位移主导才进入框选,横向留给行级拖拽(拖文件到对面栏/Finder)
      if (delta.dy.abs() > _kMoveSlop && delta.dy.abs() > delta.dx.abs()) {
        _marquee = true;
        widget.controller._verticalIntent = true;
        widget.controller._activateMarquee(additive: _additive);
      } else {
        return;
      }
    }
    final index = _hitRowIndex(event.position);
    if (index != null) {
      _anchorIndex ??= index;
      widget.controller._applyRange(_anchorIndex!, index, widget.items());
    }
    setState(() {}); // 重画选框
  }

  void _handleUp(PointerUpEvent event) {
    final controller = widget.controller;
    if (!_marquee && !_moved) {
      // 原地单击:行上 = 选中(⌘ 追加/移除),空白 = 清空
      final index = _downIndex;
      final items = widget.items();
      if (index != null && index >= 0 && index < items.length) {
        _additive
            ? controller.toggle(items[index])
            : controller.replaceWith(items[index]);
      } else if (!_additive) {
        controller.clear();
      }
    }
    controller._endPress();
    _reset();
  }

  void _handleCancel(PointerCancelEvent event) {
    widget.controller._endPress();
    _reset();
  }

  void _reset() {
    setState(() {
      _downGlobal = null;
      _currentGlobal = null;
      _downIndex = null;
      _anchorIndex = null;
      _marquee = false;
      _moved = false;
    });
  }

  Rect? get _marqueeRect {
    if (!_marquee) return null;
    final down = _downGlobal;
    final current = _currentGlobal;
    final box = context.findRenderObject() as RenderBox?;
    if (down == null || current == null || box == null || !box.hasSize) {
      return null;
    }
    final a = box.globalToLocal(down);
    final b = box.globalToLocal(current);
    final bounds = Offset.zero & box.size;
    return Rect.fromPoints(a, b).intersect(bounds);
  }

  @override
  Widget build(BuildContext context) {
    final rect = _marqueeRect;
    final color = widget.marqueeColor ?? Theme.of(context).colorScheme.primary;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _handleDown,
      onPointerMove: _handleMove,
      onPointerUp: _handleUp,
      onPointerCancel: _handleCancel,
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          widget.child,
          if (rect != null && rect.width + rect.height > 4)
            Positioned.fromRect(
              rect: rect,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.08),
                    border: Border.all(color: color.withValues(alpha: 0.45)),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
