import 'package:sqlite3/sqlite3.dart' show ResultSet;
import 'package:termora/core/data/app_database.dart';

/// 一条已结束的传输记录(SFTP 上传/下载)
class TransferRecord {
  const TransferRecord({
    required this.host,
    required this.label,
    required this.isUpload,
    required this.state,
    this.error,
    this.total,
    required this.finishedAt,
  });

  final String host;
  final String label;
  final bool isUpload;

  /// done / failed / cancelled
  final String state;
  final String? error;
  final int? total;
  final DateTime finishedAt;
}

/// SFTP 传输记录 — 持久化到 SQLite:面板重开 / 应用重启后
/// 仍能看到该主机最近的传输历史(此前只存在内存,关面板即失)。
class TransferLogStore {
  TransferLogStore._();

  static const _keepPerHost = 200;

  static Future<void> add(TransferRecord record) async {
    final app = await AppDatabase.instance();
    app.db.execute(
      'INSERT INTO transfer_log(host, label, is_upload, state, error, total, finished_at) '
      'VALUES(?, ?, ?, ?, ?, ?, ?)',
      [
        record.host,
        record.label,
        record.isUpload ? 1 : 0,
        record.state,
        record.error,
        record.total,
        record.finishedAt.millisecondsSinceEpoch,
      ],
    );
    // 每主机保留最近 N 条
    app.db.execute(
      'DELETE FROM transfer_log WHERE host = ? AND id NOT IN ('
      '  SELECT id FROM transfer_log WHERE host = ? '
      '  ORDER BY finished_at DESC, id DESC LIMIT ?)',
      [record.host, record.host, _keepPerHost],
    );
  }

  /// 某主机最近的传输记录(新→旧)
  static Future<List<TransferRecord>> recent(
    String host, {
    int limit = 50,
  }) async {
    final app = await AppDatabase.instance();
    final rows = app.db.select(
      'SELECT host, label, is_upload, state, error, total, finished_at '
      'FROM transfer_log WHERE host = ? '
      'ORDER BY finished_at DESC, id DESC LIMIT ?',
      [host, limit],
    );
    return _mapRows(rows);
  }

  /// 全部主机的传输记录(新→旧),供独立查看页;可按主机名单过滤展示
  static Future<List<TransferRecord>> all({int limit = 500}) async {
    final app = await AppDatabase.instance();
    final rows = app.db.select(
      'SELECT host, label, is_upload, state, error, total, finished_at '
      'FROM transfer_log ORDER BY finished_at DESC, id DESC LIMIT ?',
      [limit],
    );
    return _mapRows(rows);
  }

  /// 清空传输记录:[host] 为 null 清全部,否则只清该主机
  static Future<void> clear({String? host}) async {
    final app = await AppDatabase.instance();
    if (host == null) {
      app.db.execute('DELETE FROM transfer_log');
    } else {
      app.db.execute('DELETE FROM transfer_log WHERE host = ?', [host]);
    }
  }

  static List<TransferRecord> _mapRows(ResultSet rows) {
    return [
      for (final r in rows)
        TransferRecord(
          host: r.columnAt(0) as String,
          label: r.columnAt(1) as String,
          isUpload: (r.columnAt(2) as int) != 0,
          state: r.columnAt(3) as String,
          error: r.columnAt(4) as String?,
          total: r.columnAt(5) as int?,
          finishedAt: DateTime.fromMillisecondsSinceEpoch(
            r.columnAt(6) as int,
          ),
        ),
    ];
  }
}
