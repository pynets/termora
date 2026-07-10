import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:termora/app/theme/app_theme.dart';
import 'package:termora/features/notes/domain/markdown_parser.dart';
import 'package:termora/features/notes/domain/markdown_table_edit.dart';
import 'package:termora/core/l10n/app_l10n.dart';

/// 块式编辑器里的可编辑表格:点单元格就地改,Tab/Enter 在格间移动,
/// 最后一格按 Tab 自动加行;hover 出现加行/加列/源码按钮。
class EditableTableBlock extends StatefulWidget {
  const EditableTableBlock({
    super.key,
    required this.source,
    required this.onChanged,
    required this.onEditSource,
    required this.onBeforeEdit,
  });

  /// 表格块源码
  final String source;
  final ValueChanged<String> onChanged;

  /// 退回整块源码编辑
  final VoidCallback onEditSource;

  /// 开始编辑单元格前回调(块编辑器用来先提交别的块)
  final VoidCallback onBeforeEdit;

  @override
  State<EditableTableBlock> createState() => _EditableTableBlockState();
}

class _EditableTableBlockState extends State<EditableTableBlock> {
  /// 正在编辑的单元格 (row, col);row -1 = 表头
  (int, int)? _editing;

  final TextEditingController _cellController = TextEditingController();
  final FocusNode _cellFocus = FocusNode();
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _cellFocus.addListener(() {
      if (!_cellFocus.hasFocus) _commitCell();
    });
    _cellFocus.onKeyEvent = _onCellKey;
  }

  @override
  void dispose() {
    _cellController.dispose();
    _cellFocus.dispose();
    super.dispose();
  }

  void _startCell(int row, int col, {String? sourceOverride}) {
    widget.onBeforeEdit();
    setState(() {
      _editing = (row, col);
      _cellController.text = MarkdownTableEdit.cellAt(
        sourceOverride ?? widget.source,
        row,
        col,
      );
      _cellController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _cellController.text.length,
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _cellFocus.requestFocus();
    });
  }

  /// 提交当前格,返回提交后的表格源码(供连续移动时同步读取)
  String _commitCell() {
    final editing = _editing;
    if (editing == null) return widget.source;
    final next = MarkdownTableEdit.setCell(
      widget.source,
      editing.$1,
      editing.$2,
      _cellController.text,
    );
    setState(() => _editing = null);
    if (next != widget.source) widget.onChanged(next);
    return next;
  }

  KeyEventResult _onCellKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || _editing == null) {
      return KeyEventResult.ignored;
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.tab:
        _moveEditing(
          HardwareKeyboard.instance.isShiftPressed ? -1 : 1,
          rowDelta: 0,
        );
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        _moveEditing(0, rowDelta: 1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        _commitCell();
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  /// Tab 横移(尾格换行,最后一格自动加行);Enter 纵移(末行提交收起)
  void _moveEditing(int colDelta, {required int rowDelta}) {
    final editing = _editing;
    if (editing == null) return;
    var (row, col) = editing;
    var source = _commitCell();

    final columns = MarkdownTableEdit.columnCount(source);
    var rows = MarkdownTableEdit.dataRowCount(source);

    if (rowDelta != 0) {
      row += rowDelta;
      if (row >= rows) return; // 末行 Enter:提交收起
    } else {
      col += colDelta;
      if (col >= columns) {
        col = 0;
        row += 1;
        if (row >= rows) {
          source = MarkdownTableEdit.addRow(source); // 尾格 Tab 加行
          widget.onChanged(source);
          rows += 1;
        }
      } else if (col < 0) {
        col = columns - 1;
        row -= 1;
      }
    }
    if (row < -1) return;
    _startCell(row, col, sourceOverride: source);
  }

  void _addRow() {
    widget.onBeforeEdit();
    _commitCell();
    widget.onChanged(MarkdownTableEdit.addRow(widget.source));
  }

  void _addColumn() {
    widget.onBeforeEdit();
    _commitCell();
    widget.onChanged(MarkdownTableEdit.addColumn(widget.source));
  }

  @override
  Widget build(BuildContext context) {
    final source = widget.source;
    if (!MarkdownTableEdit.isTable(source)) return const SizedBox.shrink();
    final lines = source.split('\n');
    final header = MarkdownTableEdit.splitRow(lines[0]);
    final dataRows = [
      for (var i = 2; i < lines.length; i++) MarkdownTableEdit.splitRow(lines[i]),
    ];
    final alignments = MarkdownTableEdit.alignments(source);
    TextAlign alignAt(int col) => switch (
        col < alignments.length ? alignments[col] : MdTableAlign.left) {
      MdTableAlign.left => TextAlign.left,
      MdTableAlign.center => TextAlign.center,
      MdTableAlign.right => TextAlign.right,
    };

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 26,
            child: _hovered ? _buildActions() : null,
          ),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Table(
              border: TableBorder.all(color: AppTheme.borderColor, width: 0.6),
              defaultColumnWidth: const IntrinsicColumnWidth(),
              children: [
                TableRow(
                  decoration: BoxDecoration(color: AppTheme.mutedSurfaceColor),
                  children: [
                    for (var c = 0; c < header.length; c++)
                      _buildCell(-1, c, header[c], header: true,
                          textAlign: TextAlign.center),
                  ],
                ),
                for (var r = 0; r < dataRows.length; r++)
                  TableRow(
                    children: [
                      for (var c = 0; c < header.length; c++)
                        _buildCell(
                          r,
                          c,
                          c < dataRows[r].length ? dataRows[r][c] : '',
                          textAlign: alignAt(c),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActions() {
    Widget action(IconData icon, String label, VoidCallback onTap) {
      return InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 12, color: AppTheme.subtleTextColor),
              const SizedBox(width: 3),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: AppTheme.subtleTextColor,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Row(
      children: [
        action(LucideIcons.plus, tr('行'), _addRow),
        action(LucideIcons.plus, tr('列'), _addColumn),
        action(LucideIcons.code, tr('源码'), () {
          _commitCell();
          widget.onEditSource();
        }),
      ],
    );
  }

  Widget _buildCell(
    int row,
    int col,
    String content, {
    bool header = false,
    required TextAlign textAlign,
  }) {
    final isEditing = _editing == (row, col);
    final style = TextStyle(
      fontSize: 13,
      height: 1.5,
      fontWeight: header ? FontWeight.w600 : FontWeight.w400,
      color: header ? AppTheme.headingColor : AppTheme.bodyColor,
    );

    if (isEditing) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 60),
          child: TextField(
            controller: _cellController,
            focusNode: _cellFocus,
            style: style,
            textAlign: textAlign,
            cursorColor: AppTheme.brandColor,
            decoration: const InputDecoration(
              isDense: true,
              border: InputBorder.none,
              contentPadding: EdgeInsets.symmetric(vertical: 5),
            ),
            onTapOutside: (_) {
              _commitCell();
              _cellFocus.unfocus();
            },
          ),
        ),
      );
    }

    return InkWell(
      onTap: () => _startCell(row, col),
      child: Container(
        constraints: const BoxConstraints(minWidth: 60, minHeight: 30),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        alignment: switch (textAlign) {
          TextAlign.center => Alignment.center,
          TextAlign.right => Alignment.centerRight,
          _ => Alignment.centerLeft,
        },
        child: Text(content.isEmpty ? ' ' : content, style: style),
      ),
    );
  }
}
