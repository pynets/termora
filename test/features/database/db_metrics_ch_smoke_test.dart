@Tags(['smoke'])
library;

// DbMetricsService(ClickHouse)冒烟 — 需要本地 8124 临时 CH + 库 metricdb(表 ev)。
//   flutter test --run-skipped --tags smoke test/features/database/db_metrics_ch_smoke_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:termora/features/database/data/db_metrics_service.dart';
import 'package:termora/features/database/domain/db_models.dart';

const _ch = DbConnectionConfig(
  id: 'chm',
  name: 'chm',
  engine: DbEngine.clickhouse,
  host: '127.0.0.1',
  port: 8124,
  database: 'metricdb',
  username: 'default',
  password: '',
);

void main() {
  test('ch 指标:大小/计数/topTables/uptime', () async {
    final m = await DbMetricsService.load(_ch);

    expect(m.engine, DbEngine.clickhouse);
    expect(m.version, isNotEmpty);
    expect(m.tableCount, greaterThanOrEqualTo(1));
    expect(m.approxRows, greaterThanOrEqualTo(1500));
    expect(m.databaseBytes, greaterThan(0));

    final ev = m.topTables.where((t) => t.table == 'ev').toList();
    expect(ev, isNotEmpty);
    expect(ev.first.rows, greaterThanOrEqualTo(1500));
    expect(ev.first.bytes, greaterThan(0));

    expect(m.uptime, isNotNull);
    expect(m.schemaCount, greaterThanOrEqualTo(1));
  });
}
