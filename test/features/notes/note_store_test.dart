import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:termora/features/notes/data/note_store.dart';
import 'package:termora/features/notes/domain/note.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('termora_notes_test');
    NoteStore.debugDirectoryOverride = tempDir;
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    NoteStore.debugDirectoryOverride = null;
    tempDir.deleteSync(recursive: true);
  });

  Note note(String id, String content) => Note(
    id: id,
    content: content,
    createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(2000),
  );

  test('保存后能原样读回;正文落成独立 .md 文件', () async {
    await NoteStore.save([
      note('a', '# 甲'),
      Note(
        id: 'b',
        content: '乙正文',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(2000),
        pinned: true,
        notebookId: 'nb1',
      ),
    ]);

    final loaded = await NoteStore.load();
    expect(loaded, hasLength(2));
    expect(loaded[0].id, 'a');
    expect(loaded[0].content, '# 甲');
    expect(loaded[1].pinned, isTrue);
    expect(loaded[1].notebookId, 'nb1');
    expect(loaded[1].updatedAt.millisecondsSinceEpoch, 2000);

    // marktext 式文件形态:每篇一个 .md
    expect(
      File('${tempDir.path}/notes/a.md').readAsStringSync(),
      '# 甲',
    );
    expect(File('${tempDir.path}/notes/meta.json').existsSync(), isTrue);
  });

  test('删除笔记后保存,对应 .md 文件被清理', () async {
    await NoteStore.save([note('a', 'x'), note('b', 'y')]);
    await NoteStore.save([note('a', 'x')]);
    expect(File('${tempDir.path}/notes/b.md').existsSync(), isFalse);
    expect((await NoteStore.load()).single.id, 'a');
  });

  test('空存储返回空列表', () async {
    expect(await NoteStore.load(), isEmpty);
  });

  test('损坏的 meta.json 返回空列表而不抛异常', () async {
    Directory('${tempDir.path}/notes').createSync(recursive: true);
    File('${tempDir.path}/notes/meta.json').writeAsStringSync('{oops');
    expect(await NoteStore.load(), isEmpty);
  });

  test('meta 列表混入非对象/缺 id 的条目被跳过', () async {
    Directory('${tempDir.path}/notes').createSync(recursive: true);
    File('${tempDir.path}/notes/meta.json').writeAsStringSync(
      jsonEncode({
        'version': 1,
        'notes': [
          {'id': 'a', 'createdAt': 1, 'updatedAt': 2},
          42,
          {'createdAt': 1},
        ],
      }),
    );
    File('${tempDir.path}/notes/a.md').writeAsStringSync('甲');
    final loaded = await NoteStore.load();
    expect(loaded.single.id, 'a');
    expect(loaded.single.content, '甲');
  });

  test('首次加载自动从旧版 prefs 迁移,旧数据保留作备份', () async {
    final legacy = jsonEncode([
      note('old1', '# 旧一').toJson(),
      note('old2', '旧二').toJson(),
    ]);
    SharedPreferences.setMockInitialValues({'notes.items.v1': legacy});

    final loaded = await NoteStore.load();
    expect(loaded.map((n) => n.id), ['old1', 'old2']);
    // 已落成文件
    expect(File('${tempDir.path}/notes/old1.md').existsSync(), isTrue);
    // prefs 里的旧数据未删除(备份)
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('notes.items.v1'), legacy);
    // 再次加载走文件,不再迁移
    expect(await NoteStore.load(), hasLength(2));
  });

  test('选中笔记 id:保存/清除', () async {
    expect(await NoteStore.loadSelectedId(), isNull);
    await NoteStore.saveSelectedId('n1');
    expect(await NoteStore.loadSelectedId(), 'n1');
    await NoteStore.saveSelectedId(null);
    expect(await NoteStore.loadSelectedId(), isNull);
  });

  test('视图模式:默认编辑(0),保存后读回', () async {
    expect(await NoteStore.loadViewMode(), 0);
    await NoteStore.saveViewMode(1);
    expect(await NoteStore.loadViewMode(), 1);
  });
}
