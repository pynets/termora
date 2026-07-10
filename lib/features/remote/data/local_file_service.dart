import 'dart:io';

import 'package:termora/features/remote/domain/sftp_entry.dart';
import 'package:termora/core/l10n/app_l10n.dart';

class LocalFileException implements Exception {
  const LocalFileException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 本地文件面板的数据源 — 复用 [SftpEntry] 作为条目模型,
/// 让本地栏与远端栏共用同一套行组件和排序规则。
class LocalFileService {
  LocalFileService._();

  static String homeDirectory() => Platform.environment['HOME'] ?? '/';

  static Future<List<SftpEntry>> list(String path) async {
    final List<FileSystemEntity> children;
    try {
      children = await Directory(path).list(followLinks: false).toList();
    } on FileSystemException catch (error) {
      throw LocalFileException(_friendly(error));
    }
    final now = DateTime.now();
    final entries = <SftpEntry>[];
    for (final child in children) {
      final name = child.path.split('/').last;
      final isLink = child is Link;
      var isDir = child is Directory;
      if (isLink) {
        // 链接按指向判定目录与否(展示上仍是链接图标,与远端一致)
        isDir = await FileSystemEntity.type(child.path) ==
            FileSystemEntityType.directory;
      }
      var size = 0;
      var modified = '';
      try {
        final stat = await child.stat();
        size = stat.size;
        modified = _formatTime(stat.modified, now);
      } catch (_) {}
      entries.add(
        SftpEntry(
          name: name,
          isDir: isDir,
          isLink: isLink,
          size: isDir ? 0 : size,
          modified: modified,
        ),
      );
    }
    entries.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  /// ls 风格:当年只显示月日时分,往年显示完整日期
  static String _formatTime(DateTime t, DateTime now) {
    String two(int v) => v.toString().padLeft(2, '0');
    if (t.year == now.year) {
      return '${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
    }
    return '${t.year}-${two(t.month)}-${two(t.day)}';
  }

  static Future<void> rename(String from, String to) async {
    try {
      switch (FileSystemEntity.typeSync(from, followLinks: false)) {
        case FileSystemEntityType.directory:
          await Directory(from).rename(to);
        case FileSystemEntityType.link:
          await Link(from).rename(to);
        default:
          await File(from).rename(to);
      }
    } on FileSystemException catch (error) {
      throw LocalFileException(_friendly(error));
    }
  }

  static Future<void> remove(String path) async {
    try {
      if (FileSystemEntity.typeSync(path, followLinks: false) ==
          FileSystemEntityType.link) {
        await Link(path).delete();
      } else {
        await File(path).delete();
      }
    } on FileSystemException catch (error) {
      throw LocalFileException(_friendly(error));
    }
  }

  /// 只删空目录,与远端 rmdir 语义一致(防误伤)
  static Future<void> removeDir(String path) async {
    try {
      await Directory(path).delete();
    } on FileSystemException catch (error) {
      throw LocalFileException(_friendly(error));
    }
  }

  static Future<void> makeDir(String path) async {
    try {
      await Directory(path).create();
    } on FileSystemException catch (error) {
      throw LocalFileException(_friendly(error));
    }
  }

  static String _friendly(FileSystemException error) {
    final os = error.osError?.message ?? '';
    if (os.contains('Directory not empty')) return tr('仅能删除空目录');
    if (os.contains('Permission denied') || os.contains('Operation not permitted')) {
      return '没有权限访问:${error.path ?? ''}';
    }
    if (os.contains('No such file or directory')) {
      return '文件或目录不存在:${error.path ?? ''}';
    }
    return os.isNotEmpty ? os : error.message;
  }
}
