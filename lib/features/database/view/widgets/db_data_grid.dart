import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:termora/app/theme/app_theme.dart';
import 'package:termora/core/widgets/glass_menu.dart';
import 'package:termora/features/database/domain/db_models.dart';
import 'package:termora/core/l10n/app_l10n.dart';

/// 查询结果网格 — dbeaver 式累积编辑:
/// 双向滚动、斑马纹、行悬停、列分隔线;编辑写入 [edits] 缓冲(脏格高亮),
/// 支持标记删除行、新增行(绿底),行号槽点删除按钮切换删除。
class DbDataGrid extends StatefulWidget {
  const DbDataGrid({
    super.key,
    required this.output,
    this.editable = false,
    this.edits,
    this.onCellEdit,
    this.onToggleDelete,
    this.sortColumn,
    this.sortAscending = true,
    this.onHeaderTap,
    this.onHeaderFilter,
    this.filteredColumns = const {},
  });

  final DbQueryOutput output;

  /// 是否允许就地编辑(表有主键时)
  final bool editable;

  /// 累积编辑缓冲(null = 只读展示)
  final DbEditSession? edits;

  /// 提交单元格编辑到缓冲:(row, col, newValue, setNull)
  /// row >= output.rows.length 表示新增行
  final void Function(int row, int col, String? value, bool setNull)? onCellEdit;

  /// 切换某行的删除标记
  final void Function(int row)? onToggleDelete;

  /// 当前排序列与方向(表头显示箭头)
  final String? sortColumn;
  final bool sortAscending;

  /// 点击列头(排序);null 时表头不可点
  final void Function(String columnName)? onHeaderTap;

  /// 点击列头漏斗(过滤),带全局位置;null 时不显示漏斗
  final void Function(String columnName, Offset position)? onHeaderFilter;

  /// 已有过滤条件的列(漏斗高亮)
  final Set<String> filteredColumns;

  @override
  State<DbDataGrid> createState() => _DbDataGridState();
}

class _DbDataGridState extends State<DbDataGrid> {
  final _horizontal = ScrollController();
  final _vertical = ScrollController();

  static const _rowHeight = 24.0;
  static const _headerHeight = 26.0;
  static const _rowNumberWidth = 44.0;
  static const _minColWidth = 70.0;
  static const _maxColWidth = 300.0;
  static const _cellPadding = EdgeInsets.symmetric(horizontal: 6);

  late List<double> _colWidths;
  int? _hoveredRow;

  // 内联编辑态
  int? _editingRow;
  int? _editingCol;
  TextEditingController? _editController;
  final FocusNode _editFocus = FocusNode();

  /// 进入编辑时的原始文本/值 — 用于判断是否真的改动过(没改则不记入缓冲)
  String _editOriginalText = '';
  Object? _editOriginalValue;

  DbEditSession get _edits => widget.edits ?? DbEditSession();

  /// 新增行数量
  int get _addedCount => _edits.addedRows.length;

  /// 总显示行数 = 原始行 + 新增行
  int get _totalRows => widget.output.rows.length + _addedCount;

  @override
  void initState() {
    super.initState();
    _measureColumns();
    // 编辑框内的键盘导航:Tab/Enter 提交并移到相邻格,Esc 取消
    _editFocus.onKeyEvent = _handleEditKey;
  }

  @override
  void didUpdateWidget(covariant DbDataGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.output.columns.join(' ') !=
        widget.output.columns.join(' ')) {
      _measureColumns();
      _hoveredRow = null;
      _cancelEdit();
    }
    // 新增了行 → 自动滚到底并进入首列编辑,省去手动双击
    final oldAdded = oldWidget.edits?.addedRows.length ?? 0;
    final newAdded = widget.edits?.addedRows.length ?? 0;
    if (newAdded > oldAdded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final r = _totalRows - 1;
        _ensureRowVisible(r);
        _startEdit(r, 0);
      });
    }
  }

  @override
  void dispose() {
    _horizontal.dispose();
    _vertical.dispose();
    _editController?.dispose();
    _editFocus.dispose();
    super.dispose();
  }

  void _measureColumns() {
    final output = widget.output;
    _colWidths = List.filled(output.columns.length, _minColWidth);
    for (var c = 0; c < output.columns.length; c++) {
      var maxChars = output.columns[c].length;
      for (var r = 0; r < output.rows.length && r < 30; r++) {
        final len = _cellText(output.rows[r][c]).length;
        if (len > maxChars) maxChars = len;
      }
      _colWidths[c] = (maxChars * 6.2 + 18).clamp(_minColWidth, _maxColWidth);
    }
  }

  void _autoFitColumn(int c) {
    final output = widget.output;
    var maxChars = output.columns[c].length;
    for (var r = 0; r < output.rows.length; r++) {
      final len = _cellText(output.rows[r][c]).length;
      if (len > maxChars) maxChars = len;
    }
    setState(() {
      _colWidths[c] = (maxChars * 6.2 + 18).clamp(30.0, 1500.0);
    });
  }

  static String _cellText(Object? value) {
    if (identical(value, DbEditSession.unsetValue)) return '';
    if (value == null) return 'NULL';
    if (value is DateTime) return value.toIso8601String();
    if (value is List<int>) return '<${value.length} bytes>';
    final text = value.toString();
    return text.length > 300 ? '${text.substring(0, 300)}…' : text;
  }

  double get _totalWidth =>
      _colWidths.fold(0.0, (a, b) => a + b) + _rowNumberWidth;

  TextStyle get _monoStyle => TextStyle(
    fontFamily: 'Menlo',
    fontFamilyFallback: const ['Consolas', 'monospace'],
    fontSize: 10.5,
    color: AppTheme.headingColor,
    height: 1.15,
  );

  BorderSide get _columnSeparator => BorderSide(
    color: AppTheme.borderColor.withValues(alpha: 0.45),
    width: 0.5,
  );

  /// 取某显示行、某列的当前值(叠加编辑缓冲)
  Object? _valueAt(int row, int col) {
    final originalCount = widget.output.rows.length;
    if (row >= originalCount) {
      return _edits.addedRows[row - originalCount][col];
    }
    return _edits.displayValue(row, col, widget.output.rows[row][col]);
  }

  bool _isAddedRow(int row) => row >= widget.output.rows.length;

  bool _isRemoved(int row) =>
      !_isAddedRow(row) && _edits.isRowRemoved(row);

  bool _isEditedCell(int row, int col) =>
      !_isAddedRow(row) && _edits.isCellEdited(row, col);

  // ── 编辑动作 ──

  void _startEdit(int row, int col) {
    if (!widget.editable || widget.onCellEdit == null) return;
    if (_isRemoved(row)) return;
    final value = _valueAt(row, col);
    final initialText = switch (value) {
      DbEditSession.unsetValue => '',
      null => '',
      DateTime dt => dt.toIso8601String(),
      _ => value.toString(),
    };
    _editController?.dispose();
    _editController = TextEditingController(text: initialText);
    _editOriginalText = initialText;
    _editOriginalValue = value;
    setState(() {
      _editingRow = row;
      _editingCol = col;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _editFocus.requestFocus();
      _editController?.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _editController?.text.length ?? 0,
      );
    });
  }

  void _cancelEdit() {
    if (_editingRow == null) return;
    setState(() {
      _editingRow = null;
      _editingCol = null;
    });
  }

  void _commitEdit({bool setNull = false}) {
    final row = _editingRow;
    final col = _editingCol;
    final controller = _editController;
    if (row == null || col == null || controller == null) return;
    final origText = _editOriginalText;
    final origValue = _editOriginalValue;
    _cancelEdit();

    if (setNull) {
      // 原本就是 NULL(且非"未设置")→ 无变化,不记改动
      if (origValue == null) return;
      widget.onCellEdit?.call(row, col, null, true);
      return;
    }
    // 值未变化(含新增行留空的格)→ 不产生改动
    if (controller.text == origText) return;
    widget.onCellEdit?.call(row, col, controller.text, false);
  }

  /// 编辑框内按键:Tab→右一格,Shift+Tab→左一格,Enter→下一行同列,Esc→取消
  KeyEventResult _handleEditKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _cancelEdit();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.tab) {
      final shift = HardwareKeyboard.instance.isShiftPressed;
      _commitAndMove(colDelta: shift ? -1 : 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _commitAndMove(rowDelta: 1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 提交当前格并移动到相邻格继续编辑(越列自动换行)
  void _commitAndMove({int colDelta = 0, int rowDelta = 0}) {
    final row = _editingRow;
    final col = _editingCol;
    if (row == null || col == null) return;
    _commitEdit();

    var nc = col + colDelta;
    var nr = row + rowDelta;
    final cols = widget.output.columns.length;
    if (nc >= cols) {
      nc = 0;
      nr += 1;
    } else if (nc < 0) {
      nc = cols - 1;
      nr -= 1;
    }
    if (nr < 0 || nr >= _totalRows) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _ensureRowVisible(nr);
      _startEdit(nr, nc);
    });
  }

  /// 确保某显示行在纵向视口内
  void _ensureRowVisible(int r) {
    if (!_vertical.hasClients) return;
    final target = r * _rowHeight;
    final start = _vertical.offset;
    final viewport = _vertical.position.viewportDimension;
    if (target < start) {
      _vertical.jumpTo(target.clamp(0.0, _vertical.position.maxScrollExtent));
    } else if (target + _rowHeight > start + viewport) {
      _vertical.jumpTo(
        (target + _rowHeight - viewport)
            .clamp(0.0, _vertical.position.maxScrollExtent),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      controller: _horizontal,
      child: SingleChildScrollView(
        controller: _horizontal,
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: _totalWidth,
          child: Column(
            children: [
              _buildHeader(),
              Expanded(
                child: Scrollbar(
                  controller: _vertical,
                  child: ListView.builder(
                    controller: _vertical,
                    itemExtent: _rowHeight,
                    itemCount: _totalRows,
                    itemBuilder: (context, r) => _buildRow(r),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final output = widget.output;
    return Container(
      height: _headerHeight,
      decoration: BoxDecoration(
        color: AppTheme.subtleSurfaceColor,
        border: Border(
          bottom: BorderSide(color: AppTheme.borderColor, width: 1),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: _rowNumberWidth,
            padding: _cellPadding,
            alignment: Alignment.centerRight,
            decoration: BoxDecoration(border: Border(right: _columnSeparator)),
            child: Text(
              '#',
              style: _monoStyle.copyWith(
                fontSize: 9.5,
                fontWeight: FontWeight.w700,
                color: AppTheme.subtleTextColor,
              ),
            ),
          ),
          for (var c = 0; c < output.columns.length; c++)
            _buildHeaderCell(c, output.columns[c], _colWidths[c]),
        ],
      ),
    );
  }

  Widget _buildHeaderCell(int colIndex, String name, double width) {
    final sorted = widget.sortColumn == name;
    final filtered = widget.filteredColumns.contains(name);
    return Container(
      width: width,
      decoration: BoxDecoration(border: Border(right: _columnSeparator)),
      child: Stack(
        children: [
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.only(left: 6, right: 4),
              child: Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: widget.onHeaderTap == null
                          ? null
                          : () => widget.onHeaderTap!(name),
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              name,
                              overflow: TextOverflow.ellipsis,
                              style: _monoStyle.copyWith(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: sorted
                                    ? AppTheme.brandColor
                                    : AppTheme.headingColor,
                              ),
                            ),
                          ),
                          if (sorted) ...[
                            const SizedBox(width: 2),
                            Icon(
                              widget.sortAscending
                                  ? Icons.arrow_upward_rounded
                                  : Icons.arrow_downward_rounded,
                              size: 12,
                              color: AppTheme.brandColor,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  if (widget.onHeaderFilter != null)
                    _HeaderFilterButton(
                      active: filtered,
                      onPressed: (pos) => widget.onHeaderFilter!(name, pos),
                    ),
                ],
              ),
            ),
          ),
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onDoubleTap: () => _autoFitColumn(colIndex),
                onHorizontalDragUpdate: (details) {
                  setState(() {
                    _colWidths[colIndex] =
                        (_colWidths[colIndex] + details.delta.dx).clamp(30.0, 1500.0);
                  });
                },
                child: Container(
                  width: 8,
                  color: Colors.transparent,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRow(int r) {
    final row = _buildRowCells(r);
    final hovered = _hoveredRow == r;
    final added = _isAddedRow(r);
    final removed = _isRemoved(r);

    final Color background;
    if (removed) {
      background = AppTheme.errorColor.withValues(alpha: 0.10);
    } else if (added) {
      background = AppTheme.successColor.withValues(alpha: 0.10);
    } else if (hovered) {
      background = AppTheme.softBrandColor.withValues(alpha: 0.55);
    } else if (r.isOdd) {
      background = AppTheme.mutedSurfaceColor;
    } else {
      background = AppTheme.surfaceColor;
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _hoveredRow = r),
      onExit: (_) => setState(() {
        if (_hoveredRow == r) _hoveredRow = null;
      }),
      child: Container(color: background, child: Row(children: row)),
    );
  }

  List<Widget> _buildRowCells(int r) {
    final removed = _isRemoved(r);
    final added = _isAddedRow(r);
    return [
      // 行号槽 + 删除/恢复按钮
      SizedBox(
        width: _rowNumberWidth,
        child: Row(
          children: [
            const SizedBox(width: 2),
            if (widget.editable && widget.onToggleDelete != null)
              InkWell(
                onTap: () => widget.onToggleDelete!(r),
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: Icon(
                    added
                        ? Icons.close_rounded
                        : (removed
                              ? Icons.undo_rounded
                              : Icons.remove_circle_outline_rounded),
                    size: 11,
                    color: removed || added
                        ? AppTheme.errorColor
                        : AppTheme.subtleTextColor.withValues(alpha: 0.55),
                  ),
                ),
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text(
                  added ? '＋' : '${r + 1}',
                  textAlign: TextAlign.right,
                  style: _monoStyle.copyWith(
                    fontSize: 9.5,
                    color: AppTheme.subtleTextColor,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      for (var c = 0; c < widget.output.columns.length; c++)
        _buildCell(r, c),
    ];
  }

  Widget _buildCell(int r, int c) {
    if (_editingRow == r && _editingCol == c) {
      return _buildEditingCell(c);
    }

    final value = _valueAt(r, c);
    final isUnset = identical(value, DbEditSession.unsetValue);
    final isNull = value == null;
    final text = _cellText(value);
    final edited = _isEditedCell(r, c);
    final removed = _isRemoved(r);

    final bg = edited ? AppTheme.warningColor.withValues(alpha: 0.22) : null;

    return GestureDetector(
      // 双击进入编辑;单击不做复制(避免双击时先弹复制提示),复制走右键菜单
      onDoubleTap: widget.editable ? () => _startEdit(r, c) : null,
      onSecondaryTapDown: (details) =>
          _showCellMenu(details.globalPosition, r, c, value),
      child: Container(
        width: _colWidths[c],
        height: _rowHeight,
        padding: _cellPadding,
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: bg,
          border: Border(right: _columnSeparator),
        ),
        child: Text(
          text,
          overflow: TextOverflow.ellipsis,
          style: (isNull || isUnset)
              ? _monoStyle.copyWith(
                  fontStyle: FontStyle.italic,
                  color: AppTheme.subtleTextColor.withValues(alpha: 0.65),
                  decoration: removed ? TextDecoration.lineThrough : null,
                )
              : _monoStyle.copyWith(
                  decoration: removed ? TextDecoration.lineThrough : null,
                  fontWeight: edited ? FontWeight.w600 : FontWeight.w400,
                ),
        ),
      ),
    );
  }

  Widget _buildEditingCell(int c) {
    // Tab/Enter/Esc 由 _editFocus.onKeyEvent 统一处理;点击别处提交
    return Container(
      width: _colWidths[c],
      height: _rowHeight,
      decoration: BoxDecoration(
        color: AppTheme.surfaceColor,
        border: Border.all(color: AppTheme.brandColor, width: 1.5),
      ),
      child: TextField(
        controller: _editController,
        focusNode: _editFocus,
        style: _monoStyle,
        textAlignVertical: TextAlignVertical.center,
        decoration: const InputDecoration(
          isDense: true,
          border: InputBorder.none,
          contentPadding: EdgeInsets.symmetric(horizontal: 6),
        ),
        onTapOutside: (_) => _commitEdit(),
      ),
    );
  }

  void _showCellMenu(Offset position, int r, int c, Object? value) {
    final text = _cellText(value);
    showGlassMenu<String>(
      context: context,
      position: position,
      items: [
        PopupMenuItem(value: 'copy', height: 36, child: Text(tr('复制值'), style: TextStyle(fontSize: 13))),
        PopupMenuItem(value: 'copy_row', height: 36, child: Text(tr('复制整行(CSV)'), style: TextStyle(fontSize: 13))),
        if (widget.editable) ...[
          const PopupMenuDivider(),
          PopupMenuItem(value: 'edit', height: 36, child: Text(tr('编辑'), style: TextStyle(fontSize: 13))),
          PopupMenuItem(value: 'set_null', height: 36, child: Text(tr('设为 NULL'), style: TextStyle(fontSize: 13))),
          PopupMenuItem(
            value: 'delete',
            height: 36,
            child: Text(
              _isRemoved(r) ? tr('恢复此行') : tr('标记删除此行'),
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ],
    ).then((action) {
      if (action == null || !mounted) return;
      switch (action) {
        case 'copy':
          Clipboard.setData(ClipboardData(text: value?.toString() ?? ''));
        case 'copy_row':
          final cells = [
            for (var i = 0; i < widget.output.columns.length; i++)
              _cellText(_valueAt(r, i)),
          ];
          Clipboard.setData(ClipboardData(text: cells.join(',')));
        case 'edit':
          _startEdit(r, c);
        case 'set_null':
          widget.onCellEdit?.call(r, c, null, true);
        case 'delete':
          widget.onToggleDelete?.call(r);
      }
    });
    // 引用 text 避免未使用告警(部分平台菜单未展开时)
    assert(text.isEmpty || text.isNotEmpty);
  }
}

/// 列头漏斗过滤按钮 — 点击时把自身屏幕位置回传,便于在其下方弹出面板
class _HeaderFilterButton extends StatelessWidget {
  const _HeaderFilterButton({required this.active, required this.onPressed});

  final bool active;
  final void Function(Offset position) onPressed;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {
        final box = context.findRenderObject() as RenderBox?;
        final pos = box == null
            ? Offset.zero
            : box.localToGlobal(box.size.bottomLeft(Offset.zero));
        onPressed(pos);
      },
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: Icon(
          active ? Icons.filter_alt_rounded : Icons.filter_alt_outlined,
          size: 13,
          color: active
              ? AppTheme.brandColor
              : AppTheme.subtleTextColor.withValues(alpha: 0.55),
        ),
      ),
    );
  }
}
