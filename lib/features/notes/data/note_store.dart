import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:termora/features/notes/data/note_search_index.dart';
import 'package:termora/features/notes/domain/note.dart';

/// 笔记持久化 — 正文按 marktext 的文件形态落盘:
/// 应用支持目录 notes/ 下每篇一个 `<id>.md`,元数据(时间/置顶/笔记本)
/// 集中在 meta.json;保存时只重写内容变化的文件。
/// 旧版曾把全部笔记塞进 shared_preferences 一个 JSON,首次加载自动迁移
/// (旧数据保留作备份,不删除)。界面状态(选中/视图模式等)仍在 prefs。
class NoteStore {
  NoteStore._();

  /// 旧版 prefs 全量 JSON 的 key,仅迁移时读取
  static const _legacyNotesKey = 'notes.items.v1';
  static const _selectedKey = 'notes.selected.v1';
  static const _viewModeKey = 'notes.view_mode.v1';
  static const _outlineKey = 'notes.outline.v1';
  static const _sidebarKey = 'notes.sidebar.v1';
  static const _notebooksKey = 'notes.notebooks.v1';
  static const _activeNotebookKey = 'notes.active_notebook.v1';
  static const _focusModeKey = 'notes.focus_mode.v1';
  static const _typewriterKey = 'notes.typewriter.v1';

  static Directory? _directoryOverride;

  /// 测试注入:覆盖笔记文件根目录(同时清掉写入缓存)
  static set debugDirectoryOverride(Directory? dir) {
    _directoryOverride = dir;
    _written.clear();
  }

  /// 每篇笔记最近写入的内容,保存时跳过未变化的文件
  static final Map<String, String> _written = {};

  /// 文件读写用同步 API:单篇笔记体量小,桌面端开销可忽略,
  /// 且 widget 测试的 FakeAsync 环境无法推进真实异步 IO 的 Future。
  static Future<Directory> _notesDir() async {
    final base =
        _directoryOverride ?? await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'notes'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  static File _metaFile(Directory dir) => File(p.join(dir.path, 'meta.json'));

  static File _noteFile(Directory dir, String id) =>
      File(p.join(dir.path, '$id.md'));

  static Future<List<Note>> load() async {
    final dir = await _notesDir();
    final meta = _metaFile(dir);
    if (!meta.existsSync()) {
      return await _migrateFromPrefs() ?? [];
    }
    try {
      final decoded =
          jsonDecode(meta.readAsStringSync()) as Map<String, dynamic>;
      final notes = <Note>[];
      for (final entry in (decoded['notes'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()) {
        final id = entry['id'] as String? ?? '';
        if (id.isEmpty) continue;
        final file = _noteFile(dir, id);
        final content = file.existsSync() ? file.readAsStringSync() : '';
        _written[id] = content;
        notes.add(
          Note(
            id: id,
            content: content,
            createdAt: DateTime.fromMillisecondsSinceEpoch(
              entry['createdAt'] as int? ?? 0,
            ),
            updatedAt: DateTime.fromMillisecondsSinceEpoch(
              entry['updatedAt'] as int? ?? 0,
            ),
            pinned: entry['pinned'] as bool? ?? false,
            notebookId: entry['notebookId'] as String?,
          ),
        );
      }
      // 全文搜索索引:启动时全量重建一次,之后随保存增量同步
      unawaited(
        NoteSearchIndex.reindexAll({
          for (final n in notes) n.id: n.content,
        }).catchError((_) {}),
      );
      return notes;
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(List<Note> notes) async {
    final dir = await _notesDir();
    _metaFile(dir).writeAsStringSync(
      jsonEncode({
        'version': 1,
        'notes': [
          for (final n in notes)
            {
              'id': n.id,
              'createdAt': n.createdAt.millisecondsSinceEpoch,
              'updatedAt': n.updatedAt.millisecondsSinceEpoch,
              if (n.pinned) 'pinned': true,
              if (n.notebookId != null) 'notebookId': n.notebookId,
            },
        ],
      }),
    );
    // 正文:只写内容变化的文件(同步更新全文搜索索引)
    for (final n in notes) {
      if (_written[n.id] != n.content) {
        _noteFile(dir, n.id).writeAsStringSync(n.content);
        _written[n.id] = n.content;
        NoteSearchIndex.upsert(n.id, n.content);
      }
    }
    // 清理已删除笔记的文件
    final ids = {for (final n in notes) n.id};
    for (final f in dir.listSync()) {
      if (f is File && f.path.endsWith('.md')) {
        final id = p.basenameWithoutExtension(f.path);
        if (!ids.contains(id)) {
          f.deleteSync();
          _written.remove(id);
          NoteSearchIndex.remove(id);
        }
      }
    }
  }

  /// 首次运行(无 meta.json)时从旧版 prefs 全量 JSON 迁移
  static Future<List<Note>?> _migrateFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_legacyNotesKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      final notes = list
          .whereType<Map<String, dynamic>>()
          .map(Note.fromJson)
          .toList();
      await save(notes);
      // 旧数据保留在 prefs 作备份,不删除
      return notes;
    } catch (_) {
      return null;
    }
  }

  // ── 界面恢复:上次选中的笔记 / 编辑视图模式 ──

  static Future<String?> loadSelectedId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_selectedKey);
  }

  static Future<void> saveSelectedId(String? id) async {
    final prefs = await SharedPreferences.getInstance();
    if (id == null) {
      await prefs.remove(_selectedKey);
    } else {
      await prefs.setString(_selectedKey, id);
    }
  }

  /// 视图模式下标(NoteViewMode.index);默认 0 = 编辑(所见即所得)
  static Future<int> loadViewMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_viewModeKey) ?? 0;
  }

  static Future<void> saveViewMode(int mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_viewModeKey, mode);
  }

  static Future<bool> loadShowOutline() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_outlineKey) ?? false;
  }

  static Future<void> saveShowOutline(bool show) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_outlineKey, show);
  }

  static Future<bool> loadShowSidebar() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_sidebarKey) ?? true;
  }

  static Future<void> saveShowSidebar(bool show) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_sidebarKey, show);
  }

  // ── 笔记本(分组) ──

  static Future<List<Notebook>> loadNotebooks() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_notebooksKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .whereType<Map<String, dynamic>>()
          .map(Notebook.fromJson)
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveNotebooks(List<Notebook> notebooks) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _notebooksKey,
      jsonEncode([for (final n in notebooks) n.toJson()]),
    );
  }

  static Future<String?> loadActiveNotebook() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_activeNotebookKey);
  }

  static Future<void> saveActiveNotebook(String? id) async {
    final prefs = await SharedPreferences.getInstance();
    if (id == null) {
      await prefs.remove(_activeNotebookKey);
    } else {
      await prefs.setString(_activeNotebookKey, id);
    }
  }

  // ── 聚焦 / 打字机模式 ──

  static Future<bool> loadFocusMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_focusModeKey) ?? false;
  }

  static Future<void> saveFocusMode(bool on) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_focusModeKey, on);
  }

  static Future<bool> loadTypewriter() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_typewriterKey) ?? false;
  }

  static Future<void> saveTypewriter(bool on) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_typewriterKey, on);
  }
}
