import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/atom-one-light.dart';

import 'package:termora/app/theme/app_theme.dart';

/// 常用 SQL 关键词(补全提示;editor 前缀匹配区分大小写,故大小写各一份)
const List<String> _sqlKeywords = [
  'SELECT', 'FROM', 'WHERE', 'INSERT', 'INTO', 'VALUES', 'UPDATE', 'SET',
  'DELETE', 'JOIN', 'LEFT', 'RIGHT', 'INNER', 'OUTER', 'FULL', 'CROSS',
  'ON', 'AS', 'AND', 'OR', 'NOT', 'NULL', 'IS', 'IN', 'EXISTS', 'BETWEEN',
  'LIKE', 'ILIKE', 'LIMIT', 'OFFSET', 'ORDER', 'GROUP', 'BY', 'HAVING',
  'DISTINCT', 'UNION', 'ALL', 'CASE', 'WHEN', 'THEN', 'ELSE', 'END',
  'CREATE', 'TABLE', 'ALTER', 'DROP', 'INDEX', 'VIEW', 'PRIMARY', 'KEY',
  'FOREIGN', 'REFERENCES', 'DEFAULT', 'CONSTRAINT', 'UNIQUE', 'CHECK',
  'CASCADE', 'TRUNCATE', 'RETURNING', 'WITH', 'RECURSIVE', 'EXPLAIN',
  'ANALYZE', 'VACUUM', 'BEGIN', 'COMMIT', 'ROLLBACK', 'TRANSACTION',
  'GRANT', 'REVOKE', 'ASC', 'DESC', 'USING', 'INTERVAL', 'CAST',
];

/// 常用函数(小写,函数名习惯上小写书写)
const Map<String, String> _sqlFunctions = {
  'count': 'bigint',
  'sum': 'numeric',
  'avg': 'numeric',
  'min': 'any',
  'max': 'any',
  'coalesce': 'any',
  'nullif': 'any',
  'now': 'timestamptz',
  'current_date': 'date',
  'current_timestamp': 'timestamptz',
  'lower': 'text',
  'upper': 'text',
  'length': 'int',
  'substring': 'text',
  'trim': 'text',
  'concat': 'text',
  'replace': 'text',
  'array_agg': 'array',
  'string_agg': 'text',
  'jsonb_agg': 'jsonb',
  'to_char': 'text',
  'to_date': 'date',
  'generate_series': 'setof',
  'random': 'float8',
};

/// SQL 高亮编辑器(re_editor + langSql),明暗主题自动切换,
/// 内建自动补全:SQL 关键词/函数 + 元数据(schema/表/列)+ `${变量}`
class SqlEditor extends StatelessWidget {
  const SqlEditor({
    super.key,
    required this.controller,
    this.metadataPrompts = const [],
    this.variableNames = const [],
    this.onRun,
  });

  final CodeLineEditingController controller;

  /// 来自当前连接元数据的补全项(schema/表/列)
  final List<CodePrompt> metadataPrompts;

  /// 已定义的 SQL 变量名(裸名,如 min_age),在 `${` 上下文中补全
  final List<String> variableNames;

  /// ⌘/Ctrl+Enter 执行回调(re_editor 默认吞掉该组合键作换行,此处已改绑)
  final VoidCallback? onRun;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final defaultBuilder = DefaultCodeAutocompletePromptsBuilder(
      language: langSql,
      keywordPrompts: [
        for (final kw in _sqlKeywords) ...[
          CodeKeywordPrompt(word: kw),
          CodeKeywordPrompt(word: kw.toLowerCase()),
        ],
      ],
      directPrompts: [
        for (final entry in _sqlFunctions.entries)
          CodeFieldPrompt(word: '${entry.key}(', type: entry.value),
        ...metadataPrompts,
      ],
    );

    return Container(
      height: 150,
      decoration: BoxDecoration(
        color: AppTheme.surfaceColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.borderColor),
      ),
      clipBehavior: Clip.antiAlias,
      // 外层捕获 ⌘/Ctrl+Enter 执行(编辑器已从换行绑定中移除该组合键)
      child: CallbackShortcuts(
        bindings: {
          if (onRun != null) ...{
            const SingleActivator(LogicalKeyboardKey.enter, meta: true): onRun!,
            const SingleActivator(LogicalKeyboardKey.enter, control: true):
                onRun!,
          },
        },
        child: CodeAutocomplete(
          viewBuilder: _buildPromptsView,
          promptsBuilder: _SqlPromptsBuilder(
            base: defaultBuilder,
            variableNames: variableNames,
          ),
          child: CodeEditor(
            controller: controller,
            wordWrap: false,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            // 从 newLine 绑定中剔除 ⌘/Ctrl+Enter,使其冒泡给外层执行
            shortcutsActivatorsBuilder: const _SqlShortcutsBuilder(),
            style: CodeEditorStyle(
              fontSize: 13,
              fontFamily: 'Menlo',
              fontHeight: 1.5,
              codeTheme: CodeHighlightTheme(
                languages: {'sql': CodeHighlightThemeMode(mode: langSql)},
                theme: isDark ? atomOneDarkTheme : atomOneLightTheme,
              ),
            ),
            scrollbarBuilder: (context, child, details) => child,
          ),
        ),
      ),
    );
  }

  /// 补全弹层 — ↑↓ 选择,Enter 上屏,点击外部关闭
  PreferredSizeWidget _buildPromptsView(
    BuildContext context,
    ValueNotifier<CodeAutocompleteEditingValue> notifier,
    ValueChanged<CodeAutocompleteResult> onSelected,
  ) {
    const width = 300.0;
    const itemHeight = 26.0;
    final height =
        (notifier.value.prompts.length.clamp(1, 8)) * itemHeight + 8;

    return PreferredSize(
      preferredSize: Size(width, height),
      child: Container(
        width: width,
        constraints: BoxConstraints(maxHeight: height),
        decoration: BoxDecoration(
          color: AppTheme.surfaceColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.borderColor),
          boxShadow: const [
            BoxShadow(
              color: Color(0x22000000),
              blurRadius: 12,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: ValueListenableBuilder<CodeAutocompleteEditingValue>(
          valueListenable: notifier,
          builder: (context, value, _) {
            return ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemExtent: itemHeight,
              shrinkWrap: true,
              itemCount: value.prompts.length,
              itemBuilder: (context, index) {
                final prompt = value.prompts[index];
                final selected = index == value.index;
                final type = switch (prompt) {
                  CodeFieldPrompt field => field.type,
                  CodeFunctionPrompt fn => fn.type,
                  _ => prompt.word.startsWith(r'${') ? 'variable' : 'keyword',
                };
                return InkWell(
                  onTap: () => onSelected(
                    value.copyWith(index: index).autocomplete,
                  ),
                  child: Container(
                    color: selected
                        ? AppTheme.softBrandColor
                        : Colors.transparent,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            prompt.word,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: 'Menlo',
                              fontFamilyFallback: const [
                                'Consolas',
                                'monospace',
                              ],
                              fontSize: 12,
                              color: selected
                                  ? AppTheme.brandColor
                                  : AppTheme.headingColor,
                              fontWeight: selected
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                        ),
                        Text(
                          type,
                          style: TextStyle(
                            fontSize: 10.5,
                            color: AppTheme.subtleTextColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

/// 自定义快捷键:从「换行」绑定中剔除 ⌘/Ctrl+Enter,使其能冒泡到外层执行 SQL,
/// 其余行为沿用默认。
class _SqlShortcutsBuilder extends CodeShortcutsActivatorsBuilder {
  const _SqlShortcutsBuilder();

  static const _default = DefaultCodeShortcutsActivatorsBuilder();

  @override
  List<ShortcutActivator>? build(CodeShortcutType type) {
    final activators = _default.build(type);
    if (type != CodeShortcutType.newLine || activators == null) {
      return activators;
    }
    return [
      for (final a in activators)
        if (!_isRunCombo(a)) a,
    ];
  }

  bool _isRunCombo(ShortcutActivator a) =>
      a is SingleActivator &&
      a.trigger == LogicalKeyboardKey.enter &&
      (a.meta || a.control) &&
      !a.shift;
}

/// 自定义补全:在 `${` 上下文中补全变量名(re_editor 默认词提取遇到 `$`/`{`
/// 会截断,无法匹配带 `${}` 的补全词,故这里单独处理),其余委托给默认 builder。
class _SqlPromptsBuilder implements CodeAutocompletePromptsBuilder {
  _SqlPromptsBuilder({required this.base, required this.variableNames});

  final CodeAutocompletePromptsBuilder base;
  final List<String> variableNames;

  /// 光标前正处于 `${xxx`(尚未闭合)中
  static final RegExp _varContext = RegExp(r'\$\{([A-Za-z0-9_]*)$');

  @override
  CodeAutocompleteEditingValue? build(
    BuildContext context,
    CodeLine codeLine,
    CodeLineSelection selection,
  ) {
    final offset = selection.extentOffset.clamp(0, codeLine.text.length);
    final before = codeLine.text.substring(0, offset);
    final match = _varContext.firstMatch(before);
    if (match != null && variableNames.isNotEmpty) {
      final input = match.group(0)!; // 形如 '${mi' 或 '${'
      final prompts = <CodePrompt>[
        for (final name in variableNames)
          if ('\${$name}'.startsWith(input)) CodeKeywordPrompt(word: '\${$name}'),
      ];
      if (prompts.isNotEmpty) {
        return CodeAutocompleteEditingValue(
          input: input,
          prompts: prompts,
          index: 0,
        );
      }
    }
    return base.build(context, codeLine, selection);
  }
}
