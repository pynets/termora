import 'package:termora/features/database/domain/db_models.dart';

/// 单张表的体量(概览图表用)
class DbTableMetric {
  const DbTableMetric({
    required this.schema,
    required this.table,
    this.bytes = 0,
    this.rows = 0,
    this.isView = false,
  });

  final String schema;
  final String table;
  final int bytes;
  final int rows;
  final bool isView;

  String get qualified => schema.isEmpty ? table : '$schema.$table';
}

/// 单个 schema 的体量(多 schema 时的分布图用)
class DbSchemaMetric {
  const DbSchemaMetric({
    required this.schema,
    this.tableCount = 0,
    this.bytes = 0,
  });

  final String schema;
  final int tableCount;
  final int bytes;
}

/// 一个数据库的整体指标(概览面板)
class DbMetrics {
  const DbMetrics({
    required this.engine,
    this.version,
    this.databaseBytes = 0,
    this.schemaCount = 0,
    this.tableCount = 0,
    this.viewCount = 0,
    this.approxRows = 0,
    this.activeConnections,
    this.maxConnections,
    this.cacheHitRatio,
    this.uptime,
    this.topTables = const [],
    this.schemas = const [],
  });

  final DbEngine engine;
  final String? version;

  /// 数据库总大小(字节;SQLite 为文件大小)
  final int databaseBytes;
  final int schemaCount;
  final int tableCount;
  final int viewCount;

  /// 全库行数估计(各表估计求和)
  final int approxRows;

  /// PostgreSQL:活动连接 / 上限
  final int? activeConnections;
  final int? maxConnections;

  /// PostgreSQL:缓存命中率(0..1)
  final double? cacheHitRatio;

  /// 运行时长(拿得到才有)
  final Duration? uptime;

  /// 体量最大的若干表(降序)
  final List<DbTableMetric> topTables;

  /// 各 schema 分布(多 schema 时)
  final List<DbSchemaMetric> schemas;
}

/// 字节 → 人类可读(概览各处共用)
String prettyBytes(int bytes) {
  if (bytes <= 0) return '—';
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  var size = bytes.toDouble();
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  final text = unit == 0 ? size.toStringAsFixed(0) : size.toStringAsFixed(1);
  return '$text ${units[unit]}';
}

/// 大数字 → 紧凑(1.2k / 3.4M)
String prettyCount(int n) {
  if (n < 1000) return '$n';
  if (n < 1000000) return '${(n / 1000).toStringAsFixed(1)}k';
  if (n < 1000000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  return '${(n / 1000000000).toStringAsFixed(1)}B';
}

/// 时长 → 紧凑(3d 4h / 5h 12m / 8m)
String prettyDuration(Duration d) {
  final days = d.inDays;
  final hours = d.inHours % 24;
  final minutes = d.inMinutes % 60;
  if (days > 0) return '${days}d ${hours}h';
  if (hours > 0) return '${hours}h ${minutes}m';
  return '${minutes}m';
}
