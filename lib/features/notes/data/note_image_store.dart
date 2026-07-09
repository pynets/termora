import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 笔记图片资源 — 插入的图片统一复制到 notes/assets/ 下,
/// 笔记里引用落地后的绝对路径,原图挪走/删除也不影响笔记显示。
class NoteImageStore {
  NoteImageStore._();

  static Directory? _directoryOverride;

  /// 测试注入:覆盖资源根目录
  static set debugDirectoryOverride(Directory? dir) {
    _directoryOverride = dir;
  }

  static Future<Directory> _assetsDir() async {
    final base =
        _directoryOverride ?? await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'notes', 'assets'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  static String _uniqueName(String extension) =>
      'img_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}$extension';

  /// 把外部图片复制进资源目录,返回落地后的绝对路径
  static Future<String> importImage(String sourcePath) async {
    final dir = await _assetsDir();
    final ext = p.extension(sourcePath).toLowerCase();
    final dest = p.join(dir.path, _uniqueName(ext.isEmpty ? '.png' : ext));
    File(sourcePath).copySync(dest);
    return dest;
  }

  /// 图片字节落盘(粘贴/截图),返回绝对路径
  static Future<String> saveBytes(List<int> bytes) async {
    final dir = await _assetsDir();
    final dest = p.join(dir.path, _uniqueName('.png'));
    File(dest).writeAsBytesSync(bytes);
    return dest;
  }

  /// 读系统剪贴板里的图片并落盘;剪贴板无图片返回 null。
  /// macOS 用 osascript 取 PNG(免原生通道);其他平台暂不支持。
  static Future<String?> saveClipboardImage() async {
    if (!Platform.isMacOS) return null;
    final dir = await _assetsDir();
    final dest = p.join(dir.path, _uniqueName('.png'));
    try {
      await Process.run('osascript', [
        '-e', 'try',
        '-e', 'set imgData to the clipboard as «class PNGf»',
        '-e',
        'set f to open for access POSIX file "$dest" with write permission',
        '-e', 'write imgData to f',
        '-e', 'close access f',
        '-e', 'end try',
      ]);
      final file = File(dest);
      if (file.existsSync() && file.lengthSync() > 0) return dest;
      if (file.existsSync()) file.deleteSync();
      return null;
    } catch (_) {
      return null;
    }
  }
}
