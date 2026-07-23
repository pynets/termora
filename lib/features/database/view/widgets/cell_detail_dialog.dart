import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:termora/app/theme/app_theme.dart';
import 'package:termora/core/l10n/app_l10n.dart';

/// 单元格详情对话框的返回:保存新值 / 设为 NULL。取消则返回 null。
class CellDetailResult {
  const CellDetailResult.save(this.value) : setNull = false;
  const CellDetailResult.setNull() : value = '', setNull = true;

  final String value;
  final bool setNull;
}

/// 大内容单元格的查看/编辑弹窗 —— 网格里一行装不下的长文本/JSON,
/// 在这里用大文本域舒展查看;可编辑时能改写保存或设为 NULL。
/// [editable] 为 false 时只读(仅查看 + 复制)。
Future<CellDetailResult?> showCellDetailDialog(
  BuildContext context, {
  required String column,
  required String value,
  required bool editable,
  bool isNull = false,
}) {
  return showDialog<CellDetailResult>(
    context: context,
    useRootNavigator: false,
    barrierColor: Colors.black.withValues(alpha: 0.3),
    builder: (context) => _CellDetailDialog(
      column: column,
      value: value,
      editable: editable,
      isNull: isNull,
    ),
  );
}

class _CellDetailDialog extends StatefulWidget {
  const _CellDetailDialog({
    required this.column,
    required this.value,
    required this.editable,
    required this.isNull,
  });

  final String column;
  final String value;
  final bool editable;
  final bool isNull;

  @override
  State<_CellDetailDialog> createState() => _CellDetailDialogState();
}

class _CellDetailDialogState extends State<_CellDetailDialog> {
  late final TextEditingController _controller;
  late final bool _looksJson;
  bool _pretty = false;

  @override
  void initState() {
    super.initState();
    _looksJson = _tryFormatJson(widget.value) != null;
    // JSON 默认美化显示(更好读);编辑时保存的是文本域里的内容
    _pretty = _looksJson;
    _controller = TextEditingController(
      text: _pretty ? _tryFormatJson(widget.value)! : widget.value,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 能解析成 JSON 则返回缩进美化文本,否则 null
  static String? _tryFormatJson(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    if (!(t.startsWith('{') ||
        t.startsWith('[') ||
        t.startsWith('"'))) {
      return null;
    }
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(t));
    } catch (_) {
      return null;
    }
  }

  void _togglePretty() {
    // 在美化 / 紧凑之间切换(尽量保留用户已改动的内容)
    final current = _controller.text;
    if (_pretty) {
      // 转紧凑
      try {
        _controller.text = jsonEncode(jsonDecode(current));
      } catch (_) {}
      setState(() => _pretty = false);
    } else {
      final formatted = _tryFormatJson(current);
      if (formatted != null) _controller.text = formatted;
      setState(() => _pretty = true);
    }
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _controller.text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(tr('已复制到剪贴板')), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final len = _controller.text.characters.length;
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 头部:列名 + JSON 美化开关
              Row(
                children: [
                  Icon(
                    widget.editable ? LucideIcons.squarePen : LucideIcons.eye,
                    size: 17,
                    color: AppTheme.brandColor,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      widget.editable ? tr2('编辑「{0}」', [widget.column]) : tr2('查看「{0}」', [widget.column]),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.headingColor,
                      ),
                    ),
                  ),
                  if (_looksJson)
                    TextButton.icon(
                      onPressed: _togglePretty,
                      icon: const Icon(LucideIcons.braces, size: 13),
                      label: Text(_pretty ? tr('紧凑') : tr('美化')),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        foregroundColor: AppTheme.subtleTextColor,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              // 大文本域(可编辑则可改;只读则只查看)
              Flexible(
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: AppTheme.mutedSurfaceColor,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppTheme.borderColor),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Scrollbar(
                    child: TextField(
                      controller: _controller,
                      readOnly: !widget.editable,
                      expands: true,
                      maxLines: null,
                      minLines: null,
                      textAlignVertical: TextAlignVertical.top,
                      style: const TextStyle(
                        fontFamily: 'Menlo',
                        fontFamilyFallback: ['Consolas', 'monospace'],
                        fontSize: 12.5,
                        height: 1.35,
                      ),
                      decoration: const InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Text(
                    widget.isNull
                        ? tr('当前为 NULL')
                        : tr2('{0} 个字符', [len]),
                    style: TextStyle(fontSize: 11, color: AppTheme.subtleTextColor),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _copy,
                    icon: const Icon(LucideIcons.clipboardCopy, size: 14),
                    label: Text(tr('复制')),
                  ),
                  if (widget.editable) ...[
                    const SizedBox(width: 4),
                    TextButton(
                      onPressed: () => Navigator.of(context)
                          .pop(const CellDetailResult.setNull()),
                      child: Text(
                        tr('设为 NULL'),
                        style: TextStyle(color: AppTheme.subtleTextColor),
                      ),
                    ),
                  ],
                  const SizedBox(width: 4),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(tr('取消')),
                  ),
                  if (widget.editable) ...[
                    const SizedBox(width: 6),
                    FilledButton.icon(
                      onPressed: () => Navigator.of(context)
                          .pop(CellDetailResult.save(_controller.text)),
                      icon: const Icon(LucideIcons.check, size: 14),
                      label: Text(tr('保存')),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
