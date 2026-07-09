import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:termora/app/theme/app_theme.dart';
import 'package:termora/features/database/domain/data_export.dart';
import 'package:termora/features/database/domain/db_models.dart';

/// 数据导出向导 — 选格式后落盘或复制到剪贴板
Future<void> showExportDialog(
  BuildContext context, {
  required DbQueryOutput output,
  required String tableName,
}) {
  return showDialog(
    context: context,
    builder: (context) => _ExportDialog(output: output, tableName: tableName),
  );
}

class _ExportDialog extends StatefulWidget {
  const _ExportDialog({required this.output, required this.tableName});

  final DbQueryOutput output;
  final String tableName;

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  ExportFormat _format = ExportFormat.csv;
  bool _busy = false;
  String? _message;

  Future<void> _saveToFile() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final content = DataExport.export(
        widget.output,
        _format,
        tableName: widget.tableName,
      );
      final path = await FilePicker.saveFile(
        dialogTitle: '导出为 ${_format.label}',
        fileName: '${widget.tableName}.${_format.extension}',
      );
      if (path == null) {
        setState(() => _busy = false); // 用户取消
        return;
      }
      final finalPath = path.contains('.')
          ? path
          : '$path.${_format.extension}';
      await File(finalPath).writeAsString(content);
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已导出 ${widget.output.rows.length} 行到 $finalPath'),
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = '导出失败: $e';
      });
    }
  }

  Future<void> _copyToClipboard() async {
    final content = DataExport.export(
      widget.output,
      _format,
      tableName: widget.tableName,
    );
    await Clipboard.setData(ClipboardData(text: content));
    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已复制 ${_format.label} 到剪贴板'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  ({IconData icon, String subtitle}) _getFormatMeta(ExportFormat format) {
    return switch (format) {
      ExportFormat.csv => (
          icon: LucideIcons.fileSpreadsheet,
          subtitle: '逗号分隔数据 (.csv)',
        ),
      ExportFormat.json => (
          icon: LucideIcons.fileCode,
          subtitle: '结构化对象 (.json)',
        ),
      ExportFormat.sqlInsert => (
          icon: LucideIcons.database,
          subtitle: 'INSERT 语句 (.sql)',
        ),
      ExportFormat.markdown => (
          icon: LucideIcons.table2,
          subtitle: 'GitHub 表格 (.md)',
        ),
    };
  }

  Widget _buildFormatCard(ExportFormat format) {
    final selected = _format == format;
    final meta = _getFormatMeta(format);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => setState(() => _format = format),
        borderRadius: BorderRadius.circular(10),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
          decoration: BoxDecoration(
            color: selected
                ? AppTheme.brandColor.withValues(alpha: 0.12)
                : AppTheme.mutedSurfaceColor,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? AppTheme.brandColor : AppTheme.borderColor,
              width: selected ? 1.5 : 0.8,
            ),
          ),
          child: Row(
            children: [
              Icon(
                meta.icon,
                size: 19,
                color: selected ? AppTheme.brandColor : AppTheme.subtleTextColor,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      format.label,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                        color: selected
                            ? AppTheme.headingColor
                            : AppTheme.bodyColor,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      meta.subtitle,
                      style: TextStyle(
                        fontSize: 11,
                        color: selected
                            ? AppTheme.bodyColor
                            : AppTheme.subtleTextColor,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Icon(
                selected ? LucideIcons.checkCircle2 : LucideIcons.circle,
                size: 16,
                color: selected
                    ? AppTheme.brandColor
                    : AppTheme.subtleTextColor.withValues(alpha: 0.35),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 470),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: AppTheme.brandColor.withValues(alpha: 0.13),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      LucideIcons.download,
                      size: 18,
                      color: AppTheme.brandColor,
                    ),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '导出数据',
                          style: TextStyle(
                            fontSize: 15.5,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.headingColor,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '选择适合的格式导出表「${widget.tableName}」内容',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: AppTheme.subtleTextColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 9, vertical: 3.5),
                    decoration: BoxDecoration(
                      color: AppTheme.mutedSurfaceColor,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppTheme.borderColor),
                    ),
                    child: Text(
                      '共 ${widget.output.rows.length} 行',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                        color: AppTheme.bodyColor,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(child: _buildFormatCard(ExportFormat.csv)),
                  const SizedBox(width: 10),
                  Expanded(child: _buildFormatCard(ExportFormat.json)),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(child: _buildFormatCard(ExportFormat.sqlInsert)),
                  const SizedBox(width: 10),
                  Expanded(child: _buildFormatCard(ExportFormat.markdown)),
                ],
              ),
              if (_message != null) ...[
                const SizedBox(height: 14),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppTheme.errorColor.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(LucideIcons.alertCircle,
                          size: 15, color: AppTheme.errorColor),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _message!,
                          style: TextStyle(
                              fontSize: 12, color: AppTheme.errorColor),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 22),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _copyToClipboard,
                    icon: const Icon(LucideIcons.clipboardCopy, size: 14),
                    label: const Text('复制到剪贴板'),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: _busy ? null : () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _busy ? null : _saveToFile,
                    icon: _busy
                        ? const SizedBox(
                            width: 13,
                            height: 13,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(LucideIcons.save, size: 14),
                    label: const Text('保存到文件'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
