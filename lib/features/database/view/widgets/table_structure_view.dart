import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:termora/app/theme/app_theme.dart';
import 'package:termora/features/database/domain/db_models.dart';
import 'package:termora/core/l10n/app_l10n.dart';

/// 表结构面板 — 列定义 + 索引(DBeaver「属性」页的精简版)
class TableStructureView extends StatelessWidget {
  const TableStructureView({super.key, required this.structure});

  final DbTableStructure structure;

  static const _mono = TextStyle(
    fontFamily: 'Menlo',
    fontFamilyFallback: ['Consolas', 'monospace'],
    fontSize: 10.5,
    height: 1.15,
  );

  @override
  Widget build(BuildContext context) {
    final fks = [
      for (final c in structure.constraints)
        if (c.type == DbConstraintType.foreignKey) c,
    ];
    final checks = [
      for (final c in structure.constraints)
        if (c.type == DbConstraintType.check) c,
    ];
    final pkCols = [
      for (final c in structure.columns)
        if (c.isPrimaryKey) c.name,
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 20),
      children: [
        _overviewCard(fks.length, checks.length),
        const SizedBox(height: 18),
        _sectionTitle(tr2('列 ({0})', [structure.columns.length])),
        const SizedBox(height: 8),
        _columnsTable(),
        if (pkCols.isNotEmpty) ...[
          const SizedBox(height: 20),
          _sectionTitle(tr2('主键 ({0})', [pkCols.length])),
          const SizedBox(height: 8),
          _constraintTile(
            LucideIcons.key,
            AppTheme.warningColor,
            tr('PRIMARY KEY'),
            'PRIMARY KEY (${pkCols.map((c) => '"$c"').join(', ')})',
          ),
        ],
        const SizedBox(height: 20),
        _sectionTitle(tr2('索引 ({0})', [structure.indexes.length])),
        const SizedBox(height: 8),
        if (structure.indexes.isEmpty)
          Text(
            tr('(无索引)'),
            style: TextStyle(fontSize: 12, color: AppTheme.subtleTextColor),
          )
        else
          for (final index in structure.indexes) _indexTile(index),
        if (fks.isNotEmpty) ...[
          const SizedBox(height: 20),
          _sectionTitle(tr2('外键 ({0})', [fks.length])),
          const SizedBox(height: 8),
          for (final fk in fks)
            _constraintTile(
              LucideIcons.link2,
              AppTheme.brandColor,
              fk.name,
              fk.definition,
            ),
        ],
        if (checks.isNotEmpty) ...[
          const SizedBox(height: 20),
          _sectionTitle(tr2('检查约束 ({0})', [checks.length])),
          const SizedBox(height: 8),
          for (final ck in checks)
            _constraintTile(
              LucideIcons.circleCheck,
              AppTheme.successColor,
              ck.name,
              ck.definition,
            ),
        ],
      ],
    );
  }

  /// 表概览卡片:行数估计 / 大小 / 列数 / 索引 / 约束 / 注释
  Widget _overviewCard(int fkCount, int checkCount) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.mutedSurfaceColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 22,
            runSpacing: 8,
            children: [
              _metric(
                LucideIcons.hash,
                '约 ${structure.approxRows < 0 ? '未统计' : structure.approxRows} 行',
              ),
              _metric(LucideIcons.hardDrive, structure.prettySize),
              _metric(
                LucideIcons.columns3,
                tr2('{0} 列', [structure.columns.length]),
              ),
              _metric(
                LucideIcons.listOrdered,
                tr2('{0} 索引', [structure.indexes.length]),
              ),
              if (fkCount > 0)
                _metric(LucideIcons.link2, tr2('{0} 外键', [fkCount])),
              if (checkCount > 0)
                _metric(LucideIcons.circleCheck, tr2('{0} 检查', [checkCount])),
            ],
          ),
          if (structure.comment != null && structure.comment!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              structure.comment!,
              style: TextStyle(
                fontSize: 12,
                color: AppTheme.bodyColor,
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _metric(IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: AppTheme.brandColor),
        const SizedBox(width: 5),
        Text(
          text,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: AppTheme.headingColor,
          ),
        ),
      ],
    );
  }

  Widget _sectionTitle(String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12.5,
        fontWeight: FontWeight.w700,
        color: AppTheme.headingColor,
      ),
    );
  }

  Widget _columnsTable() {
    final headerStyle = _mono.copyWith(
      fontSize: 11,
      fontWeight: FontWeight.w700,
      color: AppTheme.subtleTextColor,
    );
    final cellStyle = _mono.copyWith(color: AppTheme.headingColor);
    final dimStyle = _mono.copyWith(color: AppTheme.subtleTextColor);
    final hasComments = structure.columns.any(
      (c) => c.comment != null && c.comment!.isNotEmpty,
    );

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppTheme.borderColor),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Table(
        columnWidths: <int, TableColumnWidth>{
          0: const FixedColumnWidth(32), // PK
          1: const FlexColumnWidth(1.4), // 名称
          2: const FlexColumnWidth(1.2), // 类型
          3: const FixedColumnWidth(66), // 可空
          4: const FlexColumnWidth(1.4), // 默认值
          if (hasComments) 5: const FlexColumnWidth(1.4), // 注释
        },
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        border: TableBorder(
          horizontalInside: BorderSide(
            color: AppTheme.borderColor.withValues(alpha: 0.5),
            width: 0.5,
          ),
        ),
        children: [
          TableRow(
            decoration: BoxDecoration(color: AppTheme.mutedSurfaceColor),
            children: [
              const SizedBox(height: 24),
              _cell(Text(tr('名称'), style: headerStyle)),
              _cell(Text(tr('类型'), style: headerStyle)),
              _cell(Text(tr('可空'), style: headerStyle)),
              _cell(Text(tr('默认值'), style: headerStyle)),
              if (hasComments) _cell(Text(tr('注释'), style: headerStyle)),
            ],
          ),
          for (final col in structure.columns)
            TableRow(
              children: [
                SizedBox(
                  height: 24,
                  child: col.isPrimaryKey
                      ? Icon(
                          LucideIcons.key,
                          size: 12,
                          color: AppTheme.warningColor,
                        )
                      : null,
                ),
                _cell(
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          col.name,
                          overflow: TextOverflow.ellipsis,
                          style: cellStyle.copyWith(
                            fontWeight: col.isPrimaryKey
                                ? FontWeight.w700
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                      if (col.isIdentity)
                        _flagTag(tr('自增'), AppTheme.brandColor),
                      if (col.isGenerated)
                        _flagTag(tr('生成'), AppTheme.successColor),
                    ],
                  ),
                ),
                _cell(
                  Text(
                    col.dataType,
                    overflow: TextOverflow.ellipsis,
                    style: cellStyle,
                  ),
                ),
                _cell(
                  Text(
                    col.nullable ? 'YES' : 'NO',
                    style: col.nullable
                        ? dimStyle
                        : cellStyle.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                _cell(
                  Text(
                    col.defaultValue ?? '',
                    overflow: TextOverflow.ellipsis,
                    style: dimStyle,
                  ),
                ),
                if (hasComments)
                  _cell(
                    Text(
                      col.comment ?? '',
                      overflow: TextOverflow.ellipsis,
                      style: dimStyle,
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _cell(Widget child) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: child,
    );
  }

  /// 列属性小标签(自增/生成)
  Widget _flagTag(String text, Color color) {
    return Container(
      margin: const EdgeInsets.only(left: 4),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }

  /// 约束/主键条目(图标 + 名称 + 可选中定义)
  Widget _constraintTile(
    IconData icon,
    Color color,
    String name,
    String definition,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: AppTheme.mutedSurfaceColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.borderColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 12, color: color),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    name,
                    overflow: TextOverflow.ellipsis,
                    style: _mono.copyWith(
                      fontWeight: FontWeight.w600,
                      color: AppTheme.headingColor,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            SelectableText(
              definition,
              style: _mono.copyWith(
                fontSize: 11.5,
                color: AppTheme.subtleTextColor,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _indexTile(DbIndexInfo index) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: AppTheme.mutedSurfaceColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.borderColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  LucideIcons.listOrdered,
                  size: 12,
                  color: AppTheme.brandColor,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    index.name,
                    overflow: TextOverflow.ellipsis,
                    style: _mono.copyWith(
                      fontWeight: FontWeight.w600,
                      color: AppTheme.headingColor,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            SelectableText(
              index.definition,
              style: _mono.copyWith(
                fontSize: 11.5,
                color: AppTheme.subtleTextColor,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
