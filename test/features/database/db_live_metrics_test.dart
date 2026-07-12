// 实时采样 sampleLive:SQLite 无条件 + PG/CH 冒烟(需本地临时实例)
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:termora/features/database/data/db_metrics_service.dart';
import 'package:termora/features/database/data/db_service.dart';
import 'package:termora/features/database/domain/db_live_metrics.dart';
import 'package:termora/features/database/domain/db_models.dart';

void main() {
  group('DbLiveSeries 滚动窗口', () {
    test('超容量丢最旧 + latest', () {
      var series = DbLiveSeries(capacity: 3);
      for (var i = 0; i < 5; i++) {
        series = series.appended(DbLiveSample(tMillis: i, dbBytes: i));
      }
      expect(series.length, 3);
      expect(series.samples.first.dbBytes, 2); // 0,1 被丢
      expect(series.latest!.dbBytes, 4);
      expect(series.field((s) => s.dbBytes.toDouble()), [2.0, 3.0, 4.0]);
    });
  });

  test('sqlite 采样:文件大小,无速率', () async {
    final dir = Directory.systemTemp.createTempSync('termora_live');
    final path = '${dir.path}/x.db';
    final db = sqlite3.open(path);
    db.execute('CREATE TABLE t (id INTEGER)');
    db.execute('INSERT INTO t VALUES (1),(2),(3)');
    db.close();

    final config = DbConnectionConfig(
      id: 'l',
      name: 'l',
      engine: DbEngine.sqlite,
      database: path,
    );
    final conn = await DbService.open(config);
    try {
      final s = await DbMetricsService.sampleLive(conn, config);
      expect(s.dbBytes, greaterThan(0));
      expect(s.counter, isNull);
      expect(s.ratePerSec, isNull);
      expect(s.activeConnections, isNull);
    } finally {
      await conn.close();
    }
    dir.deleteSync(recursive: true);
  });
}
