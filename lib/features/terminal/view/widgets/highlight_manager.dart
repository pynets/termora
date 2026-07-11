import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:termora/app/theme/app_theme.dart';
import 'package:termora/features/terminal/data/highlight_store.dart';
import 'package:termora/core/l10n/app_l10n.dart';

/// 打开触发器高亮规则管理弹窗。
Future<void> showHighlightManager(BuildContext context) async {
  await HighlightStore.ensureLoaded();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    useRootNavigator: false,
    barrierColor: Colors.black.withValues(alpha: 0.3),
    builder: (context) => const _HighlightManagerDialog(),
  );
}

/// 可选前景色(命中文本上色);覆盖常见语义色。
const _palette = <Color>[
  Color(0xFFFF5555), // 红 error
  Color(0xFFFFB454), // 橙 warn
  Color(0xFFF1FA8C), // 黄
  Color(0xFF50FA7B), // 绿 ok
  Color(0xFF8BE9FD), // 青 info
  Color(0xFFBD93F9), // 紫
  Color(0xFFFF79C6), // 粉
  Color(0xFFAAAAAA), // 灰 dim
];

class _HighlightManagerDialog extends StatelessWidget {
  const _HighlightManagerDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Icon(LucideIcons.highlighter300, size: 17, color: AppTheme.brandColor),
          const SizedBox(width: 8),
          Text(tr('触发器高亮')),
        ],
      ),
      content: SizedBox(
        width: 480,
        height: 380,
        child: ValueListenableBuilder<List<HighlightRule>>(
          valueListenable: HighlightStore.rules,
          builder: (context, list, _) {
            if (list.isEmpty) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      LucideIcons.highlighter300,
                      size: 26,
                      color: AppTheme.subtleTextColor.withValues(alpha: 0.5),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      tr('还没有高亮规则,点「新建」添加'),
                      style: TextStyle(
                        fontSize: 12.5,
                        color: AppTheme.subtleTextColor,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      tr('如把含 ERROR / FAIL 的行标红,便于快速定位'),
                      style: TextStyle(
                        fontSize: 11,
                        color: AppTheme.subtleTextColor,
                      ),
                    ),
                  ],
                ),
              );
            }
            return ListView.separated(
              itemCount: list.length,
              separatorBuilder: (_, _) =>
                  Divider(height: 1, color: AppTheme.borderColor),
              itemBuilder: (context, i) => _row(context, list[i]),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => _edit(context, null),
          child: Text(tr('新建')),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppTheme.brandColor),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('完成')),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, HighlightRule rule) {
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Container(
        width: 22,
        height: 22,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: rule.color.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Text(
          'Aa',
          style: TextStyle(
            fontSize: 10,
            fontWeight: rule.bold ? FontWeight.w700 : FontWeight.w400,
            color: rule.color,
          ),
        ),
      ),
      title: Text(
        rule.name.isEmpty ? rule.pattern : rule.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12.5, color: AppTheme.headingColor),
      ),
      subtitle: Text(
        '${rule.isRegex ? tr('正则') : tr('包含')} 「${rule.pattern}」'
        '${rule.wholeLine ? tr(' · 整行') : tr(' · 片段')}'
        '${rule.caseSensitive ? tr(' · 区分大小写') : ''}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 10.5, color: AppTheme.subtleTextColor),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch(
            value: rule.enabled,
            activeThumbColor: AppTheme.brandColor,
            onChanged: (v) =>
                HighlightStore.upsert(rule.copyWith(enabled: v)),
          ),
          IconButton(
            tooltip: tr('编辑'),
            icon: Icon(LucideIcons.penLine300, size: 15),
            onPressed: () => _edit(context, rule),
          ),
          IconButton(
            tooltip: tr('删除'),
            icon: Icon(LucideIcons.trash300, size: 15, color: AppTheme.errorColor),
            onPressed: () => HighlightStore.remove(rule.id),
          ),
        ],
      ),
    );
  }

  Future<void> _edit(BuildContext context, HighlightRule? existing) async {
    final rule = await showDialog<HighlightRule>(
      context: context,
      useRootNavigator: false,
      barrierColor: Colors.black.withValues(alpha: 0.3),
      builder: (context) => _HighlightEditDialog(existing: existing),
    );
    if (rule != null) await HighlightStore.upsert(rule);
  }
}

class _HighlightEditDialog extends StatefulWidget {
  const _HighlightEditDialog({this.existing});

  final HighlightRule? existing;

  @override
  State<_HighlightEditDialog> createState() => _HighlightEditDialogState();
}

class _HighlightEditDialogState extends State<_HighlightEditDialog> {
  late final TextEditingController _name;
  late final TextEditingController _pattern;
  late Color _color;
  late bool _isRegex;
  late bool _caseSensitive;
  late bool _wholeLine;
  late bool _bold;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _pattern = TextEditingController(text: e?.pattern ?? '');
    _color = e?.color ?? _palette.first;
    _isRegex = e?.isRegex ?? false;
    _caseSensitive = e?.caseSensitive ?? false;
    _wholeLine = e?.wholeLine ?? true;
    _bold = e?.bold ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _pattern.dispose();
    super.dispose();
  }

  void _save() {
    final pattern = _pattern.text.trim();
    if (pattern.isEmpty) return;
    Navigator.of(context).pop(
      (widget.existing ??
              HighlightRule(
                id: DateTime.now().microsecondsSinceEpoch.toString(),
                name: '',
                pattern: '',
                color: _color,
              ))
          .copyWith(
            name: _name.text.trim(),
            pattern: pattern,
            color: _color,
            isRegex: _isRegex,
            caseSensitive: _caseSensitive,
            wholeLine: _wholeLine,
            bold: _bold,
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? tr('新建高亮规则') : tr('编辑高亮规则')),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _field(_name, tr('名称(可空)'), tr('如 错误')),
            const SizedBox(height: 10),
            _field(_pattern, _isRegex ? tr('正则表达式') : tr('匹配文本'), tr('如 ERROR')),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              children: [
                for (final c in _palette)
                  GestureDetector(
                    onTap: () => setState(() => _color = c),
                    child: Container(
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(
                        color: c,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: _color == c
                              ? AppTheme.headingColor
                              : Colors.transparent,
                          width: 2,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            _toggle(tr('正则匹配'), _isRegex, (v) => setState(() => _isRegex = v)),
            _toggle(tr('区分大小写'), _caseSensitive,
                (v) => setState(() => _caseSensitive = v)),
            _toggle(tr('整行上色(关=只给命中片段上色)'), _wholeLine,
                (v) => setState(() => _wholeLine = v)),
            _toggle(tr('加粗'), _bold, (v) => setState(() => _bold = v)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('取消')),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppTheme.brandColor),
          onPressed: _save,
          child: Text(tr('保存')),
        ),
      ],
    );
  }

  Widget _toggle(String label, bool value, ValueChanged<bool> onChanged) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(fontSize: 12.5, color: AppTheme.headingColor),
          ),
        ),
        Switch(
          value: value,
          activeThumbColor: AppTheme.brandColor,
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _field(TextEditingController c, String label, String hint) {
    return TextField(
      controller: c,
      style: TextStyle(fontSize: 12.5, color: AppTheme.headingColor),
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(
        isDense: true,
        labelText: label,
        hintText: hint,
        hintStyle: TextStyle(
          fontSize: 11,
          color: AppTheme.subtleTextColor.withValues(alpha: 0.6),
        ),
        border: const OutlineInputBorder(),
      ),
    );
  }
}
