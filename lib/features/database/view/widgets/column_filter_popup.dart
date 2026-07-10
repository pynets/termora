import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:termora/app/theme/app_theme.dart';
import 'package:termora/core/widgets/glass_menu.dart';
import 'package:termora/features/database/domain/db_models.dart';
import 'package:termora/core/l10n/app_l10n.dart';

/// 在 [position] 下方弹出列过滤面板。返回:
/// - 新的 DbColumnFilter(应用)
/// - const DbColumnFilter(column: '', op: equals)(清除,以 column 空判断)
/// - null(取消)
Future<DbColumnFilter?> showColumnFilterPopup(
  BuildContext context, {
  required String column,
  DbColumnFilter? existing,
  required Offset position,
}) {
  return showDialog<DbColumnFilter>(
    context: context,
    barrierColor: Colors.transparent,
    builder: (context) => _ColumnFilterPopup(
      column: column,
      existing: existing,
      position: position,
    ),
  );
}

class _ColumnFilterPopup extends StatefulWidget {
  const _ColumnFilterPopup({
    required this.column,
    required this.existing,
    required this.position,
  });

  final String column;
  final DbColumnFilter? existing;
  final Offset position;

  @override
  State<_ColumnFilterPopup> createState() => _ColumnFilterPopupState();
}

class _ColumnFilterPopupState extends State<_ColumnFilterPopup> {
  late DbFilterOp _op;
  late final TextEditingController _valueController;

  @override
  void initState() {
    super.initState();
    _op = widget.existing?.op ?? DbFilterOp.equals;
    _valueController = TextEditingController(text: widget.existing?.value ?? '');
  }

  @override
  void dispose() {
    _valueController.dispose();
    super.dispose();
  }

  void _apply() {
    Navigator.of(context).pop(
      DbColumnFilter(
        column: widget.column,
        op: _op,
        value: _op.needsValue ? _valueController.text : '',
      ),
    );
  }

  void _clear() {
    // 空 column 作为"清除该列过滤"的哨兵
    Navigator.of(context).pop(
      const DbColumnFilter(column: '', op: DbFilterOp.equals),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.of(context).size;
    const width = 260.0;
    var left = widget.position.dx;
    if (left + width > screen.width) left = screen.width - width - 8;
    var top = widget.position.dy + 2;
    if (top + 210 > screen.height) top = screen.height - 210;

    return Stack(
      children: [
        Positioned(
          left: left,
          top: top,
          child: Material(
            color: Colors.transparent,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                child: Container(
                  width: width,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).brightness == Brightness.dark
                        ? AppTheme.surfaceColor.withValues(alpha: 0.70)
                        : AppTheme.surfaceColor.withValues(alpha: 0.80),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: Theme.of(context).brightness == Brightness.dark
                          ? AppTheme.surfaceColor.withValues(alpha: 0.20)
                          : AppTheme.headingColor.withValues(alpha: 0.10),
                      width: 0.5,
                    ),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x22000000),
                        blurRadius: 16,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        LucideIcons.listFilter,
                        size: 13,
                        color: AppTheme.brandColor,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          widget.column,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.headingColor,
                            fontFamily: 'Menlo',
                            fontFamilyFallback: const [
                              'Consolas',
                              'monospace',
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  GlassDropdownButton<DbFilterOp>(
                    value: _op,
                    items: [
                      for (final op in DbFilterOp.values)
                        GlassDropdownMenuItem(
                          value: op,
                          child: Text(
                            '${op.symbol}  ${op.label}',
                            style: const TextStyle(fontSize: 12.5),
                          ),
                        ),
                    ],
                    onChanged: (op) => setState(() => _op = op ?? _op),
                  ),
                  if (_op.needsValue) ...[
                    const SizedBox(height: 8),
                    TextField(
                      controller: _valueController,
                      autofocus: true,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: AppTheme.headingColor,
                      ),
                      decoration: InputDecoration(
                        hintText: _op == DbFilterOp.inList
                            ? tr('逗号分隔多个值')
                            : tr('值'),
                        hintStyle: TextStyle(
                          fontSize: 12,
                          color: AppTheme.subtleTextColor.withValues(alpha: 0.7),
                        ),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(color: AppTheme.borderColor),
                        ),
                      ),
                      onSubmitted: (_) => _apply(),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      if (widget.existing != null)
                        TextButton(
                          onPressed: _clear,
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          ),
                          child: Text(
                            tr('清除'),
                            style: TextStyle(
                              fontSize: 12,
                              color: AppTheme.errorColor,
                            ),
                          ),
                        ),
                      const Spacer(),
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                        child: Text(tr('取消'), style: TextStyle(fontSize: 12)),
                      ),
                      const SizedBox(width: 4),
                      FilledButton(
                        onPressed: _apply,
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                        child: Text(tr('应用'), style: TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  ],
);
  }
}
