/// 系统监控数据模型 —— 参考 bottom(btm) 的监控维度:
/// CPU / 内存 / 网络 / 磁盘 / 温度 / 电池 / 进程。
library;

/// 一次 CPU 采样:总使用率 + 每核使用率(0..100)。
class CpuSnapshot {
  const CpuSnapshot({required this.totalUsage, this.perCore = const []});

  /// 全机平均使用率(0..100)。
  final double totalUsage;

  /// 每核使用率(0..100);平台不支持时为空。
  final List<double> perCore;
}

/// 一次内存采样(字节)。
class MemorySnapshot {
  const MemorySnapshot({
    required this.totalBytes,
    required this.usedBytes,
    this.cacheBytes = 0,
    this.swapTotalBytes = 0,
    this.swapUsedBytes = 0,
  });

  final int totalBytes;
  final int usedBytes;

  /// 页缓存/缓冲(Linux:Buffers + Cached);平台拿不到时为 0。
  final int cacheBytes;

  final int swapTotalBytes;
  final int swapUsedBytes;

  double get usedPercent => totalBytes <= 0 ? 0 : usedBytes / totalBytes * 100;

  double get cachePercent =>
      totalBytes <= 0 ? 0 : cacheBytes / totalBytes * 100;

  double get swapPercent =>
      swapTotalBytes <= 0 ? 0 : swapUsedBytes / swapTotalBytes * 100;
}

/// 一次网络采样:开机以来累计字节 + 相对上次采样算出的速率。
class NetworkSnapshot {
  const NetworkSnapshot({
    required this.rxTotalBytes,
    required this.txTotalBytes,
    this.rxRate,
    this.txRate,
  });

  /// 所有非环回网卡累计接收/发送字节。
  final int rxTotalBytes;
  final int txTotalBytes;

  /// 每秒接收/发送字节;首个样本无前值,为 null。
  final double? rxRate;
  final double? txRate;
}

/// 一块挂载磁盘(分区)。
class DiskInfo {
  const DiskInfo({
    required this.device,
    required this.mountPoint,
    required this.totalBytes,
    required this.usedBytes,
    this.readRate,
    this.writeRate,
  });

  final String device;
  final String mountPoint;
  final int totalBytes;
  final int usedBytes;

  /// 每秒读/写字节;平台拿不到时为 null(macOS 只提供整机合计)。
  final double? readRate;
  final double? writeRate;

  int get freeBytes => totalBytes - usedBytes;

  double get usedPercent => totalBytes <= 0 ? 0 : usedBytes / totalBytes * 100;
}

/// 一块 GPU 的一次采样。
class GpuInfo {
  const GpuInfo({
    required this.label,
    required this.utilization,
    this.memUsedBytes,
    this.memTotalBytes,
  });

  final String label;

  /// 利用率(0..100)。
  final double utilization;

  /// 显存占用;Apple Silicon 统一内存下是 GPU 占用的系统内存,
  /// 无总量概念(memTotalBytes 为 null)。
  final int? memUsedBytes;
  final int? memTotalBytes;
}

/// 一个温度传感器读数。
class TempSensor {
  const TempSensor({required this.label, required this.celsius});

  final String label;
  final double celsius;
}

/// 电池充放状态。
enum BatteryState { charging, discharging, full, unknown }

/// 电池信息;无电池的机器为 null。
class BatteryInfo {
  const BatteryInfo({
    required this.percent,
    required this.state,
    this.timeRemaining,
    this.cycleCount,
    this.healthPercent,
  });

  /// 当前电量(0..100)。
  final double percent;

  final BatteryState state;

  /// 距充满/耗尽的剩余时间;未知为 null。
  final Duration? timeRemaining;

  /// 循环次数。
  final int? cycleCount;

  /// 健康度 = 当前最大容量 / 设计容量(0..100)。
  final double? healthPercent;
}

/// 一个进程。
class ProcInfo {
  const ProcInfo({
    required this.pid,
    required this.ppid,
    required this.user,
    required this.name,
    required this.command,
    required this.cpuPercent,
    required this.memPercent,
    required this.rssBytes,
    required this.state,
    this.readRate,
    this.writeRate,
    this.netRxRate,
    this.netTxRate,
    this.gpuMemBytes,
  });

  final int pid;
  final int ppid;
  final String user;

  /// 短名(可执行文件名)。
  final String name;

  /// 完整命令路径。
  final String command;

  final double cpuPercent;
  final double memPercent;
  final int rssBytes;

  /// 进程状态首字母(R 运行 / S 睡眠 / Z 僵尸 …);未知为空串。
  final String state;

  /// 每秒磁盘读/写字节(Linux `/proc/<pid>/io` 差分;
  /// 其他平台或无权限时为 null)。
  final double? readRate;
  final double? writeRate;

  /// 每秒网络收/发字节(macOS nettop 差分;其他平台为 null)。
  final double? netRxRate;
  final double? netTxRate;

  /// GPU 显存占用(Linux NVIDIA compute 进程;其他平台为 null)。
  final int? gpuMemBytes;
}

/// 一次完整采样(各维度拿不到时为 null / 空表,页面按可用性降级展示)。
class MonitorSnapshot {
  const MonitorSnapshot({
    required this.tMillis,
    this.cpu,
    this.memory,
    this.network,
    this.disks = const [],
    this.diskReadRate,
    this.diskWriteRate,
    this.gpus = const [],
    this.temps = const [],
    this.battery,
    this.processes = const [],
    this.loadAvg,
    this.uptime,
  });

  /// 采样时刻(epoch 毫秒)。
  final int tMillis;

  final CpuSnapshot? cpu;
  final MemorySnapshot? memory;
  final NetworkSnapshot? network;
  final List<DiskInfo> disks;

  /// 整机磁盘读/写速率(字节/秒);macOS 的 iostat 不分读写,
  /// 此时读速率承载合计值、写速率为 null。
  final double? diskReadRate;
  final double? diskWriteRate;

  final List<GpuInfo> gpus;
  final List<TempSensor> temps;
  final BatteryInfo? battery;
  final List<ProcInfo> processes;

  /// 1/5/15 分钟负载。
  final List<double>? loadAvg;

  /// 开机时长。
  final Duration? uptime;
}
