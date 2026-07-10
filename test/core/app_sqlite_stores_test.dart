import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:termora/core/data/app_database.dart';
import 'package:termora/core/data/command_history_store.dart';
import 'package:termora/core/data/transfer_log_store.dart';
import 'package:termora/features/notes/data/note_search_index.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AppDatabase.debugUseDatabase(sqlite3.openInMemory());
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    AppDatabase.debugUseDatabase(null);
  });

  group('CommandHistoryStore', () {
    test('记录/去重上移/按会话隔离', () async {
      await CommandHistoryStore.record('s1', 'ls');
      await CommandHistoryStore.record('s1', 'pwd');
      await CommandHistoryStore.record('s1', 'ls'); // 去重上移
      await CommandHistoryStore.record('s2', 'top');

      expect(await CommandHistoryStore.load('s1'), ['pwd', 'ls']);
      expect(await CommandHistoryStore.load('s2'), ['top']);
    });

    test('removeSession 清空该会话', () async {
      await CommandHistoryStore.record('s1', 'ls');
      await CommandHistoryStore.removeSession('s1');
      expect(await CommandHistoryStore.load('s1'), isEmpty);
    });

    test('旧 prefs 历史一次性迁移(会话级 + 全局种子)', () async {
      SharedPreferences.setMockInitialValues({
        'workbench_terminal_history_v1': ['old-a', 'old-b'],
        'workbench_terminal_history_v1.terminal_1': ['echo hi', 'make'],
      });
      // 已有专属历史的会话读到自己的
      expect(
        await CommandHistoryStore.load('terminal_1'),
        ['echo hi', 'make'],
      );
      // 新会话回落旧全局种子
      expect(await CommandHistoryStore.load('terminal_9'), ['old-a', 'old-b']);
      // 旧 key 已清除
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys().where((k) => k.contains('history_v1')), isEmpty);
    });
  });

  group('TransferLogStore', () {
    test('落盘并按主机读取最近记录(新→旧)', () async {
      await TransferLogStore.add(
        TransferRecord(
          host: 'h1',
          label: 'a.txt',
          isUpload: true,
          state: 'done',
          total: 100,
          finishedAt: DateTime.fromMillisecondsSinceEpoch(1000),
        ),
      );
      await TransferLogStore.add(
        TransferRecord(
          host: 'h1',
          label: 'b.txt',
          isUpload: false,
          state: 'failed',
          error: 'boom',
          finishedAt: DateTime.fromMillisecondsSinceEpoch(2000),
        ),
      );
      await TransferLogStore.add(
        TransferRecord(
          host: 'h2',
          label: 'c.txt',
          isUpload: false,
          state: 'done',
          finishedAt: DateTime.fromMillisecondsSinceEpoch(3000),
        ),
      );

      final h1 = await TransferLogStore.recent('h1');
      expect([for (final r in h1) r.label], ['b.txt', 'a.txt']);
      expect(h1.first.state, 'failed');
      expect(h1.first.error, 'boom');
      expect((await TransferLogStore.recent('h2')).single.label, 'c.txt');
    });
  });

  group('NoteSearchIndex(FTS5 trigram)', () {
    test('中英文子串搜索与增删同步', () async {
      final app = await AppDatabase.instance();
      if (!app.trigramAvailable) {
        markTestSkipped('SQLite 不支持 trigram,搜索回落内存过滤');
        return;
      }
      await NoteSearchIndex.reindexAll({
        'n1': '部署 postgres 的注意事项',
        'n2': 'flutter run 卡死排查',
      });
      expect(NoteSearchIndex.trySearch('postgres'), {'n1'});
      expect(NoteSearchIndex.trySearch('注意事项'), {'n1'});
      expect(NoteSearchIndex.trySearch('flutter'), {'n2'});
      expect(NoteSearchIndex.trySearch('FLUTTER'), {'n2'}); // 大小写不敏感
      expect(NoteSearchIndex.trySearch('不存在的词'), isEmpty);
      // 短查询 → null(调用方回落 contains)
      expect(NoteSearchIndex.trySearch('部署'), isNull);

      NoteSearchIndex.upsert('n1', '改成 mysql 了');
      expect(NoteSearchIndex.trySearch('postgres'), isEmpty);
      expect(NoteSearchIndex.trySearch('mysql'), {'n1'});
      NoteSearchIndex.remove('n1');
      expect(NoteSearchIndex.trySearch('mysql'), isEmpty);
    });
  });
}
