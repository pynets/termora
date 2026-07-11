import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:termora/app/theme/app_theme.dart';
import 'package:termora/core/l10n/app_l10n.dart';

/// 变量管理弹窗 — 编辑全部 `${name}` 变量,返回完整映射(取消返回 null)
Future<Map<String, String>?> showVariablesDialog(
  BuildContext context, {
  required Map<String, String> variables,
}) {
  return showDialog<Map<String, String>>(
    context: context,
    useRootNavigator: false,
    barrierColor: Colors.black.withValues(alpha: 0.3),
    builder: (context) => _VariablesDialog(
      title: tr('SQL 变量'),
      description: '在 SQL 中用 \${变量名} 引用,执行时自动替换',
      initial: variables,
      allowAddRemove: true,
    ),
  );
}

/// 缺失变量补填弹窗 — 执行前发现未定义的 `${name}` 时调用,
/// 返回这些变量的取值(取消返回 null)
Future<Map<String, String>?> promptMissingVariables(
  BuildContext context, {
  required List<String> names,
  String title = '填写变量',
  String hint = 'SQL 引用了未定义的变量,请填写取值(会保存供下次使用)',
}) {
  return showDialog<Map<String, String>>(
    context: context,
    useRootNavigator: false,
    barrierColor: Colors.black.withValues(alpha: 0.3),
    builder: (context) => _VariablesDialog(
      title: title,
      description: hint,
      initial: {for (final name in names) name: ''},
      allowAddRemove: false,
    ),
  );
}

class _VariablesDialog extends StatefulWidget {
  const _VariablesDialog({
    required this.title,
    required this.description,
    required this.initial,
    required this.allowAddRemove,
  });

  final String title;
  final String description;
  final Map<String, String> initial;
  final bool allowAddRemove;

  @override
  State<_VariablesDialog> createState() => _VariablesDialogState();
}

class _VariableRow {
  _VariableRow(String name, String value)
    : name = TextEditingController(text: name),
      value = TextEditingController(text: value);

  final TextEditingController name;
  final TextEditingController value;

  void dispose() {
    name.dispose();
    value.dispose();
  }
}

class _VariablesDialogState extends State<_VariablesDialog> {
  late final List<_VariableRow> _rows;

  @override
  void initState() {
    super.initState();
    _rows = [
      for (final entry in widget.initial.entries)
        _VariableRow(entry.key, entry.value),
    ];
    if (_rows.isEmpty && widget.allowAddRemove) {
      _rows.add(_VariableRow('', ''));
    }
  }

  @override
  void dispose() {
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  Map<String, String> _collect() {
    final result = <String, String>{};
    for (final row in _rows) {
      final name = row.name.text.trim();
      if (name.isNotEmpty) {
        result[name] = row.value.text;
      }
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final mono = TextStyle(
      fontFamily: 'Menlo',
      fontFamilyFallback: const ['Consolas', 'monospace'],
      fontSize: 12.5,
      color: AppTheme.headingColor,
    );

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 520),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(LucideIcons.variable, size: 17, color: AppTheme.brandColor),
                  const SizedBox(width: 8),
                  Text(
                    widget.title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.headingColor,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                widget.description,
                style: TextStyle(fontSize: 11.5, color: AppTheme.subtleTextColor),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      for (var i = 0; i < _rows.length; i++) _buildRow(i, mono),
                    ],
                  ),
                ),
              ),
              if (widget.allowAddRemove) ...[
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () =>
                        setState(() => _rows.add(_VariableRow('', ''))),
                    icon: const Icon(LucideIcons.plus, size: 13),
                    label: Text(tr('添加变量'), style: TextStyle(fontSize: 12)),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(tr('取消')),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(_collect()),
                    child: Text(widget.allowAddRemove ? tr('保存') : tr('执行')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRow(int index, TextStyle mono) {
    final row = _rows[index];
    InputDecoration decoration(String hint) => InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(
        fontSize: 12,
        color: AppTheme.subtleTextColor.withValues(alpha: 0.6),
      ),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(7),
        borderSide: BorderSide(color: AppTheme.borderColor),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(7),
        borderSide: BorderSide(color: AppTheme.borderColor),
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: TextField(
              controller: row.name,
              readOnly: !widget.allowAddRemove,
              style: mono,
              decoration: decoration(tr('变量名')),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              '=',
              style: TextStyle(color: AppTheme.subtleTextColor, fontSize: 13),
            ),
          ),
          Expanded(
            flex: 3,
            child: TextField(
              controller: row.value,
              autofocus: !widget.allowAddRemove && index == 0,
              style: mono,
              decoration: decoration(tr('值')),
            ),
          ),
          if (widget.allowAddRemove)
            IconButton(
              tooltip: tr('删除'),
              visualDensity: VisualDensity.compact,
              icon: Icon(LucideIcons.x, size: 13, color: AppTheme.subtleTextColor),
              onPressed: () => setState(() => _rows.removeAt(index).dispose()),
            ),
        ],
      ),
    );
  }
}
