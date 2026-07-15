import 'package:termora/features/database/domain/db_etl.dart';
import 'package:termora/features/database/domain/db_models.dart';

/// 传输模式:导出 SQL 脚本 / 导入 SQL 脚本 / 迁移到其它连接 /
/// 导出便携归档(dump)/ 从归档导入(store)。
/// (定义在 domain,供任务模型与 UI 共用)
enum DbTransferMode { export, importScript, migrate, exportDump, importDump }

/// 调度方式
enum DbScheduleKind {
  manual, // 仅手动
  interval, // 每 N 分钟
  dailyAt, // 每天定点
}

/// 任务调度设置(免 cron 依赖:间隔 / 每日定点)
class DbTransferSchedule {
  const DbTransferSchedule({
    this.kind = DbScheduleKind.manual,
    this.intervalMinutes = 60,
    this.dailyHour = 3,
    this.dailyMinute = 0,
  });

  final DbScheduleKind kind;

  /// interval 模式:每多少分钟跑一次(下限 1)
  final int intervalMinutes;

  /// dailyAt 模式:每天几点几分(本地时间)
  final int dailyHour;
  final int dailyMinute;

  bool get isActive => kind != DbScheduleKind.manual;

  /// 人类可读描述(UI 用)
  String get summary => switch (kind) {
    DbScheduleKind.manual => '手动',
    DbScheduleKind.interval => '每 $intervalMinutes 分钟',
    DbScheduleKind.dailyAt =>
      '每天 ${dailyHour.toString().padLeft(2, '0')}:'
          '${dailyMinute.toString().padLeft(2, '0')}',
  };

  /// 给定「上次运行时间」(毫秒,null=从未),算出下次应运行的时间(毫秒);
  /// manual 返回 null。[nowMs] 由调用方传入(避免在纯逻辑里读时钟)。
  int? nextRunMs(int? lastRunMs, int nowMs) {
    switch (kind) {
      case DbScheduleKind.manual:
        return null;
      case DbScheduleKind.interval:
        final step = (intervalMinutes < 1 ? 1 : intervalMinutes) * 60000;
        if (lastRunMs == null) return nowMs; // 从未跑过 → 立即到期
        return lastRunMs + step;
      case DbScheduleKind.dailyAt:
        // 锚定「上次运行」(没跑过则锚当前),返回其后最近的每日定点。
        // 这样调度 tick 用 `nextRunMs <= now` 判断到期才成立:
        // 跑过一次后锚点≈定点,顺延到次日;没跑过则今天定点(未过)或明天。
        final anchor = DateTime.fromMillisecondsSinceEpoch(lastRunMs ?? nowMs);
        var next = DateTime(
          anchor.year,
          anchor.month,
          anchor.day,
          dailyHour,
          dailyMinute,
        );
        if (!next.isAfter(anchor)) {
          next = next.add(const Duration(days: 1));
        }
        return next.millisecondsSinceEpoch;
    }
  }

  DbTransferSchedule copyWith({
    DbScheduleKind? kind,
    int? intervalMinutes,
    int? dailyHour,
    int? dailyMinute,
  }) => DbTransferSchedule(
    kind: kind ?? this.kind,
    intervalMinutes: intervalMinutes ?? this.intervalMinutes,
    dailyHour: dailyHour ?? this.dailyHour,
    dailyMinute: dailyMinute ?? this.dailyMinute,
  );

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'intervalMinutes': intervalMinutes,
    'dailyHour': dailyHour,
    'dailyMinute': dailyMinute,
  };

  factory DbTransferSchedule.fromJson(Map<String, dynamic> json) =>
      DbTransferSchedule(
        kind: DbScheduleKind.values.firstWhere(
          (e) => e.name == json['kind'],
          orElse: () => DbScheduleKind.manual,
        ),
        intervalMinutes: (json['intervalMinutes'] as num?)?.toInt() ?? 60,
        dailyHour: (json['dailyHour'] as num?)?.toInt() ?? 3,
        dailyMinute: (json['dailyMinute'] as num?)?.toInt() ?? 0,
      );
}

/// 一个已保存的传输任务(导出/导入/迁移的完整配置,可重跑、可调度)。
/// 连接以 id 引用(运行时按 id 查当前连接配置,避免快照过期)。
class DbTransferTask {
  const DbTransferTask({
    required this.id,
    required this.name,
    required this.mode,
    required this.sourceConnId,
    this.targetConnId,
    this.filePath,
    this.exportDialectName,
    this.wholeDatabase = false,
    this.schema,
    this.tables = const [],
    this.schemaTables = const {},
    this.etlRules = const {},
    this.overwrite = true,
    this.includeData = true,
    this.schedule = const DbTransferSchedule(),
    this.lastRunAtMs,
    this.lastRunOk,
    this.lastRunMessage,
  });

  final String id;
  final String name;
  final DbTransferMode mode;

  /// 源连接 id(export/migrate 是源;import 是执行脚本的目标连接)
  final String sourceConnId;

  /// 迁移目标连接 id
  final String? targetConnId;

  /// export:输出脚本路径;import:待执行脚本路径
  final String? filePath;

  /// export 目标方言(DbEngine.name);null → 用源引擎
  final String? exportDialectName;

  final bool wholeDatabase;

  /// 单 schema 模式:schema + 选中的 tables
  final String? schema;
  final List<String> tables;

  /// 多 schema 模式:schema → 选中的表(空列表 = 该 schema 全部表)
  final Map<String, List<String>> schemaTables;

  final Map<String, DbEtlTableRule> etlRules;
  final bool overwrite;
  final bool includeData;

  final DbTransferSchedule schedule;

  /// 上次运行(毫秒 / 成功与否 / 摘要或错误)
  final int? lastRunAtMs;
  final bool? lastRunOk;
  final String? lastRunMessage;

  DbEngine? get exportDialect =>
      exportDialectName == null ? null : DbEngine.fromName(exportDialectName);

  DbTransferTask copyWith({
    String? name,
    DbTransferSchedule? schedule,
    int? lastRunAtMs,
    bool? lastRunOk,
    String? lastRunMessage,
  }) => DbTransferTask(
    id: id,
    name: name ?? this.name,
    mode: mode,
    sourceConnId: sourceConnId,
    targetConnId: targetConnId,
    filePath: filePath,
    exportDialectName: exportDialectName,
    wholeDatabase: wholeDatabase,
    schema: schema,
    tables: tables,
    schemaTables: schemaTables,
    etlRules: etlRules,
    overwrite: overwrite,
    includeData: includeData,
    schedule: schedule ?? this.schedule,
    lastRunAtMs: lastRunAtMs ?? this.lastRunAtMs,
    lastRunOk: lastRunOk ?? this.lastRunOk,
    lastRunMessage: lastRunMessage ?? this.lastRunMessage,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'mode': mode.name,
    'sourceConnId': sourceConnId,
    if (targetConnId != null) 'targetConnId': targetConnId,
    if (filePath != null) 'filePath': filePath,
    if (exportDialectName != null) 'exportDialect': exportDialectName,
    'wholeDatabase': wholeDatabase,
    if (schema != null) 'schema': schema,
    if (tables.isNotEmpty) 'tables': tables,
    if (schemaTables.isNotEmpty) 'schemaTables': schemaTables,
    if (etlRules.isNotEmpty)
      'etlRules': {for (final e in etlRules.entries) e.key: e.value.toJson()},
    'overwrite': overwrite,
    'includeData': includeData,
    'schedule': schedule.toJson(),
    if (lastRunAtMs != null) 'lastRunAtMs': lastRunAtMs,
    if (lastRunOk != null) 'lastRunOk': lastRunOk,
    if (lastRunMessage != null) 'lastRunMessage': lastRunMessage,
  };

  factory DbTransferTask.fromJson(Map<String, dynamic> json) => DbTransferTask(
    id: json['id'] as String,
    name: json['name'] as String? ?? '未命名任务',
    mode: DbTransferMode.values.firstWhere(
      (e) => e.name == json['mode'],
      orElse: () => DbTransferMode.migrate,
    ),
    sourceConnId: json['sourceConnId'] as String? ?? '',
    targetConnId: json['targetConnId'] as String?,
    filePath: json['filePath'] as String?,
    exportDialectName: json['exportDialect'] as String?,
    wholeDatabase: json['wholeDatabase'] as bool? ?? false,
    schema: json['schema'] as String?,
    tables: [
      for (final t in (json['tables'] as List<dynamic>? ?? [])) t as String,
    ],
    schemaTables: {
      for (final e
          in (json['schemaTables'] as Map<String, dynamic>? ?? {}).entries)
        e.key: [for (final t in (e.value as List<dynamic>)) t as String],
    },
    etlRules: {
      for (final e in (json['etlRules'] as Map<String, dynamic>? ?? {}).entries)
        e.key: DbEtlTableRule.fromJson(e.value as Map<String, dynamic>),
    },
    overwrite: json['overwrite'] as bool? ?? true,
    includeData: json['includeData'] as bool? ?? true,
    schedule: json['schedule'] == null
        ? const DbTransferSchedule()
        : DbTransferSchedule.fromJson(json['schedule'] as Map<String, dynamic>),
    lastRunAtMs: (json['lastRunAtMs'] as num?)?.toInt(),
    lastRunOk: json['lastRunOk'] as bool?,
    lastRunMessage: json['lastRunMessage'] as String?,
  );
}
