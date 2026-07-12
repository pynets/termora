@Tags(['smoke'])
library;

// sampleLive 冒烟(PG 55432 + CH 8124):两次采样算出速率/连接/缓存。
//   flutter test --run-skipped --tags smoke test/features/database/db_live_pg_ch_smoke_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:termora/features/database/data/db_metrics_service.dart';
import 'package:termora/features/database/data/db_service.dart';
import 'package:termora/features/database/domain/db_models.dart';

const _pg = DbConnectionConfig(
  id: 'pgl',
  name: 'pgl',
  host: 'localhost',
  port: 55432,
  database: 'postgres',
  username: 'postgres',
  password: '',
);

const _ch = DbConnectionConfig(
  id: 'chl',
  name: 'chl',
  engine: DbEngine.clickhouse,
  host: '127.0.0.1',
  port: 8124,
  database: 'default',
  username: 'default',
  password: '',
);

void main() {
  test('pg 实时:连接/缓存/事务速率', () async {
    final conn = await DbService.open(_pg);
    try {
      final s1 = await DbMetricsService.sampleLive(conn, _pg);
      expect(s1.activeConnections, greaterThanOrEqualTo(1));
      expect(s1.dbBytes, greaterThan(0));
      expect(s1.counter, isNotNull);
      expect(s1.ratePerSec, isNull); // 首采无前值

      // 制造一些事务(自动提交,每条 = 一个事务)
      for (var i = 0; i < 40; i++) {
        await DbService.runSql(conn, 'SELECT $i');
      }
      // pg_stat_database 每后端最多每秒刷一次;强制立刻刷,避免竞态
      await DbService.runSql(conn, 'SELECT pg_stat_force_next_flush()');
      await Future<void>.delayed(const Duration(milliseconds: 150));

      final s2 = await DbMetricsService.sampleLive(conn, _pg, previous: s1);
      expect(s2.counter!, greaterThan(s1.counter!));
      expect(s2.ratePerSec, isNotNull);
      expect(s2.ratePerSec!, greaterThan(0));
      expect(s2.cacheHit, isNotNull);
      expect(s2.cacheHit!, inInclusiveRange(0, 1));
    } finally {
      await conn.close();
    }
  });

  test('ch 实时:查询速率/大小', () async {
    final conn = await DbService.open(_ch);
    try {
      final s1 = await DbMetricsService.sampleLive(conn, _ch);
      expect(s1.counter, isNotNull); // 累积 Query 事件
      expect(s1.activeConnections, isNotNull);

      for (var i = 0; i < 20; i++) {
        await DbService.runSql(conn, 'SELECT $i');
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));

      final s2 = await DbMetricsService.sampleLive(conn, _ch, previous: s1);
      expect(s2.counter!, greaterThan(s1.counter!));
      expect(s2.ratePerSec, isNotNull);
      expect(s2.ratePerSec!, greaterThan(0));
    } finally {
      await conn.close();
    }
  });
}
