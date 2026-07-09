import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// 文件选择器辅助工具
/// 统一管理文件对话框的默认目录，避免默认打开到程序安装位置
class FilePickerHelper {
  FilePickerHelper._();

  /// 记住上次选择的目录（全局共享）
  static String? _lastDirectory;

  /// 获取上次目录，如果没有则返回用户桌面目录
  static Future<String?> getInitialDirectory() async {
    if (_lastDirectory != null && Directory(_lastDirectory!).existsSync()) {
      return _lastDirectory;
    }
    // 默认使用用户桌面目录
    try {
      final home = Platform.environment['HOME'];
      if (home != null) {
        final desktop = Directory('$home/Desktop');
        if (desktop.existsSync()) {
          return desktop.path;
        }
        // 如果桌面目录不存在，使用文档目录
        final docs = await getApplicationDocumentsDirectory();
        return docs.path;
      }
    } catch (_) {}
    return null;
  }

  /// 更新上次选择的目录
  static void updateLastDirectory(String? filePath) {
    if (filePath != null && filePath.isNotEmpty) {
      final dir = File(filePath).parent.path;
      if (Directory(dir).existsSync()) {
        _lastDirectory = dir;
      }
    }
  }

  /// 从目录路径直接更新
  static void updateLastDirectoryFromPath(String? dirPath) {
    if (dirPath != null &&
        dirPath.isNotEmpty &&
        Directory(dirPath).existsSync()) {
      _lastDirectory = dirPath;
    }
  }
}
