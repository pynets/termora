@Tags(['smoke'])
library;

// PostgresService 冒烟测试 — 需要本地 55432 端口有临时 PG 实例:
//   initdb + pg_ctl -o "-p 55432" 后运行:
//   flutter test --tags smoke test/features/database/postgres_service_smoke_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:termora/features/database/data/postgres_service.dart';
import 'package:termora/features/database/domain/db_models.dart';

void main() {
  const config = DbConnectionConfig(
    id: 'smoke',
    name: 'smoke',
    host: 'localhost',
    port: 55432,
    database: 'postgres',
    username: 'postgres',
    password: '',
  );

  test('端到端: 连接/元数据/表数据/SQL', () async {
    // 测试连接
    final version = await PostgresService.testConnection(config);
    expect(version, isNotEmpty);

    final conn = await PostgresService.open(config);
    try {
      // schema 列表
      final schemas = await PostgresService.listSchemas(conn);
      expect(schemas, contains('public'));

      // 表 + 视图列表
      final tables = await PostgresService.listTables(conn, 'public');
      final names = {for (final t in tables) t.name: t.isView};
      expect(names['demo_users'], false);
      expect(names['demo_adults'], true);

      // 表数据第一页(200 行 + hasMore)
      final (page0, hasMore0, ctx0) = await PostgresService.fetchTableData(
        conn,
        'public',
        'demo_users',
      );
      expect(page0.columns, ['id', 'name', 'age', 'note', 'created_at']);
      expect(page0.rows.length, PostgresService.pageSize);
      expect(hasMore0, true);
      // 编辑上下文: 单表来源 + 完整主键 → 可编辑
      expect(ctx0?.editable, true);
      expect(ctx0?.pkColumnIndexes, [0]);

      // 最后一页(450 行 → 第 3 页 50 行,无更多)
      final (page2, hasMore2, _) = await PostgresService.fetchTableData(
        conn,
        'public',
        'demo_users',
        page: 2,
      );
      expect(page2.rows.length, 50);
      expect(hasMore2, false);

      // 排序 + 过滤 + 总数
      final (sorted, _, _) = await PostgresService.fetchTableData(
        conn,
        'public',
        'demo_users',
        orderBy: 'age',
        ascending: false,
      );
      expect(sorted.rows.first[2], 69); // 最大年龄 20+49
      final (filtered, _, _) = await PostgresService.fetchTableData(
        conn,
        'public',
        'demo_users',
        filter: 'user_7',
      );
      // user_7, user_70..79, user_170..179...(全行匹配)
      expect(filtered.rows, isNotEmpty);
      final total = await PostgresService.countRows(
        conn,
        'public',
        'demo_users',
      );
      expect(total, 450);

      // 列级过滤 + 计数(age >= 60 → 20+i%50>=60 即 i%50 in 40..49)
      const ageFilter = [
        DbColumnFilter(
          column: 'age',
          op: DbFilterOp.greaterEqual,
          value: '60',
        ),
      ];
      final (colFiltered, _, _) = await PostgresService.fetchTableData(
        conn,
        'public',
        'demo_users',
        columnFilters: ageFilter,
      );
      expect(colFiltered.rows.every((r) => (r[2] as int) >= 60), true);
      final colCount = await PostgresService.countRows(
        conn,
        'public',
        'demo_users',
        columnFilters: ageFilter,
      );
      expect(colCount, greaterThan(0));
      expect(colCount, lessThan(450));

      // NULL 值保留
      expect(page0.rows.any((r) => r[3] == null), true);

      // SQL 查询 — 表达式聚合结果不可编辑
      final (query, queryCtx) = await PostgresService.runSql(
        conn,
        "SELECT count(*)::int AS total FROM demo_users WHERE age >= 30",
      );
      expect(query.columns, ['total']);
      expect(query.rows.single.single, greaterThan(0));
      expect(queryCtx?.editable ?? false, false);

      // SQL 查询 — 别名单表查询含主键 → 可编辑,别名映射回真实列
      final (aliased, aliasedCtx) = await PostgresService.runSql(
        conn,
        'SELECT id, name AS nick FROM demo_users ORDER BY id LIMIT 5',
      );
      expect(aliased.columns, ['id', 'nick']);
      expect(aliasedCtx?.editable, true);
      expect(aliasedCtx?.columnNames, ['id', 'name']);

      // SQL 写入(affectedRows)
      final (update, _) = await PostgresService.runSql(
        conn,
        "UPDATE demo_users SET note = 'smoke' WHERE id <= 3",
      );
      expect(update.affectedRows, 3);

      // 多语句脚本: 客户端拆分逐条执行,返回最后一条有结果集语句的行
      final (multi, _) = await PostgresService.runSql(
        conn,
        "SELECT 1; SELECT name FROM demo_users ORDER BY id LIMIT 2;",
      );
      expect(multi.rows.length, 2);
      expect(multi.columns, ['name']);

      // 语句拆分器: 引号/注释/dollar-quote 中的分号不拆
      expect(
        PostgresService.splitStatements(
          "SELECT 'a;b'; -- c;d\nSELECT \$\$x;y\$\$ /* z;w */; SELECT 1",
        ).length,
        3,
      );

      // 语法错误 → 抛出可读异常
      await expectLater(
        PostgresService.runSql(conn, 'SELEC oops'),
        throwsA(anything),
      );

      // 表结构: 列/类型/主键/可空/默认值 + 索引
      final structure = await PostgresService.fetchTableStructure(
        conn,
        'public',
        'demo_users',
      );
      expect(structure.columns.length, 5);
      final idCol = structure.columns.first;
      expect(idCol.name, 'id');
      expect(idCol.isPrimaryKey, true);
      expect(idCol.nullable, false);
      expect(idCol.defaultValue, contains('nextval'));
      final nameCol = structure.columns[1];
      expect(nameCol.dataType, 'text');
      expect(nameCol.nullable, true);
      expect(structure.indexes.map((i) => i.name), contains('demo_users_pkey'));
      // 表大小/行数估计可用
      expect(structure.totalBytes, greaterThan(0));
      expect(structure.prettySize, isNot('—'));

      // 单元格编辑: 主键 UPDATE + RETURNING 回读(文本 CAST 成列类型)
      final updated = await PostgresService.updateCell(
        conn,
        schema: 'public',
        table: 'demo_users',
        column: 'age',
        dataType: 'integer',
        pkValues: {'id': 1},
        newValue: '99',
      );
      expect(updated, 99); // 回读值已是 int 而非文本

      // SET NULL
      final nulled = await PostgresService.updateCell(
        conn,
        schema: 'public',
        table: 'demo_users',
        column: 'note',
        dataType: 'text',
        pkValues: {'id': 1},
        newValue: null,
      );
      expect(nulled, isNull);

      // 类型不合法 → 抛异常(事务不脏:单语句自动回滚)
      await expectLater(
        PostgresService.updateCell(
          conn,
          schema: 'public',
          table: 'demo_users',
          column: 'age',
          dataType: 'integer',
          pkValues: {'id': 1},
          newValue: 'not_a_number',
        ),
        throwsA(anything),
      );

      // 主键未命中 → affectedRows 0 → StateError
      await expectLater(
        PostgresService.updateCell(
          conn,
          schema: 'public',
          table: 'demo_users',
          column: 'age',
          dataType: 'integer',
          pkValues: {'id': 999999},
          newValue: '1',
        ),
        throwsA(isA<StateError>()),
      );

      // CSV 导出: 引号/逗号/换行转义
      const csvOutput = DbQueryOutput(
        columns: ['a', 'b'],
        rows: [
          ['x,y', 'he said "hi"'],
          [null, 'line1\nline2'],
        ],
      );
      expect(
        csvOutput.toCsv(),
        'a,b\n"x,y","he said ""hi"""\n,"line1\nline2"\n',
      );

      // ── UUID 列归一化(不应是 UndecodedBytes)──
      await conn.execute(
        'CREATE TABLE uuid_demo(id uuid primary key default gen_random_uuid(), tag text)',
      );
      await conn.execute("INSERT INTO uuid_demo(tag) VALUES ('a'), ('b')");
      final (uuidOut, _, _) = await PostgresService.fetchTableData(
        conn,
        'public',
        'uuid_demo',
      );
      final uuidVal = uuidOut.rows.first[0];
      expect(uuidVal, isA<String>());
      // 标准 UUID 格式 8-4-4-4-12
      expect(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
        ).hasMatch(uuidVal as String),
        true,
      );
      expect(uuidVal.toString(), isNot(contains('UndecodedBytes')));
      await conn.execute('DROP TABLE uuid_demo');

      // ── 累积编辑批量提交(事务)──
      await conn.execute(
        'CREATE TABLE edit_demo(id serial primary key, name text, n int)',
      );
      await conn.execute(
        "INSERT INTO edit_demo(name, n) VALUES ('a', 1), ('b', 2), ('c', 3)",
      );
      final (editOutput, _, editCtx) = await PostgresService.fetchTableData(
        conn,
        'public',
        'edit_demo',
      );
      expect(editCtx?.editable, true);

      // 攒改动: 改第0行 name、删第1行、加一行
      final session = DbEditSession(
        editedCells: {
          0: {1: 'aa'},
        },
        removedRows: {1},
        addedRows: [
          [DbEditSession.unsetValue, 'd', 4],
        ],
      );
      final applied = await PostgresService.applyChanges(
        conn,
        context: editCtx!,
        output: editOutput,
        session: session,
      );
      expect(applied, 3); // 1 update + 1 delete + 1 insert

      final (after, _, _) = await PostgresService.fetchTableData(
        conn,
        'public',
        'edit_demo',
        orderBy: 'id',
      );
      final editNames = [for (final r in after.rows) r[1]];
      expect(editNames, containsAll(['aa', 'c', 'd'])); // b 已删,a→aa,新增 d
      expect(editNames, isNot(contains('b')));

      // 事务回滚: 一处非法类型 → 整批不生效
      final (cur, _, curCtx) = await PostgresService.fetchTableData(
        conn,
        'public',
        'edit_demo',
        orderBy: 'id',
      );
      final beforeCount = cur.rows.length;
      final badSession = DbEditSession(
        editedCells: {
          0: {2: 'not_int'}, // n 是 int,非法
        },
        addedRows: [
          [DbEditSession.unsetValue, 'should_not_persist', 9],
        ],
      );
      await expectLater(
        PostgresService.applyChanges(
          conn,
          context: curCtx!,
          output: cur,
          session: badSession,
        ),
        throwsA(anything),
      );
      final (rolledBack, _, _) = await PostgresService.fetchTableData(
        conn,
        'public',
        'edit_demo',
      );
      // 新增行未持久化,行数不变
      expect(rolledBack.rows.length, beforeCount);
      expect(
        rolledBack.rows.every((r) => r[1] != 'should_not_persist'),
        true,
      );

      await conn.execute('DROP TABLE edit_demo');
    } finally {
      await conn.close();
    }
  });
}
