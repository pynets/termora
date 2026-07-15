// DbDumpCodec 纯逻辑测试:manifest 校验 / 结构往返 / 值标记编码
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:termora/features/database/domain/db_dump.dart';
import 'package:termora/features/database/domain/db_models.dart';

/// 过一遍真正的 JSON 序列化 —— 归档落盘就是 JSONL,
/// 只在内存里比对会漏掉「编码结果不是 JSON 安全值」这类问题。
Map<String, dynamic> _roundTrip(Map<String, Object?> record) =>
    jsonDecode(jsonEncode(record)) as Map<String, dynamic>;

void main() {
  group('manifest', () {
    Map<String, Object?> sample() => DbDumpCodec.manifest(
      createdAtIso: '2026-07-15T10:00:00.000',
      sourceEngineName: 'postgres',
      sourceName: '生产库',
      sourceDatabase: 'app',
      schemas: const ['public', 'billing'],
      tableCount: 7,
    );

    test('自产 manifest 能通过校验,并读回 schema 与源引擎', () {
      final m = _roundTrip(sample());
      expect(() => DbDumpCodec.validateManifest(m), returnsNormally);
      expect(DbDumpCodec.manifestSchemas(m), ['public', 'billing']);
      expect(DbDumpCodec.manifestSourceEngine(m), 'postgres');
      expect(m['tableCount'], 7);
    });

    test('format 不匹配 → 拒绝(别人的 .json 拖进来)', () {
      expect(
        () => DbDumpCodec.validateManifest({'format': 'pg_dump', 'version': 1}),
        throwsFormatException,
      );
    });

    test('版本高于当前支持 → 拒绝而不是瞎解析', () {
      final m = _roundTrip(sample())..['version'] = DbDumpCodec.version + 1;
      expect(() => DbDumpCodec.validateManifest(m), throwsFormatException);
    });

    test('版本低于当前 → 放行(向后兼容旧归档)', () {
      final m = _roundTrip(sample())..['version'] = 0;
      expect(() => DbDumpCodec.validateManifest(m), returnsNormally);
    });
  });

  group('table 头结构往返', () {
    test('列的标记/约束/索引/注释都不丢', () {
      const structure = DbTableStructure(
        comment: '订单表',
        approxRows: 1234,
        totalBytes: 65536,
        columns: [
          DbColumnInfo(
            name: 'id',
            dataType: 'bigint',
            nullable: false,
            isPrimaryKey: true,
            isIdentity: true,
          ),
          DbColumnInfo(
            name: 'total',
            dataType: 'numeric(10,2)',
            nullable: false,
            defaultValue: '0',
            comment: '含税总价',
          ),
          DbColumnInfo(
            name: 'total_cny',
            dataType: 'numeric',
            nullable: true,
            isGenerated: true,
          ),
        ],
        indexes: [
          DbIndexInfo(name: 'idx_total', definition: 'CREATE INDEX idx_total'),
        ],
        constraints: [
          DbConstraintInfo(
            name: 'fk_user',
            type: DbConstraintType.foreignKey,
            definition: 'FOREIGN KEY (uid) REFERENCES users(id)',
            refSchema: 'public',
            refTable: 'users',
          ),
          DbConstraintInfo(
            name: 'ck_total',
            type: DbConstraintType.check,
            definition: 'CHECK (total >= 0)',
          ),
        ],
      );

      final json = _roundTrip(
        DbDumpCodec.tableHeader(
          index: 0,
          sourceEngineName: 'postgres',
          schema: 'public',
          table: 'orders',
          structure: structure,
        ),
      );
      expect(json['kind'], 'table');
      expect(json['schema'], 'public');
      expect(json['table'], 'orders');

      final back = DbDumpCodec.structureFromJson(json);
      expect(back.comment, '订单表');
      expect(back.approxRows, 1234);
      expect(back.totalBytes, 65536);

      expect(back.columns.map((c) => c.name), ['id', 'total', 'total_cny']);
      expect(back.columns[0].isPrimaryKey, isTrue);
      expect(back.columns[0].isIdentity, isTrue);
      expect(back.columns[0].nullable, isFalse);
      expect(back.columns[1].defaultValue, '0');
      expect(back.columns[1].comment, '含税总价');
      expect(back.columns[2].isGenerated, isTrue);

      expect(back.indexes.single.name, 'idx_total');
      expect(back.indexes.single.definition, 'CREATE INDEX idx_total');

      expect(back.constraints[0].type, DbConstraintType.foreignKey);
      expect(
        back.constraints[0].definition,
        'FOREIGN KEY (uid) REFERENCES users(id)',
      );
      expect(back.constraints[0].refSchema, 'public');
      expect(back.constraints[0].refTable, 'users');
      expect(back.constraints[1].type, DbConstraintType.check);
      expect(back.constraints[1].refTable, isNull);
    });

    test('缺字段的 table 头不炸,退化到默认值', () {
      final back = DbDumpCodec.structureFromJson({
        'kind': 'table',
        'schema': 'public',
        'table': 't',
      });
      expect(back.columns, isEmpty);
      expect(back.indexes, isEmpty);
      expect(back.constraints, isEmpty);
      expect(back.approxRows, 0);
      expect(back.comment, isNull);
    });
  });

  group('rows 批的值编码', () {
    test('各类值经 JSON 往返后类型和内容都还原', () {
      final ts = DateTime.utc(2026, 7, 15, 10, 30, 5, 123);
      final bytes = Uint8List.fromList([0, 1, 2, 255, 128]);
      final rows = <List<Object?>>[
        [1, 'hi', true, null, 3.5, ts, bytes],
        [2, '带引号"和\\反斜杠', false, null, -0.25, ts, Uint8List(0)],
      ];

      final json = _roundTrip(
        DbDumpCodec.rowsBatch(
          index: 0,
          columns: const ['id', 'name', 'ok', 'note', 'amt', 'at', 'blob'],
          rows: rows,
        ),
      );
      expect(json['kind'], 'rows');
      expect(DbDumpCodec.rowsColumns(json), [
        'id',
        'name',
        'ok',
        'note',
        'amt',
        'at',
        'blob',
      ]);

      final back = DbDumpCodec.rowsValues(json);
      expect(back, hasLength(2));
      expect(back[0][0], 1);
      expect(back[0][1], 'hi');
      expect(back[0][2], isTrue);
      expect(back[0][3], isNull);
      expect(back[0][4], 3.5);
      expect(back[0][5], isA<DateTime>());
      expect((back[0][5] as DateTime).toUtc(), ts);
      expect(back[0][6], isA<Uint8List>());
      expect(back[0][6], bytes);

      expect(back[1][1], '带引号"和\\反斜杠');
      expect(back[1][4], -0.25);
      expect(back[1][6], isEmpty);
    });

    test('jsonb / 数组列递归编码,嵌套的时间和字节也带标记', () {
      final at = DateTime.utc(2026, 1, 2, 3, 4, 5);
      final rows = <List<Object?>>[
        [
          {
            'tags': ['a', 'b'],
            'meta': {
              'at': at,
              'blob': Uint8List.fromList([9, 8]),
            },
            'n': 3,
          },
          [1, 2, 3],
          ['x', null],
        ],
      ];

      final json = _roundTrip(
        DbDumpCodec.rowsBatch(
          index: 0,
          columns: const ['doc', 'ints', 'texts'],
          rows: rows,
        ),
      );
      final back = DbDumpCodec.rowsValues(json).single;

      final doc = back[0] as Map<String, Object?>;
      expect(doc['tags'], ['a', 'b']);
      expect(doc['n'], 3);
      final meta = doc['meta'] as Map<String, Object?>;
      expect((meta['at'] as DateTime).toUtc(), at);
      expect(meta['blob'], isA<Uint8List>());
      expect(meta['blob'], [9, 8]);

      expect(back[1], [1, 2, 3]);
      expect(back[2], ['x', null]);
    });

    test('空批 / 缺字段读回空表而不是抛错', () {
      final json = _roundTrip(
        DbDumpCodec.rowsBatch(index: 0, columns: const ['id'], rows: const []),
      );
      expect(DbDumpCodec.rowsValues(json), isEmpty);
      expect(DbDumpCodec.rowsValues({'kind': 'rows'}), isEmpty);
      expect(DbDumpCodec.rowsColumns({'kind': 'rows'}), isEmpty);
    });

    test('未知驱动类型退化为字符串(不中断整批导出)', () {
      final json = _roundTrip(
        DbDumpCodec.rowsBatch(
          index: 0,
          columns: const ['weird'],
          rows: [
            [_Opaque()],
          ],
        ),
      );
      expect(DbDumpCodec.rowsValues(json).single.single, 'opaque-value');
    });
  });
}

class _Opaque {
  @override
  String toString() => 'opaque-value';
}
