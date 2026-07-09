import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一条快捷命令 / 片段:发送到当前终端(WindTerm 式 snippet)。
@immutable
class Snippet {
  const Snippet({required this.id, required this.name, required this.command});

  final String id;
  final String name;

  /// 命令正文;发送时不含尾换行由使用方决定是否补
  final String command;

  Snippet copyWith({String? name, String? command}) => Snippet(
    id: id,
    name: name ?? this.name,
    command: command ?? this.command,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'command': command,
  };

  factory Snippet.fromJson(Map<String, dynamic> json) => Snippet(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
    command: json['command'] as String? ?? '',
  );
}

/// 片段库 — shared_preferences 持久化,内存缓存 + ValueNotifier 供 UI 订阅。
class SnippetStore {
  SnippetStore._();

  static const _key = 'terminal_snippets_v1';

  /// UI 订阅这个;增删改后自动刷新按钮菜单
  static final ValueNotifier<List<Snippet>> snippets =
      ValueNotifier<List<Snippet>>(const []);

  static bool _loaded = false;

  static Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return;
      final list = (json.decode(raw) as List<dynamic>)
          .map((e) => Snippet.fromJson(e as Map<String, dynamic>))
          .toList();
      snippets.value = list;
    } catch (_) {
      // 读失败不致命,保持空库
    }
  }

  static Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _key,
        json.encode([for (final s in snippets.value) s.toJson()]),
      );
    } catch (_) {}
  }

  static Future<void> upsert(Snippet snippet) async {
    final list = [...snippets.value];
    final i = list.indexWhere((s) => s.id == snippet.id);
    if (i >= 0) {
      list[i] = snippet;
    } else {
      list.add(snippet);
    }
    snippets.value = list;
    await _save();
  }

  static Future<void> remove(String id) async {
    snippets.value = [
      for (final s in snippets.value)
        if (s.id != id) s,
    ];
    await _save();
  }
}
