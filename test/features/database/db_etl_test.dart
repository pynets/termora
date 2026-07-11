// DbEtl 纯逻辑测试:值转换 / 批处理列映射 / DDL 列裁剪与类型强转
import 'package:flutter_test/flutter_test.dart';
import 'package:termora/features/database/domain/db_etl.dart';
import 'package:termora/features/database/domain/db_migration.dart';
import 'package:termora/features/database/domain/db_models.dart';

void main() {
  group('DbEtlColumnRule.apply', () {
    Object? apply(DbEtlTransform t, Object? v, [String param = '']) =>
        DbEtlColumnRule(column: 'c', transform: t, param: param).apply(v);

    test('文本转换只作用于字符串,其它类型透传', () {
      expect(apply(DbEtlTransform.trim, '  a  '), 'a');
      expect(apply(DbEtlTransform.upper, 'ab'), 'AB');
      expect(apply(DbEtlTransform.lower, 'AB'), 'ab');
      expect(apply(DbEtlTransform.trim, 42), 42);
      expect(apply(DbEtlTransform.upper, null), isNull);
    });

    test('mask:保留头尾,中间打码;NULL 透传', () {
      expect(apply(DbEtlTransform.mask, '13812345678', '3,4'), '138****5678');
      expect(apply(DbEtlTransform.mask, 'abcdef'), 'a****f'); // 默认 1,1
      expect(apply(DbEtlTransform.mask, 'ab'), '**'); // 不够长全打码
      expect(apply(DbEtlTransform.mask, null), isNull);
      expect(apply(DbEtlTransform.mask, 13812345678, '3,4'), '138****5678');
    });

    test('hash:sha256 十六进制,确定性;NULL 透传', () {
      final a = apply(DbEtlTransform.hash, 'secret');
      expect(a, hasLength(64));
      expect(a, apply(DbEtlTransform.hash, 'secret'));
      expect(a, isNot(apply(DbEtlTransform.hash, 'secret2')));
      expect(apply(DbEtlTransform.hash, null), isNull);
    });

    test('fixed / nullify', () {
      expect(apply(DbEtlTransform.fixed, 'x', 'REDACTED'), 'REDACTED');
      expect(apply(DbEtlTransform.fixed, null, 'R'), 'R');
      expect(apply(DbEtlTransform.nullify, 'x'), isNull);
    });
  });

  group('DbEtlTableRule', () {
    const rule = DbEtlTableRule(
      table: 'users',
      targetTable: 'members',
      columns: {
        'secret': DbEtlColumnRule(column: 'secret', include: false),
        'name': DbEtlColumnRule(column: 'name', rename: 'full_name'),
        'phone': DbEtlColumnRule(
          column: 'phone',
          transform: DbEtlTransform.mask,
          param: '3,4',
        ),
      },
    );

    test('applyToBatch:裁剪列 + 改名 + 值转换', () {
      final (columns, rows) = rule.applyToBatch(
        ['id', 'name', 'phone', 'secret'],
        [
          [1, 'alice', '13812345678', 'pwd'],
          [2, 'bob', null, 'pwd2'],
        ],
      );
      expect(columns, ['id', 'full_name', 'phone']);
      expect(rows, [
        [1, 'alice', '138****5678'],
        [2, 'bob', null],
      ]);
    });

    test('applyToColumns:排除列消失,强制文本的列类型改 text', () {
      const source = [
        DbMigrationColumn(
          name: 'id',
          sourceType: 'bigint',
          generic: DbGenericType.bigint,
          nullable: false,
          isPrimaryKey: true,
        ),
        DbMigrationColumn(
          name: 'phone',
          sourceType: 'bigint',
          generic: DbGenericType.bigint,
          nullable: true,
          isPrimaryKey: false,
        ),
        DbMigrationColumn(
          name: 'secret',
          sourceType: 'text',
          generic: DbGenericType.text,
          nullable: true,
          isPrimaryKey: false,
        ),
      ];
      final out = rule.applyToColumns(DbEngine.postgres, source);
      expect(out.map((c) => c.name), ['id', 'phone']);
      // mask 输出文本 → bigint 列变 text
      expect(out[1].generic, DbGenericType.text);
      expect(out[1].sourceType, 'text');
      // ch 源引擎时文本类型用 String
      final chOut = const DbEtlTableRule(
        table: 't',
        columns: {
          'v': DbEtlColumnRule(column: 'v', transform: DbEtlTransform.hash),
        },
      ).applyToColumns(DbEngine.clickhouse, [
        const DbMigrationColumn(
          name: 'v',
          sourceType: 'Int64',
          generic: DbGenericType.bigint,
          nullable: false,
          isPrimaryKey: false,
        ),
      ]);
      expect(chOut.single.sourceType, 'String');
    });

    test('isPassthrough:空规则/等价规则不算 ETL', () {
      expect(const DbEtlTableRule(table: 't').isPassthrough, isTrue);
      expect(
        const DbEtlTableRule(
          table: 't',
          columns: {'a': DbEtlColumnRule(column: 'a')},
        ).isPassthrough,
        isTrue,
      );
      expect(rule.isPassthrough, isFalse);
      expect(
        const DbEtlTableRule(
          table: 't',
          rowFilters: [
            DbColumnFilter(column: 'id', op: DbFilterOp.less, value: '10'),
          ],
        ).isPassthrough,
        isFalse,
      );
    });

    test('nullify 让目标列可空', () {
      final out = const DbEtlTableRule(
        table: 't',
        columns: {
          'v': DbEtlColumnRule(
            column: 'v',
            transform: DbEtlTransform.nullify,
          ),
        },
      ).applyToColumns(DbEngine.postgres, [
        const DbMigrationColumn(
          name: 'v',
          sourceType: 'text',
          generic: DbGenericType.text,
          nullable: false,
          isPrimaryKey: false,
        ),
      ]);
      expect(out.single.nullable, isTrue);
    });
  });
}
