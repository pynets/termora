@Tags(['smoke'])
library;

// 断连自愈的 PostgreSQL 冒烟测试 — 需要本地 55432 临时 PG:
//   flutter test --run-skipped --tags smoke test/features/database/db_reconnect_pg_smoke_test.dart
// 场景:连上后服务端 pg_terminate_backend 杀掉后台(等价断网/休眠后 socket 死掉),
// 再执行 SQL 应自动重连成功,而不是报 "connection is not open"。
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postgres/postgres.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:termora/features/database/controller/database_providers.dart';
import 'package:termora/features/database/data/db_service.dart';
import 'package:termora/features/database/domain/db_models.dart';

// 用独立数据库,避免 pg_terminate_backend 误杀并发跑的其它冒烟测试连接
const _dbName = 'reconnect_probe';

const _pg = DbConnectionConfig(
  id: 'pg',
  name: 'pg',
  host: 'localhost',
  port: 55432,
  database: _dbName,
  username: 'postgres',
  password: '',
);

Future<void> _pump([int ms = 20]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

Future<Connection> _admin([String db = 'postgres']) => Connection.open(
  Endpoint(
    host: 'localhost',
    port: 55432,
    database: db,
    username: 'postgres',
    password: '',
  ),
  settings: const ConnectionSettings(sslMode: SslMode.disable),
);

/// 只杀本测试库上的其它后台(即控制器那条连接),不动别的库
Future<void> _killOtherBackends() async {
  final admin = await _admin();
  await admin.execute(
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity "
    "WHERE datname = '$_dbName' AND pid <> pg_backend_pid()",
  );
  await admin.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final admin = await _admin();
    try {
      await admin.execute('CREATE DATABASE $_dbName');
    } catch (_) {} // 已存在
    await admin.close();
  });

  test('DbConnection.isOpen:关闭后翻成 false', () async {
    final conn = await DbService.open(_pg);
    expect(conn.isOpen, isTrue);
    await conn.close();
    expect(conn.isOpen, isFalse);
  });

  test('后台被杀后再执行 SQL:自动重连并返回结果(不再 connection is not open)',
      () async {
    SharedPreferences.setMockInitialValues({
      'database.connections.v1': jsonEncode([_pg.toJson()]),
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);

    // 等连接配置 provider 加载
    for (var i = 0; i < 100; i++) {
      if (container.read(dbConnectionsProvider).isNotEmpty) break;
      await _pump(5);
    }
    final notifier = container.read(dbSessionProvider.notifier);
    await notifier.connect(_pg);
    for (var i = 0; i < 200; i++) {
      if (container.read(dbSessionProvider).sessionFor('pg').status ==
          DbSessionStatus.connected) {
        break;
      }
      await _pump(5);
    }
    expect(
      container.read(dbSessionProvider).sessionFor('pg').status,
      DbSessionStatus.connected,
    );

    // 基线:正常执行
    await notifier.runSql('SELECT 1 AS one');
    var sql = container.read(dbSessionProvider).sessionFor('pg').sql;
    expect(sql.error, isNull);
    expect(sql.output?.rows.first.first, 1);

    // 杀掉后台连接,给驱动一点时间处理 socket 关闭(isOpen 翻 false)
    await _killOtherBackends();
    await _pump(600);

    // 关键:再次执行应自动重连成功,而不是报错
    await notifier.runSql('SELECT 42 AS answer');
    sql = container.read(dbSessionProvider).sessionFor('pg').sql;
    expect(sql.error, isNull, reason: '应已自愈重连,不该有错误');
    expect(sql.output?.rows.first.first, 42);

    // 会话仍标记为已连接
    expect(
      container.read(dbSessionProvider).sessionFor('pg').status,
      DbSessionStatus.connected,
    );
  });
}
