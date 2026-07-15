@Tags(['smoke'])
library;

// 复现并守住用户场景:多 schema + serial 主键 + 整库迁移(保留 schema),
// 目标序列须拨到 max —— 迁移后不写 id 插入应续增、不撞主键。
// 需本地 55432 临时 PG(源库 postgres 建 hub/community 两个 schema)。
import 'package:flutter_test/flutter_test.dart';
import 'package:termora/features/database/data/db_service.dart';
import 'package:termora/features/database/data/db_transfer_service.dart';
import 'package:termora/features/database/domain/db_models.dart';

const _src = DbConnectionConfig(
  id: 's',
  name: 's',
  host: 'localhost',
  port: 55432,
  database: 'postgres',
  username: 'postgres',
  password: '',
);
const _dst = DbConnectionConfig(
  id: 'd',
  name: 'd',
  host: 'localhost',
  port: 55432,
  database: 'seqtgt',
  username: 'postgres',
  password: '',
);

Future<List<List<Object?>>> _q(DbConnectionConfig c, String sql) async {
  final conn = await DbService.open(c);
  try {
    final (o, _) = await DbService.runSql(conn, sql);
    return o.rows;
  } finally {
    await conn.close();
  }
}

Future<void> _e(DbConnectionConfig c, String sql) async {
  final conn = await DbService.open(c);
  try {
    await DbService.runSql(conn, sql);
  } finally {
    await conn.close();
  }
}

void main() {
  setUp(() async {
    // 源:两个 schema(触发保留 schema),各一张 serial 主键表
    await _e(_src, '''
DROP SCHEMA IF EXISTS hub, community CASCADE;
CREATE SCHEMA hub;
CREATE SCHEMA community;
CREATE TABLE hub.auth_role (role_id serial PRIMARY KEY, name text);
INSERT INTO hub.auth_role (name) SELECT 'r' || i FROM generate_series(1, 5) i;
CREATE TABLE community.live_room (id serial PRIMARY KEY, t text);
INSERT INTO community.live_room (t) SELECT 'x' || i FROM generate_series(1, 3) i;
''');
    try {
      await _e(_src, 'CREATE DATABASE seqtgt');
    } catch (_) {}
    await _e(_dst, 'DROP SCHEMA IF EXISTS hub, community CASCADE');
  });

  Future<void> assertSequenceAdvanced() async {
    // 目标端 role_id 是 IDENTITY 列
    expect(
      (await _q(
        _dst,
        """
SELECT attidentity FROM pg_attribute a
JOIN pg_class c ON c.oid = a.attrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'hub' AND c.relname = 'auth_role' AND attname = 'role_id'""",
      )).first.first,
      'd',
    );
    // 不写 id 直接插入 → 续在 max=5 之后 = 6(序列已被拨到 max)
    expect(
      (await _q(
        _dst,
        "INSERT INTO hub.auth_role (name) VALUES ('n') RETURNING role_id",
      )).first.first,
      6,
    );
    expect(
      (await _q(
        _dst,
        "INSERT INTO community.live_room (t) VALUES ('n') RETURNING id",
      )).first.first,
      4,
    );
  }

  test('整库迁移(保留 schema)serial→IDENTITY:序列拨到 max,续增不撞', () async {
    await DbTransferService.migrate(
      source: _src,
      target: _dst,
      wholeDatabase: true,
    );
    await assertSequenceAdvanced();
  });

  test('覆盖式重迁一次后,序列仍正确', () async {
    await DbTransferService.migrate(
      source: _src,
      target: _dst,
      wholeDatabase: true,
    );
    // 目标已存在 IDENTITY 表,再覆盖迁一次(DROP CASCADE + 重建 + setval)
    await DbTransferService.migrate(
      source: _src,
      target: _dst,
      wholeDatabase: true,
    );
    await assertSequenceAdvanced();
  });
}
