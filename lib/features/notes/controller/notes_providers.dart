import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:termora/features/notes/data/note_store.dart';
import 'package:termora/features/notes/domain/note.dart';

class NotesState {
  const NotesState({
    this.notes = const [],
    this.notebooks = const [],
    this.activeNotebookId,
    this.selectedId,
    this.query = '',
    this.loaded = false,
  });

  final List<Note> notes;

  /// 笔记本(分组)列表
  final List<Notebook> notebooks;

  /// 当前查看的笔记本;null = 全部笔记
  final String? activeNotebookId;

  final String? selectedId;

  /// 列表搜索关键字(标题+正文包含匹配)
  final String query;

  /// 首次磁盘加载是否完成(避免启动瞬间闪"空空如也")
  final bool loaded;

  Note? get selected =>
      notes.where((n) => n.id == selectedId).firstOrNull;

  Notebook? get activeNotebook =>
      notebooks.where((n) => n.id == activeNotebookId).firstOrNull;

  /// 笔记本过滤 + 搜索过滤 + 置顶优先、更新时间倒序
  List<Note> get visibleNotes {
    final q = query.trim().toLowerCase();
    final list = [
      for (final n in notes)
        if ((activeNotebookId == null || n.notebookId == activeNotebookId) &&
            (q.isEmpty || n.content.toLowerCase().contains(q)))
          n,
    ];
    list.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return b.updatedAt.compareTo(a.updatedAt);
    });
    return list;
  }

  /// 某笔记本下的笔记数(切换菜单里显示;null = 全部)
  int countIn(String? notebookId) => notebookId == null
      ? notes.length
      : notes.where((n) => n.notebookId == notebookId).length;

  NotesState copyWith({
    List<Note>? notes,
    List<Notebook>? notebooks,
    String? activeNotebookId,
    String? selectedId,
    String? query,
    bool? loaded,
    bool clearSelection = false,
    bool clearActiveNotebook = false,
  }) {
    return NotesState(
      notes: notes ?? this.notes,
      notebooks: notebooks ?? this.notebooks,
      activeNotebookId: clearActiveNotebook
          ? null
          : (activeNotebookId ?? this.activeNotebookId),
      selectedId: clearSelection ? null : (selectedId ?? this.selectedId),
      query: query ?? this.query,
      loaded: loaded ?? this.loaded,
    );
  }
}

class NotesController extends Notifier<NotesState> {
  /// 内容落盘防抖(输入中不必每键写盘)
  Timer? _saveDebounce;

  @override
  NotesState build() {
    ref.onDispose(() {
      _saveDebounce?.cancel();
    });
    _load();
    return const NotesState();
  }

  Future<void> _load() async {
    final notes = await NoteStore.load();
    final notebooks = await NoteStore.loadNotebooks();
    final lastId = await NoteStore.loadSelectedId();
    final lastNotebook = await NoteStore.loadActiveNotebook();
    final selected = notes.any((n) => n.id == lastId)
        ? lastId
        : (notes.isEmpty
              ? null
              : notes
                    .reduce(
                      (a, b) => a.updatedAt.isAfter(b.updatedAt) ? a : b,
                    )
                    .id);
    state = NotesState(
      notes: notes,
      notebooks: notebooks,
      activeNotebookId: notebooks.any((n) => n.id == lastNotebook)
          ? lastNotebook
          : null,
      selectedId: selected,
      loaded: true,
    );
  }

  /// 新建一条空白笔记并选中(归入当前查看的笔记本),返回其 id
  String create() {
    final now = DateTime.now();
    final note = Note(
      id: now.microsecondsSinceEpoch.toRadixString(36),
      content: '',
      createdAt: now,
      updatedAt: now,
      notebookId: state.activeNotebookId,
    );
    state = state.copyWith(notes: [...state.notes, note], selectedId: note.id);
    NoteStore.saveSelectedId(note.id);
    _persistNow();
    return note.id;
  }

  /// 编辑内容:状态立即更新(标题/排序即时刷新),磁盘写入防抖
  void updateContent(String id, String content) {
    final index = state.notes.indexWhere((n) => n.id == id);
    if (index < 0 || state.notes[index].content == content) return;
    state = state.copyWith(
      notes: [
        for (final n in state.notes)
          if (n.id == id)
            n.copyWith(content: content, updatedAt: DateTime.now())
          else
            n,
      ],
    );
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 500), _persistNow);
  }

  Future<void> remove(String id) async {
    final notes = [
      for (final n in state.notes)
        if (n.id != id) n,
    ];
    String? selected = state.selectedId;
    if (selected == id) {
      // 删除当前笔记:回落到剩余中最近更新的一条
      selected = notes.isEmpty
          ? null
          : notes
                .reduce((a, b) => a.updatedAt.isAfter(b.updatedAt) ? a : b)
                .id;
      NoteStore.saveSelectedId(selected);
    }
    state = NotesState(
      notes: notes,
      selectedId: selected,
      query: state.query,
      loaded: state.loaded,
    );
    await _persistNow();
  }

  void select(String id) {
    if (state.selectedId == id) return;
    state = state.copyWith(selectedId: id);
    NoteStore.saveSelectedId(id);
  }

  void setQuery(String query) {
    state = state.copyWith(query: query);
  }

  // ══════════════ 置顶 ══════════════

  Future<void> togglePin(String id) async {
    state = state.copyWith(
      notes: [
        for (final n in state.notes)
          if (n.id == id) n.copyWith(pinned: !n.pinned) else n,
      ],
    );
    await _persistNow();
  }

  // ══════════════ 笔记本 ══════════════

  /// 新建笔记本并切换过去,返回其 id
  String createNotebook(String name) {
    final notebook = Notebook(
      id: DateTime.now().microsecondsSinceEpoch.toRadixString(36),
      name: name.trim(),
    );
    state = state.copyWith(
      notebooks: [...state.notebooks, notebook],
      activeNotebookId: notebook.id,
    );
    NoteStore.saveNotebooks(state.notebooks);
    NoteStore.saveActiveNotebook(notebook.id);
    return notebook.id;
  }

  Future<void> renameNotebook(String id, String name) async {
    state = state.copyWith(
      notebooks: [
        for (final n in state.notebooks)
          if (n.id == id) Notebook(id: id, name: name.trim()) else n,
      ],
    );
    await NoteStore.saveNotebooks(state.notebooks);
  }

  /// 删除笔记本,其中的笔记回落到未分组(不删笔记)
  Future<void> deleteNotebook(String id) async {
    state = state.copyWith(
      notebooks: [
        for (final n in state.notebooks)
          if (n.id != id) n,
      ],
      notes: [
        for (final n in state.notes)
          if (n.notebookId == id) n.copyWith(clearNotebook: true) else n,
      ],
      clearActiveNotebook: state.activeNotebookId == id,
    );
    await NoteStore.saveNotebooks(state.notebooks);
    if (state.activeNotebookId == null) {
      await NoteStore.saveActiveNotebook(null);
    }
    await _persistNow();
  }

  /// 切换查看的笔记本(null = 全部)
  void setActiveNotebook(String? id) {
    state = state.copyWith(
      activeNotebookId: id,
      clearActiveNotebook: id == null,
    );
    NoteStore.saveActiveNotebook(id);
  }

  /// 把笔记移动到某笔记本(null = 移出分组)
  Future<void> moveToNotebook(String noteId, String? notebookId) async {
    state = state.copyWith(
      notes: [
        for (final n in state.notes)
          if (n.id == noteId)
            n.copyWith(
              notebookId: notebookId,
              clearNotebook: notebookId == null,
            )
          else
            n,
      ],
    );
    await _persistNow();
  }

  Future<void> _persistNow() async {
    _saveDebounce?.cancel();
    await NoteStore.save(state.notes);
  }

  /// 页面销毁/切换前确保未落盘的编辑立刻写入
  Future<void> flush() => _persistNow();
}

final notesProvider = NotifierProvider<NotesController, NotesState>(
  NotesController.new,
);
