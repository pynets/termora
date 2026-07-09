import 'dart:convert';

import 'package:termora/features/database/domain/db_models.dart';

/// 导出格式
enum ExportFormat {
  csv('CSV', 'csv'),
  json('JSON', 'json'),
  sqlInsert('SQL INSERT', 'sql'),
  markdown('Markdown 表格', 'md');

  const ExportFormat(this.label, this.extension);

  final String label;
  final String extension;
}

/// 结果集导出为各种文本格式(纯逻辑,便于测试)
class DataExport {
  DataExport._();

  static String export(
    DbQueryOutput output,
    ExportFormat format, {
    String tableName = 'exported',
  }) {
    return switch (format) {
      ExportFormat.csv => output.toCsv(),
      ExportFormat.json => _toJson(output),
      ExportFormat.sqlInsert => _toSqlInsert(output, tableName),
      ExportFormat.markdown => _toMarkdown(output),
    };
  }

  static String _cellString(Object? value) {
    if (value == null) return '';
    if (value is DateTime) return value.toIso8601String();
    if (value is List<int>) return '<${value.length} bytes>';
    return value.toString();
  }

  /// JSON:行数组,每行是 列名→值 的对象
  static String _toJson(DbQueryOutput output) {
    final list = [
      for (final row in output.rows)
        {
          for (var c = 0; c < output.columns.length; c++)
            output.columns[c]: _jsonValue(row[c]),
        },
    ];
    return const JsonEncoder.withIndent('  ').convert(list);
  }

  static Object? _jsonValue(Object? value) {
    if (value == null) return null;
    if (value is num || value is bool || value is String) return value;
    if (value is DateTime) return value.toIso8601String();
    if (value is List<int>) return '<${value.length} bytes>';
    return value.toString();
  }

  /// SQL INSERT 语句(每行一条)
  static String _toSqlInsert(DbQueryOutput output, String tableName) {
    final cols = output.columns.map(_quoteIdent).join(', ');
    final buffer = StringBuffer();
    for (final row in output.rows) {
      final values = [for (final v in row) _sqlLiteral(v)].join(', ');
      buffer.writeln(
        'INSERT INTO ${_quoteIdent(tableName)} ($cols) VALUES ($values);',
      );
    }
    return buffer.toString();
  }

  static String _sqlLiteral(Object? value) {
    if (value == null) return 'NULL';
    if (value is num) return '$value';
    if (value is bool) return value ? 'TRUE' : 'FALSE';
    final text = _cellString(value);
    return "'${text.replaceAll("'", "''")}'";
  }

  static String _quoteIdent(String ident) =>
      '"${ident.replaceAll('"', '""')}"';

  /// Markdown 表格(管道符转义,换行转空格)
  static String _toMarkdown(DbQueryOutput output) {
    String cell(Object? v) =>
        _cellString(v).replaceAll('|', '\\|').replaceAll('\n', ' ');

    final buffer = StringBuffer()
      ..writeln('| ${output.columns.map(cell).join(' | ')} |')
      ..writeln('| ${output.columns.map((_) => '---').join(' | ')} |');
    for (final row in output.rows) {
      buffer.writeln('| ${row.map(cell).join(' | ')} |');
    }
    return buffer.toString();
  }
}
