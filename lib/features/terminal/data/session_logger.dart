import 'dart:io';
import 'package:termora/core/l10n/app_l10n.dart';

/// 会话日志录制(WindTerm 式 session logging):把终端输出实时落盘成
/// 可读的纯文本日志。每个会话一个实例,互不干扰。
///
/// 写入前剥掉 ANSI 转义序列,得到便于审计/检索的纯文本;不改动屏幕渲染。
class SessionLogger {
  IOSink? _sink;
  String? _path;

  bool get isActive => _sink != null;
  String? get path => _path;

  /// CSI / OSC / 单字符转义 / 其它 C1,统一剥掉,只留可见文本。
  static final RegExp _ansi = RegExp(
    r'\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)' // OSC ... BEL / ST
    r'|\x1b[@-Z\\-_]' // 双字符 ESC
    r'|\x1b\[[0-9;?]*[ -/]*[@-~]' // CSI
    r'|\x1b[()][0-9A-Za-z]' // 字符集选择
    r'|[\x00-\x08\x0b\x0c\x0e-\x1f]', // 其它控制字符(保留 \t \n \r)
  );

  static String stripAnsi(String raw) => raw
      .replaceAll(_ansi, '')
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n');

  /// 开始录制。返回落盘路径;失败抛异常。
  /// [dir] 为空则落到 ~/termora-logs。
  Future<String> start({
    required String sessionLabel,
    required DateTime now,
    String? dir,
  }) async {
    await stop();
    final base = dir ?? '${_home()}/termora-logs';
    await Directory(base).create(recursive: true);
    final safe = sessionLabel.replaceAll(RegExp(r'[^\w.\-]+'), '_');
    final stamp = _stamp(now);
    final file = File('$base/${safe.isEmpty ? 'session' : safe}-$stamp.log');
    final sink = file.openWrite(mode: FileMode.append);
    sink.writeln(tr2('===== termora 会话日志 · {0}', [sessionLabel]));
    sink.writeln(tr2('===== 开始 {0}', [now.toLocal()]));
    sink.writeln('');
    _sink = sink;
    _path = file.path;
    return file.path;
  }

  /// 追加一段原始输出(内部剥转义)。
  void write(String raw) {
    final sink = _sink;
    if (sink == null || raw.isEmpty) return;
    final text = stripAnsi(raw);
    if (text.isEmpty) return;
    sink.write(text);
  }

  /// 停止并冲刷落盘。
  Future<void> stop() async {
    final sink = _sink;
    _sink = null;
    _path = null;
    if (sink == null) return;
    try {
      sink.writeln('');
      await sink.flush();
      await sink.close();
    } catch (_) {}
  }

  static String _home() =>
      Platform.environment['HOME'] ?? Directory.current.path;

  static String _stamp(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}'
        '-${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }
}
