import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:termora/app/theme/app_theme.dart';
import 'package:termora/core/l10n/app_l10n.dart';
import 'package:termora/core/widgets/glass_menu.dart';
import 'package:termora/features/database/data/db_service.dart';
import 'package:termora/features/database/domain/db_etl.dart';
import 'package:termora/features/database/domain/db_models.dart';

/// 单表 ETL 规则编辑器。返回:
/// - 新规则(保存)/ null(取消)。等价于"什么都不做"的规则由调用方按
///   [DbEtlTableRule.isPassthrough] 丢弃。
Future<DbEtlTableRule?> showEtlRuleDialog(
  BuildContext context, {
  required DbConnectionConfig source,
  required String schema,
  required String table,
  DbEtlTableRule? existing,
}) {
  return showDialog<DbEtlTableRule>(
    context: context,
    useRootNavigator: false,
    barrierColor: Colors.black.withValues(alpha: 0.3),
    builder: (context) => _EtlRuleDialog(
      source: source,
      schema: schema,
      table: table,
      existing: existing,
    ),
  );
}

/// 可编辑的行过滤条目
class _FilterDraft {
  _FilterDraft({this.column = '', this.op = DbFilterOp.equals})
    : value = TextEditingController();

  String column;
  DbFilterOp op;
  final TextEditingController value;
}

class _EtlRuleDialog extends StatefulWidget {
  const _EtlRuleDialog({
    required this.source,
    required this.schema,
    required this.table,
    this.existing,
  });

  final DbConnectionConfig source;
  final String schema;
  final String table;
  final DbEtlTableRule? existing;

  @override
  State<_EtlRuleDialog> createState() => _EtlRuleDialogState();
}

class _EtlRuleDialogState extends State<_EtlRuleDialog> {
  bool _loading = true;
  String? _error;
  List<DbColumnInfo> _columns = const [];

  late final TextEditingController _targetTable = TextEditingController(
    text: widget.existing?.targetTable ?? '',
  );
  final List<_FilterDraft> _filters = [];

  // 列状态(以源列名为 key)
  final Map<String, bool> _include = {};
  final Map<String, DbEtlTransform> _transform = {};
  final Map<String, TextEditingController> _rename = {};
  final Map<String, TextEditingController> _param = {};

  @override
  void initState() {
    super.initState();
    for (final f in widget.existing?.rowFilters ?? const <DbColumnFilter>[]) {
      final draft = _FilterDraft(column: f.column, op: f.op);
      draft.value.text = f.value;
      _filters.add(draft);
    }
    _loadColumns();
  }

  @override
  void dispose() {
    _targetTable.dispose();
    for (final f in _filters) {
      f.value.dispose();
    }
    for (final c in _rename.values) {
      c.dispose();
    }
    for (final c in _param.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadColumns() async {
    try {
      final conn = await DbService.open(widget.source);
      try {
        final structure = await DbService.fetchTableStructure(
          conn,
          widget.schema,
          widget.table,
        );
        if (!mounted) return;
        setState(() {
          _loading = false;
          _columns = structure.columns;
          for (final c in structure.columns) {
            final rule = widget.existing?.columns[c.name];
            _include[c.name] = rule?.include ?? true;
            _transform[c.name] = rule?.transform ?? DbEtlTransform.none;
            _rename[c.name] = TextEditingController(text: rule?.rename ?? '');
            _param[c.name] = TextEditingController(text: rule?.param ?? '');
          }
        });
      } finally {
        await conn.close();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  DbEtlTableRule _buildRule() {
    final columnRules = <String, DbEtlColumnRule>{};
    for (final c in _columns) {
      final rule = DbEtlColumnRule(
        column: c.name,
        include: _include[c.name] ?? true,
        rename: _rename[c.name]?.text.trim(),
        transform: _transform[c.name] ?? DbEtlTransform.none,
        param: _param[c.name]?.text ?? '',
      );
      if (!rule.isPassthrough) columnRules[c.name] = rule;
    }
    return DbEtlTableRule(
      table: widget.table,
      targetTable: _targetTable.text.trim().isEmpty
          ? null
          : _targetTable.text.trim(),
      rowFilters: [
        for (final f in _filters)
          if (f.column.isNotEmpty &&
              (!f.op.needsValue || f.value.text.trim().isNotEmpty))
            DbColumnFilter(
              column: f.column,
              op: f.op,
              value: f.value.text.trim(),
            ),
      ],
      columns: columnRules,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(LucideIcons.wand, size: 17, color: AppTheme.brandColor),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      tr2('ETL 规则 — {0}', [widget.table]),
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.headingColor,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 30),
                  child: Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                )
              else if (_error != null)
                SelectableText(
                  tr2('读取表结构失败: {0}', [_error]),
                  style: TextStyle(fontSize: 12, color: AppTheme.errorColor),
                )
              else
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _sectionLabel(tr('目标表名(空 = 同名)')),
                        TextField(
                          controller: _targetTable,
                          style: TextStyle(
                            fontSize: 13,
                            color: AppTheme.headingColor,
                          ),
                          decoration: _inputDecoration(widget.table),
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            _sectionLabel(tr('行过滤(抽取时下推到源库)')),
                            const Spacer(),
                            TextButton.icon(
                              onPressed: () => setState(
                                () => _filters.add(_FilterDraft()),
                              ),
                              icon: const Icon(LucideIcons.plus, size: 13),
                              label: Text(
                                tr('添加条件'),
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                        for (var i = 0; i < _filters.length; i++)
                          _buildFilterRow(i),
                        const SizedBox(height: 10),
                        _sectionLabel(tr('列规则(勾选 = 迁移该列)')),
                        const SizedBox(height: 4),
                        _buildColumnHeader(),
                        for (final c in _columns) _buildColumnRow(c),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 14),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: () => Navigator.of(context).pop(
                      DbEtlTableRule(table: widget.table),
                    ),
                    icon: const Icon(LucideIcons.eraser, size: 13),
                    label: Text(tr('清除规则')),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(tr('取消')),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _loading || _error != null
                        ? null
                        : () => Navigator.of(context).pop(_buildRule()),
                    child: Text(tr('保存')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) => Text(
    text,
    style: TextStyle(
      fontSize: 11.5,
      fontWeight: FontWeight.w600,
      color: AppTheme.subtleTextColor,
    ),
  );

  InputDecoration _inputDecoration(String? hint) => InputDecoration(
    hintText: hint,
    hintStyle: TextStyle(
      fontSize: 12.5,
      color: AppTheme.subtleTextColor.withValues(alpha: 0.6),
    ),
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(7),
      borderSide: BorderSide(color: AppTheme.borderColor),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(7),
      borderSide: BorderSide(color: AppTheme.borderColor),
    ),
  );

  Widget _buildFilterRow(int index) {
    final draft = _filters[index];
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: GlassDropdownButton<String>(
              value: draft.column.isEmpty
                  ? (_columns.isEmpty ? '' : _columns.first.name)
                  : draft.column,
              items: [
                for (final c in _columns)
                  GlassDropdownMenuItem(
                    value: c.name,
                    child: Text(
                      c.name,
                      style: const TextStyle(fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (v) {
                if (v != null) setState(() => draft.column = v);
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: GlassDropdownButton<DbFilterOp>(
              value: draft.op,
              items: [
                for (final op in DbFilterOp.values)
                  GlassDropdownMenuItem(
                    value: op,
                    child: Text(
                      '${op.symbol} ${op.label}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
              ],
              onChanged: (v) {
                if (v != null) setState(() => draft.op = v);
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 4,
            child: draft.op.needsValue
                ? TextField(
                    controller: draft.value,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: AppTheme.headingColor,
                    ),
                    decoration: _inputDecoration(
                      draft.op == DbFilterOp.inList ? 'a, b, c' : null,
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          IconButton(
            tooltip: tr('删除条件'),
            visualDensity: VisualDensity.compact,
            icon: Icon(
              LucideIcons.x,
              size: 13,
              color: AppTheme.subtleTextColor,
            ),
            onPressed: () => setState(() {
              _filters.removeAt(index).value.dispose();
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildColumnHeader() {
    TextStyle style = TextStyle(
      fontSize: 10.5,
      fontWeight: FontWeight.w600,
      color: AppTheme.subtleTextColor,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          const SizedBox(width: 30),
          Expanded(flex: 4, child: Text(tr('源列'), style: style)),
          Expanded(flex: 3, child: Text(tr('重命名为'), style: style)),
          Expanded(flex: 3, child: Text(tr('转换'), style: style)),
          Expanded(flex: 2, child: Text(tr('参数'), style: style)),
        ],
      ),
    );
  }

  Widget _buildColumnRow(DbColumnInfo column) {
    final name = column.name;
    final included = _include[name] ?? true;
    final transform = _transform[name] ?? DbEtlTransform.none;
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Row(
        children: [
          SizedBox(
            width: 30,
            child: InkWell(
              onTap: () => setState(() => _include[name] = !included),
              child: Icon(
                included ? LucideIcons.squareCheck : LucideIcons.square,
                size: 15,
                color: included
                    ? AppTheme.brandColor
                    : AppTheme.subtleTextColor,
              ),
            ),
          ),
          Expanded(
            flex: 4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name + (column.isPrimaryKey ? ' 🔑' : ''),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    color: included
                        ? AppTheme.headingColor
                        : AppTheme.subtleTextColor,
                  ),
                ),
                Text(
                  column.dataType,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    color: AppTheme.subtleTextColor,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 3,
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextField(
                controller: _rename[name],
                enabled: included,
                style: TextStyle(
                  fontSize: 12,
                  color: AppTheme.headingColor,
                ),
                decoration: _inputDecoration(name),
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: GlassDropdownButton<DbEtlTransform>(
                value: transform,
                items: [
                  for (final t in DbEtlTransform.values)
                    GlassDropdownMenuItem(
                      value: t,
                      child: Text(
                        t.label,
                        style: const TextStyle(fontSize: 11.5),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (v) {
                  if (v != null && included) {
                    setState(() => _transform[name] = v);
                  }
                },
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: transform.needsParam
                ? TextField(
                    controller: _param[name],
                    enabled: included,
                    style: TextStyle(
                      fontSize: 12,
                      color: AppTheme.headingColor,
                    ),
                    decoration: _inputDecoration(
                      transform == DbEtlTransform.mask ? '1,1' : null,
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}
