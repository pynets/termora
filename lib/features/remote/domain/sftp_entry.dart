/// 远端目录里的一个条目(由 OpenSSH sftp 的 `ls -la` 长格式解析而来)
class SftpEntry {
  const SftpEntry({
    required this.name,
    required this.isDir,
    this.isLink = false,
    this.size = 0,
    this.modified = '',
  });

  final String name;
  final bool isDir;
  final bool isLink;
  final int size;

  /// 原样保留 sftp 输出的时间列(如 "Jul  7 10:00" / "Mar 12  2025"),
  /// 只做展示,不参与排序
  final String modified;

  String get sizeLabel {
    if (isDir) return '—';
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    if (size < 1024 * 1024 * 1024) {
      return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(size / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
