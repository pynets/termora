import 'package:termora/core/l10n/app_l10n.dart';

/// 字节数人性化:1.5 GB / 320 MB / 12 KB。
String fmtBytes(num bytes) {
  final b = bytes.toDouble().abs();
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  var v = b;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  final text = v >= 100 || i == 0
      ? v.toStringAsFixed(0)
      : v >= 10
      ? v.toStringAsFixed(1)
      : v.toStringAsFixed(2);
  return '$text ${units[i]}';
}

/// 速率:字节/秒 → "1.2 MB/s";null(还没差分基线)显示占位。
String fmtRate(double? bytesPerSec) =>
    bytesPerSec == null ? '—' : '${fmtBytes(bytesPerSec)}/s';

/// 百分比,固定 1 位小数。
String fmtPercent(double v) => '${v.isFinite ? v.toStringAsFixed(1) : '—'}%';

/// 时长:"3 天 4 小时" / "2 小时 5 分" / "12 分钟"。
String fmtDuration(Duration d) {
  if (d.inDays > 0) {
    return tr2('{0} 天 {1} 小时', [d.inDays, d.inHours % 24]);
  }
  if (d.inHours > 0) {
    return tr2('{0} 小时 {1} 分', [d.inHours, d.inMinutes % 60]);
  }
  return tr2('{0} 分钟', [d.inMinutes]);
}
