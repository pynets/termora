@Tags(['smoke'])
library;

// ClickHouseService 冒烟测试 — 需要本地 8124 端口有临时 ClickHouse:
//   clickhouse-server -- --http_port=8124 ...
//   建库 demo + 表 demo.events(见对话脚本),然后:
//   flutter test --run-skipped --tags smoke test/features/database/clickhouse_service_smoke_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:termora/features/database/data/clickhouse_service.dart';
import 'package:termora/features/database/domain/db_models.dart';

void main() {
  const config = DbConnectionConfig(
    id: 'ch-smoke',
    name: 'ch-smoke',
    engine: DbEngine.clickhouse,
    host: '127.0.0.1',
    port: 8124,
    database: 'demo',
    username: 'default',
    password: '',
  );

  test('端到端: 连接/库/表/数据/结构/查询', () async {
    // 测试连接
    final version = await ClickHouseService.testConnection(config);
    expect(version, isNotEmpty);

    // 库列表(排除系统库,含 demo)
    final schemas = await ClickHouseService.listSchemas(config);
    expect(schemas, contains('demo'));
    expect(schemas, isNot(contains('system')));

    // 表列表
    final tables = await ClickHouseService.listTables(config, 'demo');
    expect(tables.map((t) => t.name), contains('events'));

    // 表数据第一页(200 行 + hasMore),ClickHouse 只读 → editContext 为 null
    final (page0, hasMore0, ctx0) = await ClickHouseService.fetchTableData(
      config,
      'demo',
      'events',
    );
    expect(page0.columns, ['id', 'name', 'ts', 'amount']);
    expect(page0.rows.length, ClickHouseService.pageSize);
    expect(hasMore0, true);
    expect(ctx0, isNull);

    // 最后一页(450 → 第 3 页 50 行)
    final (page2, hasMore2, _) = await ClickHouseService.fetchTableData(
      config,
      'demo',
      'events',
      page: 2,
    );
    expect(page2.rows.length, 50);
    expect(hasMore2, false);

    // NULL 保留(amount 每 5 行一个 null)
    expect(page0.rows.any((r) => r[3] == null), true);

    // 排序:按 id 降序,首行是最大 id
    final (sorted, _, _) = await ClickHouseService.fetchTableData(
      config,
      'demo',
      'events',
      orderBy: 'id',
      ascending: false,
    );
    expect('${sorted.rows.first[0]}', '449');

    // 列过滤:name = 'user_7'
    final (filtered, _, _) = await ClickHouseService.fetchTableData(
      config,
      'demo',
      'events',
      columnFilters: const [
        DbColumnFilter(
          column: 'name',
          op: DbFilterOp.equals,
          value: 'user_7',
        ),
      ],
    );
    expect(filtered.rows.length, 1);
    expect(filtered.rows.first[0].toString(), '7');

    // 全行过滤:匹配 'user_44'(user_44, user_144...)
    final (rowFiltered, _, _) = await ClickHouseService.fetchTableData(
      config,
      'demo',
      'events',
      filter: 'user_44',
    );
    expect(rowFiltered.rows, isNotEmpty);

    // 计数(全表 + 过滤后)
    final total = await ClickHouseService.countRows(config, 'demo', 'events');
    expect(total, 450);
    final filteredCount = await ClickHouseService.countRows(
      config,
      'demo',
      'events',
      columnFilters: const [
        DbColumnFilter(column: 'id', op: DbFilterOp.lessEqual, value: '9'),
      ],
    );
    expect(filteredCount, lessThan(450));
    expect(filteredCount, greaterThan(0));

    // 表结构:列/类型/主键/行数
    final structure = await ClickHouseService.fetchTableStructure(
      config,
      'demo',
      'events',
    );
    expect(structure.columns.length, 4);
    final idCol = structure.columns.first;
    expect(idCol.name, 'id');
    expect(idCol.dataType, 'UInt64');
    expect(idCol.isPrimaryKey, true); // ORDER BY id → 主键
    final amountCol = structure.columns.firstWhere((c) => c.name == 'amount');
    expect(amountCol.nullable, true);
    expect(structure.approxRows, greaterThan(0));

    // SQL 查询
    final (query, queryCtx) = await ClickHouseService.runSql(
      config,
      'SELECT count() AS c, max(id) AS m FROM demo.events',
    );
    expect(query.columns, ['c', 'm']);
    expect('${query.rows.single[0]}', '450');
    expect(queryCtx, isNull); // 只读

    // 语法错误 → 抛可读异常
    await expectLater(
      ClickHouseService.runSql(config, 'SELEC oops'),
      throwsA(isA<ClickHouseException>()),
    );
  });
}
