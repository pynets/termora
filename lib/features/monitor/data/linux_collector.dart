import 'dart:io';

import 'package:termora/features/monitor/data/platform_collector.dart';
import 'package:termora/features/monitor/domain/monitor_models.dart';

/// Linux 采集器 —— 指标基本都从 /proc、/sys 直读,开销极小:
/// - CPU:/proc/stat 每核 tick 差分;
/// - 内存:/proc/meminfo(MemAvailable 口径);
/// - 网络:/proc/net/dev 累计字节差分;
/// - 磁盘:容量 `df -kP`,I/O /proc/diskstats 扇区差分(512B/扇区);
/// - 温度:/sys/class/hwmon,回落 /sys/class/thermal;
/// - 电池:/sys/class/power_supply/BAT*;
/// - 进程:`ps`(与 macOS 同一解析)。
class LinuxCollector extends PlatformCollector {
  int _sampleIndex = 0;

  // 差分基线。
  List<(int, int)>? _prevCpuTicks; // 每核 (busy, total)
  int? _prevRx;
  int? _prevTx;
  Map<String, (int, int)>? _prevDiskSectors; // dev -> (read, written)
  int? _prevNetMillis;
  int? _prevDiskMillis;

  // 每进程 CPU tick 差分基线(pid -> utime+stime)。
  Map<int, int> _prevProcTicks = const {};

  // 每进程磁盘 I/O 差分基线(pid -> (read_bytes, write_bytes))。
  Map<int, (int, int)> _prevProcIo = const {};
  int? _prevProcMillis;

  /// USER_HZ,一般为 100;首轮用 getconf 校准。
  double? _clkTck;

  // 慢变化项缓存。
  List<DiskInfo> _disks = const [];
  BatteryInfo? _battery;

  /// nvidia-smi 不存在时置 false,之后不再反复尝试。
  bool _nvidiaAvailable = true;

  /// NVIDIA compute 进程的显存占用(pid -> 字节)。
  Map<int, int> _procGpuMem = const {};

  @override
  Future<MonitorSnapshot> sample() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final refreshSlow = _sampleIndex % 5 == 0;
    _sampleIndex++;

    final ps = await runForStdout('ps', const [
      'axo',
      'pid=,ppid=,user=,pcpu=,pmem=,rss=,state=,comm=',
    ]);
    if (refreshSlow) {
      final df = await runForStdout('df', const ['-kP']);
      if (df != null) _disks = parseDfOutput(df);
      _battery = _readBattery();
    }

    final diskRates = _sampleDiskRates(now);
    // 先刷 GPU(同时更新每进程显存表),再做进程增强。
    final gpus = await _readGpus();
    final processes = _attachGpuMem(
      await _withInstantCpu(ps == null ? const [] : parsePsOutput(ps), now),
    );

    return MonitorSnapshot(
      tMillis: now,
      cpu: _sampleCpu(),
      memory: _readMemory(),
      network: _sampleNetwork(now),
      disks: _attachDiskRates(diskRates),
      diskReadRate: diskRates.values.fold<double?>(
        null,
        (a, r) => (a ?? 0) + (r.$1 ?? 0),
      ),
      diskWriteRate: diskRates.values.fold<double?>(
        null,
        (a, r) => (a ?? 0) + (r.$2 ?? 0),
      ),
      gpus: gpus,
      temps: _readTemps(),
      battery: _battery,
      processes: processes,
      loadAvg: _readLoadAvg(),
      uptime: _readUptime(),
    );
  }

  String? _readFile(String path) {
    try {
      return File(path).readAsStringSync();
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------- CPU

  CpuSnapshot? _sampleCpu() {
    final stat = _readFile('/proc/stat');
    if (stat == null) return null;
    final ticks = <(int, int)>[];
    for (final line in stat.split('\n')) {
      // cpuN user nice system idle iowait irq softirq steal …
      if (!RegExp(r'^cpu\d+ ').hasMatch(line)) continue;
      final f = line
          .trim()
          .split(RegExp(r'\s+'))
          .skip(1)
          .map((v) => int.tryParse(v) ?? 0)
          .toList();
      if (f.length < 4) continue;
      final idle = f[3] + (f.length > 4 ? f[4] : 0); // idle + iowait
      final total = f.fold<int>(0, (a, b) => a + b);
      ticks.add((total - idle, total));
    }
    if (ticks.isEmpty) return null;
    final prev = _prevCpuTicks;
    _prevCpuTicks = ticks;
    if (prev == null || prev.length != ticks.length) {
      return const CpuSnapshot(totalUsage: 0);
    }
    final perCore = <double>[];
    for (var i = 0; i < ticks.length; i++) {
      final dBusy = ticks[i].$1 - prev[i].$1;
      final dTotal = ticks[i].$2 - prev[i].$2;
      perCore.add(dTotal <= 0 ? 0 : (dBusy / dTotal * 100).clamp(0, 100));
    }
    final avg = perCore.reduce((a, b) => a + b) / perCore.length;
    return CpuSnapshot(totalUsage: avg, perCore: perCore);
  }

  // ------------------------------------------------------------- Memory

  MemorySnapshot? _readMemory() {
    final meminfo = _readFile('/proc/meminfo');
    if (meminfo == null) return null;
    int kb(String key) =>
        int.tryParse(
          RegExp(
                '^$key:\\s+(\\d+)',
                multiLine: true,
              ).firstMatch(meminfo)?.group(1) ??
              '',
        ) ??
        0;
    final total = kb('MemTotal');
    if (total <= 0) return null;
    final available = kb('MemAvailable');
    final swapTotal = kb('SwapTotal');
    final swapFree = kb('SwapFree');
    return MemorySnapshot(
      totalBytes: total * 1024,
      usedBytes: (total - available) * 1024,
      cacheBytes: (kb('Buffers') + kb('Cached')) * 1024,
      swapTotalBytes: swapTotal * 1024,
      swapUsedBytes: (swapTotal - swapFree) * 1024,
    );
  }

  // ------------------------------------------- Per-process CPU / Disk IO

  /// 参考 bottom 补齐两个 ps 给不了的口径:
  /// - CPU:ps 的 pcpu 在 Linux 上是「自进程启动以来」的均值,改用
  ///   `/proc/<pid>/stat` 的 utime+stime tick 差分得到瞬时值;
  /// - 磁盘 I/O:`/proc/<pid>/io` 的 read_bytes/write_bytes 差分
  ///   (别的用户的进程通常无权限读,保持 null)。
  /// 首轮无基线时保留 ps 的原值。
  Future<List<ProcInfo>> _withInstantCpu(
    List<ProcInfo> procs,
    int nowMillis,
  ) async {
    if (procs.isEmpty) return procs;
    _clkTck ??=
        double.tryParse(
          (await runForStdout('getconf', const ['CLK_TCK']))?.trim() ?? '',
        ) ??
        100;

    final ticks = <int, int>{};
    final ioBytes = <int, (int, int)>{};
    for (final p in procs) {
      final stat = _readFile('/proc/${p.pid}/stat');
      if (stat != null) {
        // comm 含空格/括号,从最后一个 ')' 之后切:state ppid … utime stime
        final tail = stat.substring(stat.lastIndexOf(')') + 1).trim();
        final f = tail.split(RegExp(r'\s+'));
        if (f.length >= 13) {
          final utime = int.tryParse(f[11]);
          final stime = int.tryParse(f[12]);
          if (utime != null && stime != null) ticks[p.pid] = utime + stime;
        }
      }
      final io = _readFile('/proc/${p.pid}/io');
      if (io != null) {
        final read = int.tryParse(
          RegExp(
                r'^read_bytes:\s+(\d+)',
                multiLine: true,
              ).firstMatch(io)?.group(1) ??
              '',
        );
        final write = int.tryParse(
          RegExp(
                r'^write_bytes:\s+(\d+)',
                multiLine: true,
              ).firstMatch(io)?.group(1) ??
              '',
        );
        if (read != null && write != null) ioBytes[p.pid] = (read, write);
      }
    }

    final prevTicks = _prevProcTicks;
    final prevIo = _prevProcIo;
    final prevMillis = _prevProcMillis;
    _prevProcTicks = ticks;
    _prevProcIo = ioBytes;
    _prevProcMillis = nowMillis;
    if (prevMillis == null || nowMillis <= prevMillis) return procs;
    final dtSec = (nowMillis - prevMillis) / 1000;

    return [
      for (final p in procs)
        () {
          final tick = ticks[p.pid];
          final tickBefore = prevTicks[p.pid];
          final io = ioBytes[p.pid];
          final ioBefore = prevIo[p.pid];
          if ((tick == null || tickBefore == null) &&
              (io == null || ioBefore == null)) {
            return p;
          }
          final cpu = (tick != null && tickBefore != null)
              ? ((tick - tickBefore) / _clkTck! / dtSec * 100).clamp(
                  0.0,
                  double.infinity,
                )
              : p.cpuPercent;
          double? readRate;
          double? writeRate;
          if (io != null && ioBefore != null) {
            readRate = ((io.$1 - ioBefore.$1) / dtSec).clamp(
              0,
              double.infinity,
            );
            writeRate = ((io.$2 - ioBefore.$2) / dtSec).clamp(
              0,
              double.infinity,
            );
          }
          return ProcInfo(
            pid: p.pid,
            ppid: p.ppid,
            user: p.user,
            name: p.name,
            command: p.command,
            cpuPercent: cpu,
            memPercent: p.memPercent,
            rssBytes: p.rssBytes,
            state: p.state,
            readRate: readRate,
            writeRate: writeRate,
          );
        }(),
    ];
  }

  // ------------------------------------------------------------ Network

  NetworkSnapshot? _sampleNetwork(int nowMillis) {
    final dev = _readFile('/proc/net/dev');
    if (dev == null) return null;
    var rx = 0;
    var tx = 0;
    for (final line in dev.split('\n')) {
      final idx = line.indexOf(':');
      if (idx < 0) continue;
      final name = line.substring(0, idx).trim();
      if (name == 'lo') continue;
      final f = line.substring(idx + 1).trim().split(RegExp(r'\s+'));
      if (f.length < 16) continue;
      rx += int.tryParse(f[0]) ?? 0; // 接收字节
      tx += int.tryParse(f[8]) ?? 0; // 发送字节
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

  // -------------------------------------------------------------- Disks

  /// /proc/diskstats:设备名 + 读扇区(第 6 列)/ 写扇区(第 10 列)差分。
  Map<String, (double?, double?)> _sampleDiskRates(int nowMillis) {
    final stats = _readFile('/proc/diskstats');
    if (stats == null) return const {};
    final sectors = <String, (int, int)>{};
    for (final line in stats.split('\n')) {
      final f = line.trim().split(RegExp(r'\s+'));
      if (f.length < 14) continue;
      final name = f[2];
      // 跳过 loop/ram 与分区统计重复的父设备无从判断,全部收集,
      // 之后按 df 的设备名匹配。
      if (name.startsWith('loop') || name.startsWith('ram')) continue;
      sectors[name] = (int.tryParse(f[5]) ?? 0, int.tryParse(f[9]) ?? 0);
    }
    final rates = <String, (double?, double?)>{};
    final prev = _prevDiskSectors;
    final prevMillis = _prevDiskMillis;
    if (prev != null && prevMillis != null && nowMillis > prevMillis) {
      final dt = (nowMillis - prevMillis) / 1000;
      for (final e in sectors.entries) {
        final p = prev[e.key];
        if (p == null) continue;
        rates[e.key] = (
          ((e.value.$1 - p.$1) * 512 / dt).clamp(0, double.infinity),
          ((e.value.$2 - p.$2) * 512 / dt).clamp(0, double.infinity),
        );
      }
    }
    _prevDiskSectors = sectors;
    _prevDiskMillis = nowMillis;
    return rates;
  }

  List<DiskInfo> _attachDiskRates(Map<String, (double?, double?)> rates) {
    if (rates.isEmpty) return _disks;
    return [
      for (final d in _disks)
        () {
          final base = d.device.split('/').last;
          final r = rates[base];
          if (r == null) return d;
          return DiskInfo(
            device: d.device,
            mountPoint: d.mountPoint,
            totalBytes: d.totalBytes,
            usedBytes: d.usedBytes,
            readRate: r.$1,
            writeRate: r.$2,
          );
        }(),
    ];
  }

  // ---------------------------------------------------------------- GPU

  /// NVIDIA 走 nvidia-smi;没有则扫 AMD 的
  /// /sys/class/drm/card*/device/gpu_busy_percent。
  Future<List<GpuInfo>> _readGpus() async {
    if (_nvidiaAvailable) {
      final out = await runForStdout('nvidia-smi', const [
        '--query-gpu=name,utilization.gpu,memory.used,memory.total',
        '--format=csv,noheader,nounits',
      ], timeout: const Duration(seconds: 4));
      if (out == null) {
        _nvidiaAvailable = false;
      } else {
        final gpus = <GpuInfo>[];
        for (final line in out.split('\n')) {
          final f = line.split(',').map((v) => v.trim()).toList();
          if (f.length < 4) continue;
          final util = double.tryParse(f[1]);
          if (util == null) continue;
          gpus.add(
            GpuInfo(
              label: f[0],
              utilization: util.clamp(0, 100),
              memUsedBytes: (int.tryParse(f[2]) ?? 0) * 1024 * 1024,
              memTotalBytes: (int.tryParse(f[3]) ?? 0) * 1024 * 1024,
            ),
          );
        }
        if (gpus.isNotEmpty) {
          await _refreshProcGpuMem();
          return gpus;
        }
      }
    }

    final gpus = <GpuInfo>[];
    try {
      final drm = Directory('/sys/class/drm');
      if (!drm.existsSync()) return gpus;
      for (final dir in drm.listSync().whereType<Directory>()) {
        final name = dir.path.split('/').last;
        if (!RegExp(r'^card\d+$').hasMatch(name)) continue;
        final busy = double.tryParse(
          _readFile('${dir.path}/device/gpu_busy_percent')?.trim() ?? '',
        );
        if (busy == null) continue;
        final used = int.tryParse(
          _readFile('${dir.path}/device/mem_info_vram_used')?.trim() ?? '',
        );
        final total = int.tryParse(
          _readFile('${dir.path}/device/mem_info_vram_total')?.trim() ?? '',
        );
        gpus.add(
          GpuInfo(
            label: name,
            utilization: busy.clamp(0, 100),
            memUsedBytes: used,
            memTotalBytes: total,
          ),
        );
      }
    } catch (_) {
      // 无权限/无 GPU:忽略。
    }
    return gpus;
  }

  /// NVIDIA compute 进程的显存表(nvidia-smi query-compute-apps,MiB)。
  Future<void> _refreshProcGpuMem() async {
    final out = await runForStdout('nvidia-smi', const [
      '--query-compute-apps=pid,used_gpu_memory',
      '--format=csv,noheader,nounits',
    ], timeout: const Duration(seconds: 4));
    if (out == null) return;
    final mem = <int, int>{};
    for (final line in out.split('\n')) {
      final f = line.split(',').map((v) => v.trim()).toList();
      if (f.length < 2) continue;
      final pid = int.tryParse(f[0]);
      final mib = int.tryParse(f[1]);
      if (pid == null || mib == null) continue;
      mem[pid] = mib * 1024 * 1024;
    }
    _procGpuMem = mem;
  }

  /// 把每进程显存挂到进程列表上(仅 NVIDIA compute 进程有值)。
  List<ProcInfo> _attachGpuMem(List<ProcInfo> procs) {
    if (_procGpuMem.isEmpty) return procs;
    return [
      for (final p in procs)
        () {
          final mem = _procGpuMem[p.pid];
          if (mem == null) return p;
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
            readRate: p.readRate,
            writeRate: p.writeRate,
            gpuMemBytes: mem,
          );
        }(),
    ];
  }

  // -------------------------------------------------------- Temperature

  List<TempSensor> _readTemps() {
    final temps = <TempSensor>[];
    try {
      final hwmon = Directory('/sys/class/hwmon');
      if (hwmon.existsSync()) {
        for (final dir in hwmon.listSync().whereType<Directory>()) {
          final name =
              _readFile('${dir.path}/name')?.trim() ?? dir.path.split('/').last;
          for (final f in dir.listSync().whereType<File>()) {
            final base = f.path.split('/').last;
            final m = RegExp(r'^temp(\d+)_input$').firstMatch(base);
            if (m == null) continue;
            final raw = int.tryParse(_readFile(f.path)?.trim() ?? '');
            if (raw == null) continue;
            final label = _readFile(
              '${dir.path}/temp${m.group(1)}_label',
            )?.trim();
            temps.add(
              TempSensor(
                label: label == null || label.isEmpty ? name : '$name $label',
                celsius: raw / 1000,
              ),
            );
          }
        }
      }
      if (temps.isEmpty) {
        final thermal = Directory('/sys/class/thermal');
        if (thermal.existsSync()) {
          for (final dir in thermal.listSync().whereType<Directory>()) {
            if (!dir.path.split('/').last.startsWith('thermal_zone')) {
              continue;
            }
            final raw = int.tryParse(
              _readFile('${dir.path}/temp')?.trim() ?? '',
            );
            if (raw == null) continue;
            final type = _readFile('${dir.path}/type')?.trim();
            temps.add(
              TempSensor(
                label: type ?? dir.path.split('/').last,
                celsius: raw / 1000,
              ),
            );
          }
        }
      }
    } catch (_) {
      // 传感器目录不可读:忽略,页面显示空态。
    }
    temps.sort((a, b) => a.label.compareTo(b.label));
    return temps;
  }

  // ------------------------------------------------------------ Battery

  BatteryInfo? _readBattery() {
    try {
      final root = Directory('/sys/class/power_supply');
      if (!root.existsSync()) return null;
      for (final dir in root.listSync().whereType<Directory>()) {
        if (!dir.path.split('/').last.startsWith('BAT')) continue;
        final capacity = double.tryParse(
          _readFile('${dir.path}/capacity')?.trim() ?? '',
        );
        if (capacity == null) continue;
        final status = _readFile('${dir.path}/status')?.trim().toLowerCase();
        final state = switch (status) {
          'charging' => BatteryState.charging,
          'discharging' => BatteryState.discharging,
          'full' => BatteryState.full,
          _ => BatteryState.unknown,
        };
        final cycles = int.tryParse(
          _readFile('${dir.path}/cycle_count')?.trim() ?? '',
        );
        double? health;
        final full =
            int.tryParse(_readFile('${dir.path}/energy_full')?.trim() ?? '') ??
            int.tryParse(_readFile('${dir.path}/charge_full')?.trim() ?? '');
        final design =
            int.tryParse(
              _readFile('${dir.path}/energy_full_design')?.trim() ?? '',
            ) ??
            int.tryParse(
              _readFile('${dir.path}/charge_full_design')?.trim() ?? '',
            );
        if (full != null && design != null && design > 0) {
          health = full / design * 100;
        }
        return BatteryInfo(
          percent: capacity,
          state: state,
          cycleCount: cycles,
          healthPercent: health,
        );
      }
    } catch (_) {
      // 忽略。
    }
    return null;
  }

  // -------------------------------------------------------------- Misc

  List<double>? _readLoadAvg() {
    final content = _readFile('/proc/loadavg');
    if (content == null) return null;
    final f = content.trim().split(RegExp(r'\s+'));
    if (f.length < 3) return null;
    final values = [for (var i = 0; i < 3; i++) double.tryParse(f[i]) ?? 0];
    return values;
  }

  Duration? _readUptime() {
    final content = _readFile('/proc/uptime');
    if (content == null) return null;
    final sec = double.tryParse(content.trim().split(' ').first);
    if (sec == null) return null;
    return Duration(seconds: sec.round());
  }
}
