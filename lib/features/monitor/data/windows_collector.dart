import 'dart:convert';

import 'package:termora/features/monitor/data/platform_collector.dart';
import 'package:termora/features/monitor/domain/monitor_models.dart';

/// Windows 采集器 —— 每轮跑一次 PowerShell(CIM 性能计数器)拿 JSON。
/// 单轮开销较大(约 1~2 秒),控制器在 Windows 上会自动放宽采样间隔。
/// 温度(MSAcpi_ThermalZoneTemperature)多数机型不支持,拿不到即空。
class WindowsCollector extends PlatformCollector {
  // 网络累计字节差分基线。
  int? _prevRx;
  int? _prevTx;
  int? _prevNetMillis;

  /// 上轮采样还没结束时直接复用旧快照,避免 PowerShell 堆积。
  bool _sampling = false;
  MonitorSnapshot? _last;

  static const _script = r'''
$ErrorActionPreference='SilentlyContinue'
$os = Get-CimInstance Win32_OperatingSystem
$perf = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor
$cores = @($perf | Where-Object {$_.Name -ne '_Total'} | Sort-Object {[int]$_.Name} | ForEach-Object {[double]$_.PercentProcessorTime})
$total = [double]($perf | Where-Object {$_.Name -eq '_Total'} | Select-Object -First 1).PercentProcessorTime
$disks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {@{dev=$_.DeviceID; size=[long]$_.Size; free=[long]$_.FreeSpace}})
$netRaw = Get-CimInstance Win32_PerfRawData_Tcpip_NetworkInterface
$rx = [long](($netRaw | Measure-Object -Property BytesReceivedPersec -Sum).Sum)
$tx = [long](($netRaw | Measure-Object -Property BytesSentPersec -Sum).Sum)
$procs = @(Get-CimInstance Win32_PerfFormattedData_PerfProc_Process | Where-Object {$_.Name -ne '_Total' -and $_.Name -ne 'Idle'} | ForEach-Object {@{name=$_.Name; pid=[int]$_.IDProcess; ppid=[int]$_.CreatingProcessID; cpu=[double]$_.PercentProcessorTime; ws=[long]$_.WorkingSet}})
$bat = Get-CimInstance Win32_Battery | Select-Object -First 1
$batInfo = $null
if ($bat) { $batInfo = @{percent=[double]$bat.EstimatedChargeRemaining; status=[int]$bat.BatteryStatus} }
$temps = @()
try {
  $temps = @(Get-CimInstance -Namespace root/wmi MSAcpi_ThermalZoneTemperature | ForEach-Object {@{label=$_.InstanceName; c=[math]::Round($_.CurrentTemperature/10 - 273.15, 1)}})
} catch {}
$page = Get-CimInstance Win32_PageFileUsage | Select-Object -First 1
@{
  cpuTotal=$total; cpuCores=$cores;
  memTotalKb=[long]$os.TotalVisibleMemorySize; memFreeKb=[long]$os.FreePhysicalMemory;
  swapTotalMb=$(if($page){[long]$page.AllocatedBaseSize}else{0}); swapUsedMb=$(if($page){[long]$page.CurrentUsage}else{0});
  uptimeSec=[long]((Get-Date) - $os.LastBootUpTime).TotalSeconds;
  disks=$disks; rx=$rx; tx=$tx; procs=$procs; battery=$batInfo; temps=$temps
} | ConvertTo-Json -Depth 4 -Compress
''';

  @override
  Future<MonitorSnapshot> sample() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_sampling && _last != null) return _last!;
    _sampling = true;
    try {
      final out = await runForStdout('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        _script,
      ], timeout: const Duration(seconds: 20));
      if (out == null) return _last ?? MonitorSnapshot(tMillis: now);
      final data = jsonDecode(out.trim());
      if (data is! Map<String, dynamic>) {
        return _last ?? MonitorSnapshot(tMillis: now);
      }
      final snapshot = _buildSnapshot(data, now);
      _last = snapshot;
      return snapshot;
    } catch (_) {
      return _last ?? MonitorSnapshot(tMillis: now);
    } finally {
      _sampling = false;
    }
  }

  MonitorSnapshot _buildSnapshot(Map<String, dynamic> data, int now) {
    // ConvertTo-Json 会把单元素数组折叠成对象,统一包回列表。
    List<dynamic> asList(dynamic v) => v == null
        ? const []
        : v is List
        ? v
        : [v];
    double num0(dynamic v) => v is num ? v.toDouble() : 0;
    int int0(dynamic v) => v is num ? v.toInt() : 0;

    final perCore = [for (final v in asList(data['cpuCores'])) num0(v)];
    final cpu = CpuSnapshot(
      totalUsage: num0(data['cpuTotal']).clamp(0, 100),
      perCore: [for (final v in perCore) v.clamp(0.0, 100.0)],
    );

    final memTotal = int0(data['memTotalKb']) * 1024;
    final memory = memTotal <= 0
        ? null
        : MemorySnapshot(
            totalBytes: memTotal,
            usedBytes: memTotal - int0(data['memFreeKb']) * 1024,
            swapTotalBytes: int0(data['swapTotalMb']) * 1024 * 1024,
            swapUsedBytes: int0(data['swapUsedMb']) * 1024 * 1024,
          );

    final rx = int0(data['rx']);
    final tx = int0(data['tx']);
    double? rxRate;
    double? txRate;
    final prevMillis = _prevNetMillis;
    if (prevMillis != null && now > prevMillis) {
      final dt = (now - prevMillis) / 1000;
      rxRate = ((rx - _prevRx!) / dt).clamp(0, double.infinity);
      txRate = ((tx - _prevTx!) / dt).clamp(0, double.infinity);
    }
    _prevRx = rx;
    _prevTx = tx;
    _prevNetMillis = now;

    final disks = <DiskInfo>[
      for (final d in asList(data['disks']))
        if (d is Map && int0(d['size']) > 0)
          DiskInfo(
            device: '${d['dev']}',
            mountPoint: '${d['dev']}\\',
            totalBytes: int0(d['size']),
            usedBytes: int0(d['size']) - int0(d['free']),
          ),
    ];

    // PercentProcessorTime 以单核为 100%,换算成全机口径。
    final coreCount = perCore.isEmpty ? 1 : perCore.length;
    final processes = <ProcInfo>[
      for (final p in asList(data['procs']))
        if (p is Map && int0(p['pid']) > 0)
          ProcInfo(
            pid: int0(p['pid']),
            ppid: int0(p['ppid']),
            user: '',
            name: '${p['name']}',
            command: '${p['name']}',
            cpuPercent: num0(p['cpu']) / coreCount,
            memPercent: memTotal <= 0 ? 0 : int0(p['ws']) / memTotal * 100,
            rssBytes: int0(p['ws']),
            state: '',
          ),
    ];

    BatteryInfo? battery;
    final bat = data['battery'];
    if (bat is Map) {
      // BatteryStatus:1=放电 2=接电源,其余状态归入充电/未知。
      final status = int0(bat['status']);
      battery = BatteryInfo(
        percent: num0(bat['percent']),
        state: switch (status) {
          1 => BatteryState.discharging,
          2 => BatteryState.full,
          6 || 7 || 8 || 9 => BatteryState.charging,
          _ => BatteryState.unknown,
        },
      );
    }

    return MonitorSnapshot(
      tMillis: now,
      cpu: cpu,
      memory: memory,
      network: NetworkSnapshot(
        rxTotalBytes: rx,
        txTotalBytes: tx,
        rxRate: rxRate,
        txRate: txRate,
      ),
      disks: disks,
      temps: [
        for (final t in asList(data['temps']))
          if (t is Map && t['c'] is num)
            TempSensor(label: '${t['label']}', celsius: num0(t['c'])),
      ],
      battery: battery,
      processes: processes,
      uptime: Duration(seconds: int0(data['uptimeSec'])),
    );
  }
}
