import 'package:flutter_test/flutter_test.dart';
import 'package:termora/features/database/domain/data_export.dart';
import 'package:termora/features/database/domain/db_models.dart';

void main() {
  const output = DbQueryOutput(
    columns: ['id', 'name', 'note'],
    rows: [
      [1, 'a', 'hi'],
      [2, "O'B", null],
    ],
  );

  test('CSV', () {
    expect(
      DataExport.export(output, ExportFormat.csv),
      'id,name,note\n1,a,hi\n2,O\'B,\n',
    );
  });

  test('JSON: null 保留,数字不加引号', () {
    final json = DataExport.export(output, ExportFormat.json);
    expect(json, contains('"id": 1'));
    expect(json, contains('"note": null'));
    expect(json, contains('"name": "O\'B"'));
  });

  test('SQL INSERT: 标识符引用 + 字符串转义 + NULL', () {
    final sql = DataExport.export(
      output,
      ExportFormat.sqlInsert,
      tableName: 'users',
    );
    expect(
      sql,
      contains('INSERT INTO "users" ("id", "name", "note") VALUES (1, \'a\', \'hi\');'),
    );
    expect(sql, contains("VALUES (2, 'O''B', NULL);"));
  });

  test('Markdown: 表头分隔行 + 管道转义', () {
    const piped = DbQueryOutput(
      columns: ['a'],
      rows: [
        ['x|y'],
      ],
    );
    final md = DataExport.export(piped, ExportFormat.markdown);
    expect(md, contains('| a |'));
    expect(md, contains('| --- |'));
    expect(md, contains('| x\\|y |'));
  });
}
