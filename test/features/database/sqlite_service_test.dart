// SqliteService 端到端测试 — 本地临时文件建库,不依赖外部服务
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:termora/features/database/data/sqlite_service.dart';
import 'package:termora/features/database/domain/db_models.dart';

void main() {
  late Directory tempDir;
  late String dbPath;
  late Database db;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('termora_sqlite_test');
    dbPath = '${tempDir.path}/demo.db';
    final seed = sqlite3.open(dbPath);
    seed.execute('''
CREATE TABLE users (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  score REAL DEFAULT 0
);
CREATE INDEX idx_users_name ON users(name);
CREATE VIEW top_users AS SELECT * FROM users WHERE score > 50;
CREATE TABLE no_pk (v TEXT);
''');
    final insert = seed.prepare('INSERT INTO users (id, name, score) VALUES (?, ?, ?)');
    for (var i = 1; i <= 250; i++) {
      insert.execute([i, 'user$i', i * 1.0]);
    }
    insert.close();
    seed.close();

    db = sqlite3.open(dbPath);
  });

  tearDown(() {
    db.close();
    tempDir.deleteSync(recursive: true);
  });

  DbConnectionConfig config() => DbConnectionConfig(
    id: 'sqlite-test',
    name: 'sqlite-test',
    engine: DbEngine.sqlite,
    database: dbPath,
  );

  test('open: 文件不存在时报错而不是建空库', () async {
    final bad = DbConnectionConfig(
      id: 'x',
      name: 'x',
      engine: DbEngine.sqlite,
      database: '${tempDir.path}/nope.db',
    );
    await expectLater(SqliteService.open(bad), throwsA(isA<StateError>()));
    expect(File('${tempDir.path}/nope.db').existsSync(), isFalse);
  });

  test('testConnection / listSchemas / listTables', () async {
    final version = await SqliteService.testConnection(config());
    expect(version, isNotEmpty);

    final schemas = await SqliteService.listSchemas(db);
    expect(schemas, ['main']);

    final tables = await SqliteService.listTables(db, 'main');
    expect(
      tables.map((t) => t.name).toList(),
      ['no_pk', 'users', 'top_users'], // table 在 view 前
    );
    expect(tables.firstWhere((t) => t.name == 'top_users').isView, isTrue);
  });

  test('fetchTableData: 分页/排序/过滤/编辑上下文', () async {
    final (page0, hasMore, ctx) = await SqliteService.fetchTableData(
      db,
      'main',
      'users',
    );
    expect(page0.columns, ['id', 'name', 'score']);
    expect(page0.rows.length, 200);
    expect(hasMore, isTrue);
    expect(ctx, isNotNull);
    expect(ctx!.editable, isTrue);
    expect(ctx.pkColumnIndexes, [0]);

    final (page1, hasMore1, _) = await SqliteService.fetchTableData(
      db,
      'main',
      'users',
      page: 1,
    );
    expect(page1.rows.length, 50);
    expect(hasMore1, isFalse);

    // 排序
    final (sorted, _, _) = await SqliteService.fetchTableData(
      db,
      'main',
      'users',
      orderBy: 'id',
      ascending: false,
    );
    expect(sorted.rows.first.first, 250);

    // 全行过滤(LIKE 对 ASCII 不区分大小写)
    final (filtered, _, _) = await SqliteService.fetchTableData(
      db,
      'main',
      'users',
      filter: 'USER25',
    );
    expect(filtered.rows.length, 2); // user25 / user250

    // 列过滤
    final (colFiltered, _, _) = await SqliteService.fetchTableData(
      db,
      'main',
      'users',
      columnFilters: const [
        DbColumnFilter(column: 'id', op: DbFilterOp.inList, value: '1, 2, 3'),
        DbColumnFilter(column: 'name', op: DbFilterOp.notEquals, value: 'user2'),
      ],
    );
    expect(colFiltered.rows.length, 2);

    expect(await SqliteService.countRows(db, 'main', 'users'), 250);
    expect(
      await SqliteService.countRows(db, 'main', 'users', filter: 'user25'),
      2,
    );

    // 无主键表 / 视图 → 只读
    final (_, _, noPkCtx) = await SqliteService.fetchTableData(
      db,
      'main',
      'no_pk',
    );
    expect(noPkCtx?.editable ?? false, isFalse);
    final (viewOut, _, viewCtx) = await SqliteService.fetchTableData(
      db,
      'main',
      'top_users',
    );
    expect(viewOut.rows, isNotEmpty);
    expect(viewCtx?.editable ?? false, isFalse);
  });

  test('fetchTableStructure: 列/主键/索引/行数', () async {
    final structure = await SqliteService.fetchTableStructure(
      db,
      'main',
      'users',
    );
    expect(structure.columns.length, 3);
    final id = structure.columns.first;
    expect(id.name, 'id');
    expect(id.isPrimaryKey, isTrue);
    expect(id.nullable, isFalse);
    final score = structure.columns.last;
    expect(score.defaultValue, '0');
    expect(structure.indexes.map((i) => i.name), contains('idx_users_name'));
    expect(structure.approxRows, 250);
  });

  test('runSql: 多语句脚本,返回最后一个结果集', () async {
    final (output, ctx) = await SqliteService.runSql(db, '''
-- 注释里有分号; 不拆
UPDATE users SET score = 99.5 WHERE id = 1;
SELECT id, name FROM users WHERE name = 'user;1' OR id = 1;
''');
    // 单表 SELECT 且结果覆盖主键 → 推断出可编辑上下文(结果网格可改)
    expect(ctx, isNotNull);
    expect(ctx!.table, 'users');
    expect(ctx.editable, isTrue);
    expect(output.columns, ['id', 'name']);
    expect(output.rows, [
      [1, 'user1'],
    ]);
    expect(
      db.select('SELECT score FROM users WHERE id = 1').first.values.first,
      99.5,
    );
  });

  test('applyChanges: 增删改一个事务提交', () async {
    final (output, _, ctx) = await SqliteService.fetchTableData(
      db,
      'main',
      'users',
    );
    final session = DbEditSession(
      editedCells: {
        0: {1: 'renamed', 2: null}, // id=1: name 改值,score 置 NULL
      },
      removedRows: {1}, // 删 id=2
      addedRows: [
        [999, 'newbie', DbEditSession.unsetValue], // score 用默认值
      ],
    );
    final applied = await SqliteService.applyChanges(
      db,
      context: ctx!,
      output: output,
      session: session,
    );
    expect(applied, 3);

    final row1 = db.select('SELECT name, score FROM users WHERE id = 1').first;
    expect(row1.values, ['renamed', null]);
    expect(db.select('SELECT * FROM users WHERE id = 2'), isEmpty);
    final added = db.select('SELECT name, score FROM users WHERE id = 999').first;
    expect(added.values, ['newbie', 0.0]);
  });

  test('applyChanges: 中途失败整体回滚', () async {
    final (output, _, ctx) = await SqliteService.fetchTableData(
      db,
      'main',
      'users',
    );
    final session = DbEditSession(
      removedRows: {0}, // 先删 id=1(会成功)
      addedRows: [
        [2, 'dup', DbEditSession.unsetValue], // id=2 主键冲突 → 失败
      ],
    );
    await expectLater(
      SqliteService.applyChanges(
        db,
        context: ctx!,
        output: output,
        session: session,
      ),
      throwsA(anything),
    );
    // 删除也一并回滚
    expect(await SqliteService.countRows(db, 'main', 'users'), 250);
  });
}
