// DbTransferTask / DbTransferSchedule 纯逻辑:序列化往返 + 调度到期计算
import 'package:flutter_test/flutter_test.dart';
import 'package:termora/features/database/domain/db_etl.dart';
import 'package:termora/features/database/domain/db_models.dart';
import 'package:termora/features/database/domain/db_transfer_task.dart';

void main() {
  group('DbTransferSchedule.nextRunMs', () {
    test('manual 永不到期', () {
      const s = DbTransferSchedule();
      expect(s.nextRunMs(null, 1000), isNull);
    });

    test('interval:从未跑过立即到期,跑过则加间隔', () {
      const s = DbTransferSchedule(
        kind: DbScheduleKind.interval,
        intervalMinutes: 30,
      );
      expect(s.nextRunMs(null, 1000), 1000); // 立即
      expect(s.nextRunMs(1000, 1000), 1000 + 30 * 60000);
    });

    test('dailyAt:今天已过则顺延明天', () {
      const s = DbTransferSchedule(
        kind: DbScheduleKind.dailyAt,
        dailyHour: 3,
        dailyMinute: 0,
      );
      final today230 = DateTime(2026, 7, 11, 2, 30).millisecondsSinceEpoch;
      final today3 = DateTime(2026, 7, 11, 3, 0).millisecondsSinceEpoch;
      expect(s.nextRunMs(null, today230), today3); // 今天 03:00

      final today330 = DateTime(2026, 7, 11, 3, 30).millisecondsSinceEpoch;
      final tomorrow3 = DateTime(2026, 7, 12, 3, 0).millisecondsSinceEpoch;
      expect(s.nextRunMs(null, today330), tomorrow3); // 顺延明天
    });

    test('dailyAt:跑过一次后顺延次日,tick 可判定到期', () {
      const s = DbTransferSchedule(
        kind: DbScheduleKind.dailyAt,
        dailyHour: 3,
      );
      // 昨天 03:00 跑过;今天 03:00:30 → 今天 03:00 到期(<= now)
      final ranYesterday = DateTime(2026, 7, 10, 3, 0).millisecondsSinceEpoch;
      final now = DateTime(2026, 7, 11, 3, 0, 30).millisecondsSinceEpoch;
      final due = s.nextRunMs(ranYesterday, now)!;
      expect(due, DateTime(2026, 7, 11, 3, 0).millisecondsSinceEpoch);
      expect(due <= now, isTrue); // tick 判定到期

      // 刚在今天 03:00:30 跑完 → 下次是明天 03:00(未到期)
      final due2 = s.nextRunMs(now, now)!;
      expect(due2, DateTime(2026, 7, 12, 3, 0).millisecondsSinceEpoch);
      expect(due2 > now, isTrue);
    });

    test('interval:到期判定', () {
      const s = DbTransferSchedule(
        kind: DbScheduleKind.interval,
        intervalMinutes: 10,
      );
      final ran = DateTime(2026, 7, 11, 3, 0).millisecondsSinceEpoch;
      final now = DateTime(2026, 7, 11, 3, 11).millisecondsSinceEpoch;
      expect(s.nextRunMs(ran, now)! <= now, isTrue); // 已过 10 分钟
      final now2 = DateTime(2026, 7, 11, 3, 5).millisecondsSinceEpoch;
      expect(s.nextRunMs(ran, now2)! > now2, isTrue); // 才 5 分钟,未到
    });

    test('summary 文案', () {
      expect(const DbTransferSchedule().summary, '手动');
      expect(
        const DbTransferSchedule(
          kind: DbScheduleKind.interval,
          intervalMinutes: 15,
        ).summary,
        '每 15 分钟',
      );
      expect(
        const DbTransferSchedule(
          kind: DbScheduleKind.dailyAt,
          dailyHour: 9,
          dailyMinute: 5,
        ).summary,
        '每天 09:05',
      );
    });
  });

  test('DbTransferTask 序列化往返(含 ETL 规则/调度)', () {
    final task = DbTransferTask(
      id: 't1',
      name: 'prod→test 脱敏',
      mode: DbTransferMode.migrate,
      sourceConnId: 'src',
      targetConnId: 'dst',
      wholeDatabase: false,
      schema: 'public',
      tables: ['users', 'orders'],
      etlRules: const {
        'users': DbEtlTableRule(
          table: 'users',
          targetTable: 'members',
          rowFilters: [
            DbColumnFilter(
              column: 'id',
              op: DbFilterOp.inList,
              value: '1,2,3',
            ),
          ],
          columns: {
            'phone': DbEtlColumnRule(
              column: 'phone',
              transform: DbEtlTransform.mask,
              param: '3,4',
            ),
            'secret': DbEtlColumnRule(column: 'secret', include: false),
          },
        ),
      },
      overwrite: true,
      includeData: true,
      schedule: const DbTransferSchedule(
        kind: DbScheduleKind.dailyAt,
        dailyHour: 2,
        dailyMinute: 30,
      ),
      lastRunAtMs: 123456,
      lastRunOk: true,
      lastRunMessage: '3 张表 / 5 行',
    );

    final restored = DbTransferTask.fromJson(task.toJson());
    expect(restored.id, 't1');
    expect(restored.name, 'prod→test 脱敏');
    expect(restored.mode, DbTransferMode.migrate);
    expect(restored.sourceConnId, 'src');
    expect(restored.targetConnId, 'dst');
    expect(restored.schema, 'public');
    expect(restored.tables, ['users', 'orders']);
    expect(restored.overwrite, isTrue);
    expect(restored.schedule.kind, DbScheduleKind.dailyAt);
    expect(restored.schedule.dailyHour, 2);
    expect(restored.schedule.dailyMinute, 30);
    expect(restored.lastRunAtMs, 123456);
    expect(restored.lastRunOk, isTrue);
    expect(restored.lastRunMessage, '3 张表 / 5 行');

    // ETL 规则深度还原
    final rule = restored.etlRules['users']!;
    expect(rule.targetTableName, 'members');
    expect(rule.rowFilters.single.op, DbFilterOp.inList);
    expect(rule.rowFilters.single.value, '1,2,3');
    expect(rule.columns['phone']!.transform, DbEtlTransform.mask);
    expect(rule.columns['phone']!.param, '3,4');
    expect(rule.columns['secret']!.include, isFalse);
  });

  test('export 任务:方言 + 整库标志', () {
    final task = DbTransferTask(
      id: 'e1',
      name: '每日备份',
      mode: DbTransferMode.export,
      sourceConnId: 'src',
      wholeDatabase: true,
      exportDialectName: DbEngine.postgres.name,
      filePath: '/tmp/backup.sql',
    );
    final restored = DbTransferTask.fromJson(task.toJson());
    expect(restored.mode, DbTransferMode.export);
    expect(restored.wholeDatabase, isTrue);
    expect(restored.exportDialect, DbEngine.postgres);
    expect(restored.filePath, '/tmp/backup.sql');
    expect(restored.schema, isNull);
  });

  test('多 schema 任务:schemaTables 往返', () {
    const task = DbTransferTask(
      id: 'm1',
      name: '多库迁移',
      mode: DbTransferMode.migrate,
      sourceConnId: 'src',
      targetConnId: 'dst',
      schemaTables: {
        'public': ['users', 'orders'],
        'hub': [], // 空 = 全部表
      },
    );
    final restored = DbTransferTask.fromJson(task.toJson());
    expect(restored.schemaTables['public'], ['users', 'orders']);
    expect(restored.schemaTables['hub'], isEmpty);
    expect(restored.schemaTables.keys, containsAll(['public', 'hub']));
  });
}
