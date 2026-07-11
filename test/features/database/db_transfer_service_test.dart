// DbTransferService 端到端测试 — 用两个本地 SQLite 文件跑
// 迁移(覆盖)/ 导出脚本 / 导入脚本 全链路,不依赖外部服务
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:termora/features/database/data/db_transfer_service.dart';
import 'package:termora/features/database/domain/db_etl.dart';
import 'package:termora/features/database/domain/db_models.dart';

void main() {
  late Directory tempDir;
  late String sourcePath;
  late String targetPath;

  DbConnectionConfig config(String id, String path) => DbConnectionConfig(
    id: id,
    name: id,
    engine: DbEngine.sqlite,
    database: path,
  );

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('termora_transfer_test');
    sourcePath = '${tempDir.path}/source.db';
    targetPath = '${tempDir.path}/target.db';

    final source = sqlite3.open(sourcePath);
    source.execute('''
CREATE TABLE users (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  bio TEXT,
  score REAL,
  avatar BLOB
);
CREATE TABLE empty_table (id INTEGER PRIMARY KEY, v TEXT);
''');
    final insert = source.prepare(
      'INSERT INTO users VALUES (?, ?, ?, ?, ?)',
    );
    for (var i = 1; i <= 450; i++) {
      insert.execute([
        i,
        "user'$i", // 带单引号,验证转义
        i % 3 == 0 ? null : 'bio $i',
        i * 0.5,
        i == 1 ? [0xde, 0xad, 0xbe, 0xef] : null,
      ]);
    }
    insert.close();
    source.close();

    // 目标库:建空文件(迁移不隐式建库)
    sqlite3.open(targetPath).close();
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  void verifyUsers(String path) {
    final db = sqlite3.open(path);
    try {
      expect(
        db.select('SELECT count(*) FROM users').first.values.first,
        450,
      );
      final row1 = db
          .select('SELECT name, bio, score, avatar FROM users WHERE id = 1')
          .first
          .values;
      expect(row1[0], "user'1");
      expect(row1[1], 'bio 1');
      expect(row1[2], 0.5);
      expect(row1[3], [0xde, 0xad, 0xbe, 0xef]);
      expect(
        db.select('SELECT bio FROM users WHERE id = 3').first.values.first,
        isNull,
      );
      // 主键约束迁过来了
      expect(
        () => db.execute("INSERT INTO users (id, name) VALUES (1, 'dup')"),
        throwsA(anything),
      );
    } finally {
      db.close();
    }
  }

  test('migrate: sqlite → sqlite 覆盖迁移(含分批拷贝/转义/NULL/BLOB)', () async {
    final log = <String>[];
    final summary = await DbTransferService.migrate(
      source: config('src', sourcePath),
      target: config('dst', targetPath),
      schema: 'main',
      tables: ['users', 'empty_table'],
      onProgress: (p) => log.add(p.message),
    );
    expect(summary.tables, 2);
    expect(summary.rows, 450);
    verifyUsers(targetPath);
    expect(log, isNotEmpty);

    // 再迁一次(目标已有同名表)→ 覆盖后数据不重复
    final again = await DbTransferService.migrate(
      source: config('src', sourcePath),
      target: config('dst', targetPath),
      schema: 'main',
      tables: ['users'],
    );
    expect(again.rows, 450);
    verifyUsers(targetPath);
  });

  test('migrate: 不覆盖时撞同名表报错', () async {
    await DbTransferService.migrate(
      source: config('src', sourcePath),
      target: config('dst', targetPath),
      schema: 'main',
      tables: ['users'],
    );
    await expectLater(
      DbTransferService.migrate(
        source: config('src', sourcePath),
        target: config('dst', targetPath),
        schema: 'main',
        tables: ['users'],
        overwrite: false,
      ),
      throwsA(anything),
    );
  });

  test('migrate: 仅结构不拷数据', () async {
    final summary = await DbTransferService.migrate(
      source: config('src', sourcePath),
      target: config('dst', targetPath),
      schema: 'main',
      tables: ['users'],
      copyData: false,
    );
    expect(summary.rows, 0);
    final db = sqlite3.open(targetPath);
    expect(db.select('SELECT count(*) FROM users').first.values.first, 0);
    db.close();
  });

  test('migrate: 取消会中断', () async {
    var calls = 0;
    await expectLater(
      DbTransferService.migrate(
        source: config('src', sourcePath),
        target: config('dst', targetPath),
        schema: 'main',
        tables: ['users'],
        isCancelled: () => ++calls > 2,
      ),
      throwsA(isA<DbTransferCancelledException>()),
    );
  });

  test('exportToScript + importScript: 导出再导入等价', () async {
    final scriptPath = '${tempDir.path}/dump.sql';
    final summary = await DbTransferService.exportToScript(
      source: config('src', sourcePath),
      schema: 'main',
      tables: ['users'],
      targetEngine: DbEngine.sqlite,
      filePath: scriptPath,
    );
    expect(summary.rows, 450);

    final script = await File(scriptPath).readAsString();
    expect(script, contains('DROP TABLE IF EXISTS "users"'));
    expect(script, contains('CREATE TABLE "users"'));
    expect(script, contains('INSERT INTO "users"'));

    final imported = await DbTransferService.importScript(
      target: config('dst', targetPath),
      script: script,
    );
    // DROP + CREATE + 3 批 INSERT(450 行 / 每批 200)
    expect(imported.statements, 5);
    verifyUsers(targetPath);
  });

  test('importScript: 语句失败带序号和语句预览', () async {
    await expectLater(
      DbTransferService.importScript(
        target: config('dst', targetPath),
        script: 'CREATE TABLE ok (id INTEGER);\nSELECT * FROM missing;',
      ),
      throwsA(
        predicate(
          (e) => '$e'.contains('#2') && '$e'.contains('missing'),
        ),
      ),
    );
  });

  test('migrate 整库:遍历全部表、跳过视图', () async {
    // source.db 有 users(250) / empty_table(0) 两张表,建个视图确认被跳过
    final seed = sqlite3.open(sourcePath);
    seed.execute('CREATE VIEW v_users AS SELECT * FROM users');
    seed.close();

    final summary = await DbTransferService.migrate(
      source: config('src', sourcePath),
      target: config('dst', targetPath),
      wholeDatabase: true,
    );
    // 2 张表(视图不算),users 450 行
    expect(summary.tables, 2);
    expect(summary.rows, 450);

    final db = sqlite3.open(targetPath);
    try {
      final tables = db
          .select(
            "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
          )
          .map((r) => r.values.first)
          .toList();
      expect(tables, ['empty_table', 'users']);
      // sqlite 目标无 schema,落到 main、不带前缀
      expect(
        db.select('SELECT count(*) FROM users').first.values.first,
        450,
      );
      // 视图没被迁成表
      expect(
        db.select(
          "SELECT count(*) FROM sqlite_master WHERE name='v_users'",
        ).first.values.first,
        0,
      );
    } finally {
      db.close();
    }
  });

  test('exportToScript 整库(sqlite 方言):无 schema 前缀', () async {
    final scriptPath = '${tempDir.path}/whole.sql';
    final summary = await DbTransferService.exportToScript(
      source: config('src', sourcePath),
      wholeDatabase: true,
      targetEngine: DbEngine.sqlite,
      filePath: scriptPath,
    );
    expect(summary.tables, 2);
    final script = await File(scriptPath).readAsString();
    expect(script, contains('CREATE TABLE "users"'));
    expect(script, contains('CREATE TABLE "empty_table"'));
    // sqlite 方言不产生 CREATE SCHEMA
    expect(script, isNot(contains('CREATE SCHEMA')));
  });

  test('migrate schemaTables:指定 schema→表(空列表=全部表)', () async {
    // 显式表清单
    final s1 = await DbTransferService.migrate(
      source: config('src', sourcePath),
      target: config('dst', targetPath),
      schemaTables: const {
        'main': ['users'],
      },
    );
    expect(s1.tables, 1);
    expect(s1.rows, 450);
    var db = sqlite3.open(targetPath);
    expect(
      db.select(
        "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='empty_table'",
      ).first.values.first,
      0, // empty_table 未迁
    );
    db.close();

    // 空列表 = 该 schema 全部表
    final s2 = await DbTransferService.migrate(
      source: config('src', sourcePath),
      target: config('dst', targetPath),
      schemaTables: const {'main': []},
    );
    expect(s2.tables, 2); // users + empty_table
    db = sqlite3.open(targetPath);
    expect(
      db.select('SELECT count(*) FROM empty_table').first.values.first,
      0,
    );
    db.close();
  });

  test('migrate + ETL:行过滤/表列改名/裁剪/脱敏', () async {
    const rule = DbEtlTableRule(
      table: 'users',
      targetTable: 'vip_users',
      rowFilters: [
        DbColumnFilter(column: 'id', op: DbFilterOp.inList, value: '1,2,3,4,5'),
      ],
      columns: {
        'avatar': DbEtlColumnRule(column: 'avatar', include: false),
        'bio': DbEtlColumnRule(
          column: 'bio',
          rename: 'about',
          transform: DbEtlTransform.upper,
        ),
        'name': DbEtlColumnRule(
          column: 'name',
          transform: DbEtlTransform.mask,
          param: '2,2',
        ),
        'score': DbEtlColumnRule(
          column: 'score',
          transform: DbEtlTransform.fixed,
          param: 'N/A',
        ),
      },
    );

    final summary = await DbTransferService.migrate(
      source: config('src', sourcePath),
      target: config('dst', targetPath),
      schema: 'main',
      tables: ['users'],
      etlRules: const {'users': rule},
    );
    expect(summary.rows, 5); // 行过滤只留 1..5

    final db = sqlite3.open(targetPath);
    try {
      // 表改名 + 列裁剪/改名
      final cols = db
          .select("SELECT name FROM pragma_table_info('vip_users')")
          .map((r) => r.values.first)
          .toList();
      expect(cols, ['id', 'name', 'about', 'score']);

      expect(
        db.select('SELECT count(*) FROM vip_users').first.values.first,
        5,
      );
      final row = db
          .select('SELECT name, about, score FROM vip_users WHERE id = 1')
          .first
          .values;
      expect(row[0], "us**'1"); // mask 2,2:user'1 → us**'1
      expect(row[1], 'BIO 1'); // upper
      expect(row[2], 'N/A'); // fixed(类型强转为 TEXT)
      expect(
        db
            .select('SELECT about FROM vip_users WHERE id = 3')
            .first
            .values
            .first,
        isNull, // 源 bio 为 NULL,upper 透传
      );
      // 主键约束仍在
      expect(
        () => db.execute(
          "INSERT INTO vip_users (id, name) VALUES (1, 'dup')",
        ),
        throwsA(anything),
      );
    } finally {
      db.close();
    }
  });

  test('exportToScript + ETL:脚本里是转换后的结构和数据', () async {
    const rule = DbEtlTableRule(
      table: 'users',
      targetTable: 'vip_users',
      rowFilters: [
        DbColumnFilter(column: 'id', op: DbFilterOp.equals, value: '1'),
      ],
      columns: {
        'avatar': DbEtlColumnRule(column: 'avatar', include: false),
        'name': DbEtlColumnRule(
          column: 'name',
          transform: DbEtlTransform.hash,
        ),
      },
    );
    final scriptPath = '${tempDir.path}/etl.sql';
    final summary = await DbTransferService.exportToScript(
      source: config('src', sourcePath),
      schema: 'main',
      tables: ['users'],
      targetEngine: DbEngine.sqlite,
      filePath: scriptPath,
      etlRules: const {'users': rule},
    );
    expect(summary.rows, 1);

    final script = await File(scriptPath).readAsString();
    expect(script, contains('CREATE TABLE "vip_users"'));
    expect(script, isNot(contains('avatar'))); // 列被裁掉
    expect(script, isNot(contains("user'1"))); // 明文没进脚本
    expect(script, contains(RegExp('[0-9a-f]{64}'))); // 只有哈希
  });

  test('exportToScript: 跨方言导出(postgres 语法)', () async {
    final scriptPath = '${tempDir.path}/pg.sql';
    await DbTransferService.exportToScript(
      source: config('src', sourcePath),
      schema: 'main',
      tables: ['users'],
      targetEngine: DbEngine.postgres,
      filePath: scriptPath,
    );
    final script = await File(scriptPath).readAsString();
    // sqlite INTEGER → pg bigint;BLOB → bytea hex
    expect(script, contains('"id" bigint NOT NULL'));
    expect(script, contains(r"'\xdeadbeef'"));
    expect(script, contains("'user''1'"));
  });
}
