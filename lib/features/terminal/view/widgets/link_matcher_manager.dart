import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:termora/app/theme/app_theme.dart';
import 'package:termora/features/terminal/data/link_matcher_store.dart';
import 'package:termora/core/l10n/app_l10n.dart';

/// 打开自定义链接规则管理弹窗。
Future<void> showLinkMatcherManager(BuildContext context) async {
  await LinkMatcherStore.ensureLoaded();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => const _LinkMatcherManagerDialog(),
  );
}

class _LinkMatcherManagerDialog extends StatelessWidget {
  const _LinkMatcherManagerDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Icon(LucideIcons.link300, size: 17, color: AppTheme.brandColor),
          const SizedBox(width: 8),
          Text(tr('自定义链接规则')),
        ],
      ),
      content: SizedBox(
        width: 500,
        height: 380,
        child: ValueListenableBuilder<List<LinkMatcher>>(
          valueListenable: LinkMatcherStore.matchers,
          builder: (context, list, _) {
            if (list.isEmpty) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      LucideIcons.link300,
                      size: 26,
                      color: AppTheme.subtleTextColor.withValues(alpha: 0.5),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      tr('还没有链接规则,点「新建」添加'),
                      style: TextStyle(
                        fontSize: 12.5,
                        color: AppTheme.subtleTextColor,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      r'如 JIRA-(\d+) → https://jira.example.com/browse/JIRA-$1',
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

  Widget _row(BuildContext context, LinkMatcher matcher) {
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(
        LucideIcons.link300,
        size: 15,
        color: matcher.regex == null
            ? AppTheme.errorColor
            : AppTheme.subtleTextColor,
      ),
      title: Text(
        matcher.name.isEmpty ? matcher.pattern : matcher.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12.5, color: AppTheme.headingColor),
      ),
      subtitle: Text(
        '${matcher.pattern} → ${matcher.urlTemplate}'
        '${matcher.regex == null ? tr(' · 正则无效') : ''}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 10.5,
          color: matcher.regex == null
              ? AppTheme.errorColor
              : AppTheme.subtleTextColor,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch(
            value: matcher.enabled,
            activeThumbColor: AppTheme.brandColor,
            onChanged: (v) =>
                LinkMatcherStore.upsert(matcher.copyWith(enabled: v)),
          ),
          IconButton(
            tooltip: tr('编辑'),
            icon: Icon(LucideIcons.penLine300, size: 15),
            onPressed: () => _edit(context, matcher),
          ),
          IconButton(
            tooltip: tr('删除'),
            icon: Icon(
              LucideIcons.trash300,
              size: 15,
              color: AppTheme.errorColor,
            ),
            onPressed: () => LinkMatcherStore.remove(matcher.id),
          ),
        ],
      ),
    );
  }

  Future<void> _edit(BuildContext context, LinkMatcher? existing) async {
    final matcher = await showDialog<LinkMatcher>(
      context: context,
      builder: (context) => _LinkMatcherEditDialog(existing: existing),
    );
    if (matcher != null) await LinkMatcherStore.upsert(matcher);
  }
}

class _LinkMatcherEditDialog extends StatefulWidget {
  const _LinkMatcherEditDialog({this.existing});

  final LinkMatcher? existing;

  @override
  State<_LinkMatcherEditDialog> createState() => _LinkMatcherEditDialogState();
}

class _LinkMatcherEditDialogState extends State<_LinkMatcherEditDialog> {
  late final TextEditingController _name;
  late final TextEditingController _pattern;
  late final TextEditingController _template;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _pattern = TextEditingController(text: e?.pattern ?? '');
    _template = TextEditingController(text: e?.urlTemplate ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _pattern.dispose();
    _template.dispose();
    super.dispose();
  }

  bool get _patternValid {
    if (_pattern.text.trim().isEmpty) return false;
    try {
      RegExp(_pattern.text.trim());
      return true;
    } catch (_) {
      return false;
    }
  }

  void _save() {
    if (!_patternValid || _template.text.trim().isEmpty) return;
    Navigator.of(context).pop(
      (widget.existing ??
              LinkMatcher(
                id: DateTime.now().microsecondsSinceEpoch.toString(),
                name: '',
                pattern: '',
                urlTemplate: '',
              ))
          .copyWith(
            name: _name.text.trim(),
            pattern: _pattern.text.trim(),
            urlTemplate: _template.text.trim(),
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? tr('新建链接规则') : tr('编辑链接规则')),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _field(_name, tr('名称(可空)'), tr('如 JIRA 工单')),
            const SizedBox(height: 10),
            _field(
              _pattern,
              tr('正则表达式'),
              r'如 JIRA-(\d+)',
              error: _pattern.text.trim().isNotEmpty && !_patternValid,
            ),
            const SizedBox(height: 10),
            _field(_template, tr('URL 模板'), r'如 https://jira.example.com/browse/JIRA-$1'),
            const SizedBox(height: 8),
            Text(
              r'模板里 $0 为整个匹配,$1..$9 为捕获组。'
              '\n输出中命中的文本会变成可点击链接(悬停有下划线和预览)。',
              style: TextStyle(
                fontSize: 11,
                height: 1.4,
                color: AppTheme.subtleTextColor,
              ),
            ),
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

  Widget _field(
    TextEditingController c,
    String label,
    String hint, {
    bool error = false,
  }) {
    return TextField(
      controller: c,
      style: TextStyle(
        fontSize: 12.5,
        color: error ? AppTheme.errorColor : AppTheme.headingColor,
      ),
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(
        isDense: true,
        labelText: label,
        hintText: hint,
        errorText: error ? tr('正则无效') : null,
        hintStyle: TextStyle(
          fontSize: 11,
          color: AppTheme.subtleTextColor.withValues(alpha: 0.6),
        ),
        border: const OutlineInputBorder(),
      ),
    );
  }
}
