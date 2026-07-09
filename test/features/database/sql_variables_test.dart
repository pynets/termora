import 'package:flutter_test/flutter_test.dart';
import 'package:termora/features/database/domain/sql_variables.dart';

void main() {
  group('SqlVariables', () {
    test('extract 按出现顺序去重提取变量名', () {
      expect(
        SqlVariables.extract(
          'SELECT * FROM \${table} WHERE age > \${min_age} '
          'AND name != \${table}',
        ),
        ['table', 'min_age'],
      );
    });

    test('extract 忽略非法名字与裸 \$', () {
      expect(SqlVariables.extract(r'SELECT ${1bad}, ${}, $var, ${ok_1}'), [
        'ok_1',
      ]);
    });

    test('substitute 替换已定义变量,未定义原样保留', () {
      expect(
        SqlVariables.substitute(
          'SELECT * FROM \${table} LIMIT \${n}',
          {'table': 'demo_users'},
        ),
        'SELECT * FROM demo_users LIMIT \${n}',
      );
    });

    test('substitute 值中含美元符不会二次展开', () {
      expect(
        SqlVariables.substitute('SELECT \${a}', {'a': r'${b}', 'b': 'x'}),
        r'SELECT ${b}',
      );
    });
  });

  group('位置参数 \$N', () {
    test('提取排序去重', () {
      expect(
        SqlVariables.extractPositional('WHERE a=\$2 AND b=\$1 AND c=\$2'),
        ['\$1', '\$2'],
      );
    });

    test('跳过字符串/注释/dollar-quote 中的 \$1', () {
      const sql =
          "SELECT '\$1', \$\$body \$2\$\$ -- \$3\n /* \$4 */ FROM t WHERE id=\$5";
      expect(SqlVariables.extractPositional(sql), ['\$5']);
    });

    test('字面量内联:数字原样,文本加引号并转义', () {
      final result = SqlVariables.substitutePositional(
        'WHERE id=\$1 AND name=\$2',
        {'\$1': '42', '\$2': "O'Brien"},
      );
      expect(result, "WHERE id=42 AND name='O''Brien'");
    });

    test('toLiteral: 布尔/NULL/数字原样,文本加引号', () {
      expect(SqlVariables.toLiteral('true'), 'true');
      expect(SqlVariables.toLiteral('NULL'), 'NULL');
      expect(SqlVariables.toLiteral('3.14'), '3.14');
      expect(SqlVariables.toLiteral('hello'), "'hello'");
    });

    test('不替换字符串内的 \$1', () {
      final result = SqlVariables.substitutePositional(
        "SELECT '\$1' AS lit, \$1 AS val",
        {'\$1': '9'},
      );
      expect(result, "SELECT '\$1' AS lit, 9 AS val");
    });
  });
}
