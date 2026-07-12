import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'package:termora/features/monitor/data/platform_collector.dart';
import 'package:termora/features/monitor/domain/monitor_models.dart';

/// macOS 采集器。
///
/// - CPU:mach `host_processor_info`(FFI)每核 tick 差分;失败降级为
///   `ps` 汇总的近似值。
/// - 内存:`vm_stat` + `sysctl hw.memsize / vm.swapusage`,口径对齐
///   活动监视器(active + wired + compressed)。
/// - 网络:`netstat -ibn` 的 Link 行累计字节差分。
/// - 磁盘:容量 `df -kP`;I/O `iostat -Id` 累计 MB 差分(不分读写,
///   只有整机合计)。
/// - 温度:非 root 拿不到 SMC,仅提供电池温度(ioreg)。
/// - 电池:`pmset -g batt` + `ioreg -rn AppleSmartBattery`。
class MacosCollector extends PlatformCollector {
  final _cpuFfi = _MacosCpuTicks();

  /// ps 降级方案的上一轮结果(算不出时沿用)。
  double _fallbackCpu = 0;

  int _sampleIndex = 0;

  // 网络与磁盘 I/O 差分基线。
  int? _prevRx;
  int? _prevTx;
  int? _prevNetMillis;
  double? _prevIoMb;
  int? _prevIoMillis;

  // 慢变化项缓存(每 5 轮刷新一次)。
  List<DiskInfo> _disks = const [];
  BatteryInfo? _battery;
  List<TempSensor> _temps = const [];

  /// GPU 名称(Apple Silicon 与 CPU 同芯片,取芯片型号;取不到用 GPU)。
  String? _gpuLabel;

  // 每进程网络(nettop 差分):较重(约 0.2s),最快每 5 秒刷新一次。
  static const _procNetRefreshMillis = 5000;
  bool _nettopAvailable = true;
  int _lastNettopMillis = 0;
  Map<int, (int, int)> _prevProcNet = const {};
  int? _prevProcNetMillis;
  Map<int, (double, double)> _procNetRates = const {};

  @override
  Future<MonitorSnapshot> sample() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final refreshSlow = _sampleIndex % 5 == 0;
    final refreshProcNet =
        _nettopAvailable && now - _lastNettopMillis >= _procNetRefreshMillis;
    if (refreshProcNet) _lastNettopMillis = now;
    _sampleIndex++;

    // 全部子进程并发跑,按名取值(不再用脆弱的下标)。
    final fVmStat = runForStdout('vm_stat', const []);
    final fNetstat = runForStdout('netstat', const ['-ibn']);
    final fPs = runForStdout('ps', const [
      'axo',
      'pid=,ppid=,user=,pcpu=,pmem=,rss=,state=,comm=',
    ]);
    final fSysctl = runForStdout('sysctl', const [
      '-n',
      'hw.memsize',
      'vm.swapusage',
      'vm.loadavg',
      'kern.boottime',
      'machdep.cpu.brand_string',
    ]);
    final fIostat = runForStdout('iostat', const ['-Id']);
    final fIoregGpu = runForStdout('ioreg', const [
      '-rc',
      'IOAccelerator',
      '-d',
      '1',
    ]);
    final fNettop = refreshProcNet
        ? runForStdout('nettop', const [
            '-P',
            '-x',
            '-L',
            '1',
            '-J',
            'bytes_in,bytes_out',
          ])
        : Future<String?>.value(null);
    final fDf = refreshSlow
        ? runForStdout('df', const ['-kP'])
        : Future<String?>.value(null);
    final fPmset = refreshSlow
        ? runForStdout('pmset', const ['-g', 'batt'])
        : Future<String?>.value(null);
    final fIoregBat = refreshSlow
        ? runForStdout('ioreg', const ['-rn', 'AppleSmartBattery'])
        : Future<String?>.value(null);

    final vmStat = await fVmStat;
    final netstat = await fNetstat;
    final ps = await fPs;
    final sysctl = await fSysctl;
    final iostat = await fIostat;
    final ioregGpu = await fIoregGpu;
    if (refreshSlow) {
      final df = await fDf;
      if (df != null) _disks = parseDfOutput(df);
      _parseBattery(await fPmset, await fIoregBat);
    }
    if (refreshProcNet) {
      final nettop = await fNettop;
      if (nettop == null) {
        _nettopAvailable = false;
      } else {
        _updateProcNetRates(nettop, now);
      }
    }

    var processes = ps == null ? const <ProcInfo>[] : parsePsOutput(ps);
    processes = _attachProcNet(processes);
    final sysctlLines = sysctl?.split('\n') ?? const [];
    if (sysctlLines.length > 4 && sysctlLines[4].trim().isNotEmpty) {
      _gpuLabel ??= sysctlLines[4].trim();
    }

    final io = _parseIostat(iostat, now);

    return MonitorSnapshot(
      tMillis: now,
      cpu: _sampleCpu(processes),
      memory: _parseMemory(vmStat, sysctlLines),
      network: _parseNetwork(netstat, now),
      disks: _disks,
      diskReadRate: io,
      diskWriteRate: null,
      gpus: _parseGpus(ioregGpu),
      temps: _temps,
      battery: _battery,
      processes: processes,
      loadAvg: _parseLoadAvg(sysctlLines),
      uptime: _parseUptime(sysctlLines, now),
    );
  }

  // -------------------------------------------------- Per-process network

  /// `nettop -P -x -L 1 -J bytes_in,bytes_out`:每行
  /// `进程名.pid,累计接收,累计发送,`,差分得每进程网络速率。
  void _updateProcNetRates(String nettop, int nowMillis) {
    final cur = <int, (int, int)>{};
    for (final line in nettop.split('\n')) {
      final parts = line.split(',');
      if (parts.length < 3) continue;
      final dot = parts[0].lastIndexOf('.');
      if (dot < 0) continue;
      final pid = int.tryParse(parts[0].substring(dot + 1));
      final rx = int.tryParse(parts[1]);
      final tx = int.tryParse(parts[2]);
      if (pid == null || rx == null || tx == null) continue;
      cur[pid] = (rx, tx);
    }
    final prev = _prevProcNet;
    final prevMillis = _prevProcNetMillis;
    _prevProcNet = cur;
    _prevProcNetMillis = nowMillis;
    if (prevMillis == null || nowMillis <= prevMillis) return;
    final dt = (nowMillis - prevMillis) / 1000;
    _procNetRates = {
      for (final e in cur.entries)
        if (prev[e.key] != null)
          e.key: (
            ((e.value.$1 - prev[e.key]!.$1) / dt).clamp(0, double.infinity),
            ((e.value.$2 - prev[e.key]!.$2) / dt).clamp(0, double.infinity),
          ),
    };
  }

  /// 把缓存的每进程网络速率挂到进程列表上(两次 nettop 之间沿用)。
  List<ProcInfo> _attachProcNet(List<ProcInfo> procs) {
    if (_procNetRates.isEmpty) return procs;
    return [
      for (final p in procs)
        () {
          final r = _procNetRates[p.pid];
          if (r == null) return p;
          return ProcInfo(
            pid: p.pid,
            ppid: p.ppid,
            user: p.user,
            name: p.name,
            command: p.command,
            cpuPercent: p.cpuPercent,
            memPercent: p.memPercent,
            rssBytes: p.rssBytes,
            state: p.state,
            netRxRate: r.$1,
            netTxRate: r.$2,
          );
        }(),
    ];
  }

  // ---------------------------------------------------------------- CPU

  CpuSnapshot _sampleCpu(List<ProcInfo> processes) {
    final perCore = _cpuFfi.sampleUsage();
    if (perCore != null && perCore.isNotEmpty) {
      final avg = perCore.reduce((a, b) => a + b) / perCore.length;
      return CpuSnapshot(totalUsage: avg, perCore: perCore);
    }
    // 降级:各进程 pcpu 之和 / 核数(近似,无每核明细)。
    final cores = _cpuFfi.coreCount ?? 1;
    if (processes.isNotEmpty) {
      final sum = processes.fold<double>(0, (a, p) => a + p.cpuPercent);
      _fallbackCpu = (sum / cores).clamp(0, 100);
    }
    return CpuSnapshot(totalUsage: _fallbackCpu);
  }

  // ------------------------------------------------------------- Memory

  MemorySnapshot? _parseMemory(String? vmStat, List<String> sysctlLines) {
    if (vmStat == null || sysctlLines.isEmpty) return null;
    final total = int.tryParse(sysctlLines[0].trim());
    if (total == null) return null;

    final pageSize =
        int.tryParse(
          RegExp(r'page size of (\d+) bytes').firstMatch(vmStat)?.group(1) ??
              '',
        ) ??
        16384;
    int pages(String label) =>
        int.tryParse(
          RegExp('$label:\\s+(\\d+)').firstMatch(vmStat)?.group(1) ?? '',
        ) ??
        0;
    final used =
        (pages('Pages active') +
            pages('Pages wired down') +
            pages('Pages occupied by compressor')) *
        pageSize;

    var swapTotal = 0;
    var swapUsed = 0;
    if (sysctlLines.length > 1) {
      final m = RegExp(
        r'total = ([\d.]+)M\s+used = ([\d.]+)M',
      ).firstMatch(sysctlLines[1]);
      if (m != null) {
        swapTotal = ((double.tryParse(m.group(1)!) ?? 0) * 1024 * 1024).round();
        swapUsed = ((double.tryParse(m.group(2)!) ?? 0) * 1024 * 1024).round();
      }
    }
    return MemorySnapshot(
      totalBytes: total,
      usedBytes: used,
      swapTotalBytes: swapTotal,
      swapUsedBytes: swapUsed,
    );
  }

  // ------------------------------------------------------------ Network

  NetworkSnapshot? _parseNetwork(String? netstat, int nowMillis) {
    if (netstat == null) return null;
    var rx = 0;
    var tx = 0;
    for (final line in netstat.split('\n')) {
      final parts = line.trim().split(RegExp(r'\s+'));
      // 只统计 <Link#N> 行(每网卡一条);Address 列可能缺失,从行尾定位:
      // … Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll
      if (parts.length < 10 || !parts[2].startsWith('<Link#')) continue;
      if (parts[0].startsWith('lo')) continue;
      rx += int.tryParse(parts[parts.length - 5]) ?? 0;
      tx += int.tryParse(parts[parts.length - 2]) ?? 0;
    }
    double? rxRate;
    double? txRate;
    final prevMillis = _prevNetMillis;
    if (prevMillis != null && nowMillis > prevMillis) {
      final dt = (nowMillis - prevMillis) / 1000;
      rxRate = ((rx - _prevRx!) / dt).clamp(0, double.infinity);
      txRate = ((tx - _prevTx!) / dt).clamp(0, double.infinity);
    }
    _prevRx = rx;
    _prevTx = tx;
    _prevNetMillis = nowMillis;
    return NetworkSnapshot(
      rxTotalBytes: rx,
      txTotalBytes: tx,
      rxRate: rxRate,
      txRate: txRate,
    );
  }

  // ------------------------------------------------------------ Disk IO

  /// `iostat -Id`:三行输出,第三行是各盘 (KB/t, xfrs, MB) 三元组;
  /// MB 为开机以来累计传输量(读写合计),差分得整机字节速率。
  double? _parseIostat(String? iostat, int nowMillis) {
    if (iostat == null) return null;
    final lines = iostat.split('\n').where((l) => l.trim().isNotEmpty).toList();
    if (lines.length < 3) return null;
    final values = lines[2].trim().split(RegExp(r'\s+'));
    var totalMb = 0.0;
    for (var i = 2; i < values.length; i += 3) {
      totalMb += double.tryParse(values[i]) ?? 0;
    }
    double? rate;
    final prevMillis = _prevIoMillis;
    if (prevMillis != null && nowMillis > prevMillis && _prevIoMb != null) {
      final dt = (nowMillis - prevMillis) / 1000;
      rate = ((totalMb - _prevIoMb!) * 1024 * 1024 / dt).clamp(
        0,
        double.infinity,
      );
    }
    _prevIoMb = totalMb;
    _prevIoMillis = nowMillis;
    return rate;
  }

  // ---------------------------------------------------------------- GPU

  /// `ioreg -rc IOAccelerator -d 1`:每块加速器一个 `+-o` 块,
  /// PerformanceStatistics 里有 "Device Utilization %" 与
  /// "In use system memory"(统一内存下 GPU 占用的系统内存)。
  List<GpuInfo> _parseGpus(String? ioreg) {
    if (ioreg == null) return const [];
    final gpus = <GpuInfo>[];
    final blocks = ioreg.split('+-o ');
    var index = 0;
    for (final block in blocks) {
      final util = double.tryParse(
        RegExp(r'"Device Utilization %"=(\d+)').firstMatch(block)?.group(1) ??
            '',
      );
      if (util == null) continue;
      final memUsed = int.tryParse(
        RegExp(r'"In use system memory"=(\d+)').firstMatch(block)?.group(1) ??
            '',
      );
      final base = _gpuLabel ?? 'GPU';
      gpus.add(
        GpuInfo(
          label: index == 0 ? base : '$base #$index',
          utilization: util.clamp(0, 100),
          memUsedBytes: memUsed,
        ),
      );
      index++;
    }
    return gpus;
  }

  // ------------------------------------------------------------ Battery

  void _parseBattery(String? pmset, String? ioreg) {
    if (pmset == null || !pmset.contains('InternalBattery')) {
      _battery = null;
      _temps = const [];
      return;
    }
    final percent =
        double.tryParse(RegExp(r'(\d+)%').firstMatch(pmset)?.group(1) ?? '') ??
        0;
    var state = BatteryState.unknown;
    if (pmset.contains('discharging')) {
      state = BatteryState.discharging;
    } else if (pmset.contains('charging')) {
      state = BatteryState.charging;
    } else if (pmset.contains('charged')) {
      state = BatteryState.full;
    }
    Duration? remaining;
    final timeMatch = RegExp(r'(\d+):(\d+) remaining').firstMatch(pmset);
    if (timeMatch != null) {
      remaining = Duration(
        hours: int.parse(timeMatch.group(1)!),
        minutes: int.parse(timeMatch.group(2)!),
      );
    }

    int? cycleCount;
    double? health;
    final temps = <TempSensor>[];
    if (ioreg != null) {
      int? key(String name) => int.tryParse(
        RegExp('"$name" = (\\d+)').firstMatch(ioreg)?.group(1) ?? '',
      );
      cycleCount = key('CycleCount');
      final rawMax = key('AppleRawMaxCapacity');
      final design = key('DesignCapacity');
      if (rawMax != null && design != null && design > 0) {
        health = rawMax / design * 100;
      }
      final temp = key('Temperature');
      if (temp != null && temp > 0) {
        temps.add(TempSensor(label: '电池', celsius: temp / 100));
      }
    }
    _battery = BatteryInfo(
      percent: percent,
      state: state,
      timeRemaining: remaining,
      cycleCount: cycleCount,
      healthPercent: health,
    );
    _temps = temps;
  }

  // -------------------------------------------------------------- Misc

  List<double>? _parseLoadAvg(List<String> sysctlLines) {
    if (sysctlLines.length < 3) return null;
    final nums = RegExp(r'[\d.]+')
        .allMatches(sysctlLines[2])
        .map((m) => double.tryParse(m.group(0)!) ?? 0)
        .toList();
    return nums.length >= 3 ? nums.sublist(0, 3) : null;
  }

  Duration? _parseUptime(List<String> sysctlLines, int nowMillis) {
    if (sysctlLines.length < 4) return null;
    final sec = int.tryParse(
      RegExp(r'sec = (\d+)').firstMatch(sysctlLines[3])?.group(1) ?? '',
    );
    if (sec == null) return null;
    return Duration(milliseconds: nowMillis - sec * 1000);
  }
}

// ==================================================================== FFI

const int _processorCpuLoadInfo = 2; // PROCESSOR_CPU_LOAD_INFO
const int _cpuStateUser = 0;
const int _cpuStateSystem = 1;
const int _cpuStateIdle = 2;
const int _cpuStateNice = 3;
const int _cpuStateMax = 4;

typedef _HostProcessorInfoNative =
    Int32 Function(
      Uint32 host,
      Int32 flavor,
      Pointer<Uint32> outCount,
      Pointer<Pointer<Int32>> outInfo,
      Pointer<Uint32> outInfoCnt,
    );
typedef _HostProcessorInfoDart =
    int Function(
      int host,
      int flavor,
      Pointer<Uint32> outCount,
      Pointer<Pointer<Int32>> outInfo,
      Pointer<Uint32> outInfoCnt,
    );
typedef _VmDeallocateNative =
    Int32 Function(Uint32 task, IntPtr addr, IntPtr size);
typedef _VmDeallocateDart = int Function(int task, int addr, int size);

/// mach `host_processor_info` 的每核 CPU tick 采样(差分算使用率)。
/// 初始化或调用失败即永久降级(返回 null),不影响其余指标。
class _MacosCpuTicks {
  _MacosCpuTicks() {
    try {
      final lib = DynamicLibrary.process();
      _hostProcessorInfo = lib
          .lookupFunction<_HostProcessorInfoNative, _HostProcessorInfoDart>(
            'host_processor_info',
          );
      _machHostSelf = lib.lookupFunction<Uint32 Function(), int Function()>(
        'mach_host_self',
      );
      _vmDeallocate = lib
          .lookupFunction<_VmDeallocateNative, _VmDeallocateDart>(
            'vm_deallocate',
          );
      _machTaskSelf = lib.lookup<Uint32>('mach_task_self_').value;
      _available = true;
    } catch (_) {
      _available = false;
    }
  }

  late final _HostProcessorInfoDart _hostProcessorInfo;
  late final int Function() _machHostSelf;
  late final _VmDeallocateDart _vmDeallocate;
  late final int _machTaskSelf;
  bool _available = false;

  /// 上一轮每核 (busy, total) tick。
  List<(int, int)>? _prevTicks;

  int? get coreCount => _prevTicks?.length;

  /// 返回每核使用率(0..100);首轮无差分基线返回 null。
  List<double>? sampleUsage() {
    final ticks = _readTicks();
    if (ticks == null) return null;
    final prev = _prevTicks;
    _prevTicks = ticks;
    if (prev == null || prev.length != ticks.length) return null;
    final usage = <double>[];
    for (var i = 0; i < ticks.length; i++) {
      final dBusy = ticks[i].$1 - prev[i].$1;
      final dTotal = ticks[i].$2 - prev[i].$2;
      usage.add(dTotal <= 0 ? 0 : (dBusy / dTotal * 100).clamp(0, 100));
    }
    return usage;
  }

  List<(int, int)>? _readTicks() {
    if (!_available) return null;
    final outCount = calloc<Uint32>();
    final outInfo = calloc<Pointer<Int32>>();
    final outInfoCnt = calloc<Uint32>();
    try {
      final kr = _hostProcessorInfo(
        _machHostSelf(),
        _processorCpuLoadInfo,
        outCount,
        outInfo,
        outInfoCnt,
      );
      if (kr != 0) {
        _available = false;
        return null;
      }
      final cores = outCount.value;
      final info = outInfo.value;
      final ticks = <(int, int)>[];
      for (var i = 0; i < cores; i++) {
        final base = i * _cpuStateMax;
        final user = info[base + _cpuStateUser];
        final system = info[base + _cpuStateSystem];
        final idle = info[base + _cpuStateIdle];
        final nice = info[base + _cpuStateNice];
        final busy = user + system + nice;
        ticks.add((busy, busy + idle));
      }
      _vmDeallocate(_machTaskSelf, info.address, outInfoCnt.value * 4);
      return ticks;
    } catch (_) {
      _available = false;
      return null;
    } finally {
      calloc.free(outCount);
      calloc.free(outInfo);
      calloc.free(outInfoCnt);
    }
  }
}
