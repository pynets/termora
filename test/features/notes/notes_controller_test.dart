import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:termora/features/notes/controller/notes_providers.dart';
import 'package:termora/features/notes/data/note_store.dart';
import 'package:termora/features/notes/domain/note.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('termora_notes_ctrl');
    NoteStore.debugDirectoryOverride = tempDir;
  });

  tearDown(() {
    NoteStore.debugDirectoryOverride = null;
    tempDir.deleteSync(recursive: true);
  });

  /// 建容器并等首次磁盘加载完成
  Future<(ProviderContainer, NotesController)> makeContainer() async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(notesProvider.notifier);
    while (!container.read(notesProvider).loaded) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    return (container, controller);
  }

  test('新建笔记即选中,并已落盘', () async {
    SharedPreferences.setMockInitialValues({});
    final (container, controller) = await makeContainer();

    final id = controller.create();
    final state = container.read(notesProvider);
    expect(state.notes.single.id, id);
    expect(state.selectedId, id);

    await controller.flush();
    expect((await NoteStore.load()).single.id, id);
    expect(await NoteStore.loadSelectedId(), id);
  });

  test('编辑内容立即反映到状态,flush 后落盘', () async {
    SharedPreferences.setMockInitialValues({});
    final (container, controller) = await makeContainer();
    final id = controller.create();

    controller.updateContent(id, '# 新标题\n\n正文');
    expect(container.read(notesProvider).selected!.title, '新标题');

    await controller.flush();
    expect((await NoteStore.load()).single.content, '# 新标题\n\n正文');
  });

  test('删除当前选中回落到最近更新的一条', () async {
    SharedPreferences.setMockInitialValues({});
    final (container, controller) = await makeContainer();
    final a = controller.create();
    final b = controller.create();
    controller.updateContent(a, '旧');
    controller.updateContent(b, '新');
    controller.select(b);

    await controller.remove(b);
    final state = container.read(notesProvider);
    expect(state.notes.single.id, a);
    expect(state.selectedId, a);
  });

  test('搜索按内容过滤,"最近修改"模式按更新时间倒序', () async {
    SharedPreferences.setMockInitialValues({});
    final (container, controller) = await makeContainer();
    controller.setSortMode(NoteSortMode.updated);
    final a = controller.create();
    await Future<void>.delayed(const Duration(milliseconds: 2));
    final b = controller.create();
    controller.updateContent(a, '# 买菜清单');
    await Future<void>.delayed(const Duration(milliseconds: 2));
    controller.updateContent(b, '# 会议纪要');

    var visible = container.read(notesProvider).visibleNotes;
    expect(visible.map((n) => n.id), [b, a]); // b 最后更新,排前

    controller.setQuery('买菜');
    visible = container.read(notesProvider).visibleNotes;
    expect(visible.single.id, a);

    controller.setQuery('');
    expect(container.read(notesProvider).visibleNotes, hasLength(2));
  });

  test('默认排序 = 名称数字自然序;置顶恒在前;模式持久化恢复', () async {
    SharedPreferences.setMockInitialValues({});
    final (container, controller) = await makeContainer();
    expect(container.read(notesProvider).sortMode, NoteSortMode.title);

    final a = controller.create();
    final b = controller.create();
    final c = controller.create();
    controller.updateContent(a, '第10章');
    controller.updateContent(b, '第2章');
    controller.updateContent(c, 'abc');

    // 数字自然序:abc < 第2章 < 第10章(数字按数值比较)
    var visible = container.read(notesProvider).visibleNotes;
    expect(visible.map((n) => n.title), ['abc', '第2章', '第10章']);

    // 置顶优先于排序
    await controller.togglePin(a);
    visible = container.read(notesProvider).visibleNotes;
    expect(visible.first.id, a);

    // 切"最近创建"并持久化,重启(新容器)恢复
    controller.setSortMode(NoteSortMode.created);
    await controller.flush();
    final (container2, _) = await makeContainer();
    expect(container2.read(notesProvider).sortMode, NoteSortMode.created);
  });

  test('置顶排序优先于更新时间', () async {
    SharedPreferences.setMockInitialValues({});
    final (container, controller) = await makeContainer();
    controller.setSortMode(NoteSortMode.updated);
    final a = controller.create();
    await Future<void>.delayed(const Duration(milliseconds: 2));
    final b = controller.create();
    controller.updateContent(a, '旧的');
    await Future<void>.delayed(const Duration(milliseconds: 2));
    controller.updateContent(b, '新的');

    await controller.togglePin(a);
    var visible = container.read(notesProvider).visibleNotes;
    expect(visible.map((n) => n.id), [a, b]); // 置顶的旧笔记排前

    await controller.togglePin(a);
    visible = container.read(notesProvider).visibleNotes;
    expect(visible.map((n) => n.id), [b, a]);
  });

  test('笔记本:新建即切换,过滤生效,新笔记归入当前本', () async {
    SharedPreferences.setMockInitialValues({});
    final (container, controller) = await makeContainer();
    final loose = controller.create(); // 未分组

    final nbId = controller.createNotebook('工作');
    expect(container.read(notesProvider).activeNotebookId, nbId);

    final inNb = controller.create(); // 归入"工作"
    expect(container.read(notesProvider).selected!.notebookId, nbId);

    // 当前本只看到本内笔记
    var visible = container.read(notesProvider).visibleNotes;
    expect(visible.map((n) => n.id), [inNb]);

    // 全部笔记看到两条
    controller.setActiveNotebook(null);
    visible = container.read(notesProvider).visibleNotes;
    expect(visible, hasLength(2));

    // 移动未分组笔记进本
    await controller.moveToNotebook(loose, nbId);
    controller.setActiveNotebook(nbId);
    expect(container.read(notesProvider).visibleNotes, hasLength(2));
  });

  test('删除笔记本:笔记移回未分组且视图回落到全部', () async {
    SharedPreferences.setMockInitialValues({});
    final (container, controller) = await makeContainer();
    final nbId = controller.createNotebook('临时');
    final id = controller.create();

    await controller.deleteNotebook(nbId);
    final state = container.read(notesProvider);
    expect(state.notebooks, isEmpty);
    expect(state.activeNotebookId, isNull);
    expect(state.notes.single.id, id);
    expect(state.notes.single.notebookId, isNull);
  });

  test('笔记本重命名并持久化恢复', () async {
    SharedPreferences.setMockInitialValues({});
    final (_, controller) = await makeContainer();
    final nbId = controller.createNotebook('旧名');
    await controller.renameNotebook(nbId, '新名');
    controller.create();
    await controller.flush();

    // 新容器模拟重启
    final (container2, _) = await makeContainer();
    final state = container2.read(notesProvider);
    expect(state.notebooks.single.name, '新名');
    expect(state.activeNotebookId, nbId);
    expect(state.notes.single.notebookId, nbId);
  });

  test('启动时恢复上次选中;失效 id 回落到最近更新', () async {
    final now = DateTime.now();
    Note note(String id, DateTime updated) =>
        Note(id: id, content: id, createdAt: now, updatedAt: updated);
    SharedPreferences.setMockInitialValues({});
    await NoteStore.save([
      note('old', now.subtract(const Duration(days: 1))),
      note('fresh', now),
    ]);
    await NoteStore.saveSelectedId('gone');

    final (container, _) = await makeContainer();
    expect(container.read(notesProvider).selectedId, 'fresh');
  });
}
