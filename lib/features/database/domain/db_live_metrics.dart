/// 一次实时采样(每 N 秒一条)。累积计数器 [counter] 用于算速率;
/// [ratePerSec] 是相对上一条样本算出的每秒事务/查询数。
class DbLiveSample {
  const DbLiveSample({
    required this.tMillis,
    this.activeConnections,
    this.cacheHit,
    this.dbBytes = 0,
    this.counter,
    this.ratePerSec,
  });

  /// 采样时刻(毫秒)
  final int tMillis;

  /// 活动连接数(pg)/ 正在执行的查询数(ch)
  final int? activeConnections;

  /// 缓存命中率 0..1(pg)
  final double? cacheHit;

  /// 数据库大小(字节)
  final int dbBytes;

  /// 累积事务(pg:xact_commit+rollback)/ 查询(ch:Query 事件)计数,算速率用
  final int? counter;

  /// 每秒事务/查询(由相邻样本的 [counter] 差 / 时间差得出)
  final double? ratePerSec;
}

/// 定长滚动窗口的实时序列(概览实时图用)
class DbLiveSeries {
  DbLiveSeries({this.capacity = 90, List<DbLiveSample>? samples})
    : samples = samples ?? const [];

  final int capacity;
  final List<DbLiveSample> samples;

  bool get isEmpty => samples.isEmpty;
  bool get isNotEmpty => samples.isNotEmpty;
  int get length => samples.length;
  DbLiveSample? get latest => samples.isEmpty ? null : samples.last;

  /// 追加一条,超出容量丢最旧
  DbLiveSeries appended(DbLiveSample s) {
    final next = [...samples, s];
    if (next.length > capacity) {
      next.removeRange(0, next.length - capacity);
    }
    return DbLiveSeries(capacity: capacity, samples: next);
  }

  /// 取某字段的时间序列(null 表示该点无值,图上画成断点)
  List<double?> field(double? Function(DbLiveSample s) selector) => [
    for (final s in samples) selector(s),
  ];
}
