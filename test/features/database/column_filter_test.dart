import 'package:flutter_test/flutter_test.dart';
import 'package:termora/features/database/domain/db_models.dart';

void main() {
  group('DbColumnFilter.toSqlFragment', () {
    test('等于:文本参数绑定', () {
      final (sql, params) = const DbColumnFilter(
        column: 'name',
        op: DbFilterOp.equals,
        value: 'bob',
      ).toSqlFragment('p');
      expect(sql, '"name"::text = @p');
      expect(params, {'p': 'bob'});
    });

    test('LIKE:自动加通配符', () {
      final (sql, params) = const DbColumnFilter(
        column: 'name',
        op: DbFilterOp.like,
        value: 'ob',
      ).toSqlFragment('p');
      expect(sql, '"name"::text ILIKE @p');
      expect(params, {'p': '%ob%'});
    });

    test('IS NULL:无参数', () {
      final (sql, params) = const DbColumnFilter(
        column: 'note',
        op: DbFilterOp.isNull,
      ).toSqlFragment('p');
      expect(sql, '"note" IS NULL');
      expect(params, isEmpty);
    });

    test('IN:逗号拆分为多个占位符', () {
      final (sql, params) = const DbColumnFilter(
        column: 'id',
        op: DbFilterOp.inList,
        value: '1, 2 ,3',
      ).toSqlFragment('p');
      expect(sql, '"id"::text IN (@p0, @p1, @p2)');
      expect(params, {'p0': '1', 'p1': '2', 'p2': '3'});
    });

    test('区间:大于等于', () {
      final (sql, params) = const DbColumnFilter(
        column: 'age',
        op: DbFilterOp.greaterEqual,
        value: '18',
      ).toSqlFragment('p');
      expect(sql, '"age" >= @p');
      expect(params, {'p': '18'});
    });

    test('列名含引号:转义', () {
      final (sql, _) = const DbColumnFilter(
        column: 'we"ird',
        op: DbFilterOp.isNotNull,
      ).toSqlFragment('p');
      expect(sql, '"we""ird" IS NOT NULL');
    });
  });

  group('buildWhere', () {
    test('多列 AND 合并,参数前缀隔离', () {
      final (where, params) = buildWhere(const [
        DbColumnFilter(column: 'a', op: DbFilterOp.equals, value: '1'),
        DbColumnFilter(column: 'b', op: DbFilterOp.like, value: 'x'),
      ]);
      expect(where, '("a"::text = @cf0) AND ("b"::text ILIKE @cf1)');
      expect(params, {'cf0': '1', 'cf1': '%x%'});
    });

    test('空列表返回空', () {
      final (where, params) = buildWhere(const []);
      expect(where, '');
      expect(params, isEmpty);
    });
  });
}
