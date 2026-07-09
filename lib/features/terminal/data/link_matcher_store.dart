import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一条自定义链接规则(对标 xterm.js registerLinkMatcher):
/// 终端输出里匹配 [pattern] 的文本变成可点击链接,URL 由 [urlTemplate]
/// 生成 —— `$0` 为整个匹配,`$1`..`$9` 为捕获组。
/// 典型用法:`JIRA-(\d+)` → `https://jira.example.com/browse/JIRA-$1`。
@immutable
class LinkMatcher {
  const LinkMatcher({
    required this.id,
    required this.name,
    required this.pattern,
    required this.urlTemplate,
    this.enabled = true,
  });

  final String id;
  final String name;
  final String pattern;
  final String urlTemplate;
  final bool enabled;

  /// 预编译正则;非法或为空返回 null(规则视为不匹配)。
  RegExp? get regex {
    if (pattern.isEmpty) return null;
    try {
      return RegExp(pattern);
    } catch (_) {
      return null;
    }
  }

  /// 把捕获组代入模板;组缺失时代空串。
  String expandUrl(RegExpMatch match) {
    return urlTemplate.replaceAllMapped(RegExp(r'\$(\d)'), (m) {
      final index = int.parse(m.group(1)!);
      if (index > match.groupCount) return '';
      return match.group(index) ?? '';
    });
  }

  LinkMatcher copyWith({
    String? name,
    String? pattern,
    String? urlTemplate,
    bool? enabled,
  }) => LinkMatcher(
    id: id,
    name: name ?? this.name,
    pattern: pattern ?? this.pattern,
    urlTemplate: urlTemplate ?? this.urlTemplate,
    enabled: enabled ?? this.enabled,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'pattern': pattern,
    'urlTemplate': urlTemplate,
    'enabled': enabled,
  };

  factory LinkMatcher.fromJson(Map<String, dynamic> json) => LinkMatcher(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
    pattern: json['pattern'] as String? ?? '',
    urlTemplate: json['urlTemplate'] as String? ?? '',
    enabled: json['enabled'] as bool? ?? true,
  );
}

/// 一个命中的自定义链接:[start, end) 为文本内偏移。
class CustomLinkHit {
  const CustomLinkHit(this.start, this.end, this.url);
  final int start;
  final int end;
  final String url;
}

/// 自定义链接规则库 — 持久化 + ValueNotifier 供渲染订阅。
class LinkMatcherStore {
  LinkMatcherStore._();

  static const _key = 'terminal_link_matchers_v1';

  static final ValueNotifier<List<LinkMatcher>> matchers =
      ValueNotifier<List<LinkMatcher>>(const []);

  static bool _loaded = false;

  static Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return;
      matchers.value = (json.decode(raw) as List<dynamic>)
          .map((e) => LinkMatcher.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {}
  }

  static Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _key,
        json.encode([for (final m in matchers.value) m.toJson()]),
      );
    } catch (_) {}
  }

  static Future<void> upsert(LinkMatcher matcher) async {
    final list = [...matchers.value];
    final i = list.indexWhere((m) => m.id == matcher.id);
    if (i >= 0) {
      list[i] = matcher;
    } else {
      list.add(matcher);
    }
    matchers.value = list;
    await _save();
  }

  static Future<void> remove(String id) async {
    matchers.value = [
      for (final m in matchers.value)
        if (m.id != id) m,
    ];
    await _save();
  }

  /// 在 [text] 里找出所有启用规则的命中(可能互相重叠,由调用方合并)。
  static List<CustomLinkHit> findHits(String text) {
    final rules = matchers.value;
    if (rules.isEmpty || text.isEmpty) return const [];
    final hits = <CustomLinkHit>[];
    for (final rule in rules) {
      if (!rule.enabled) continue;
      final re = rule.regex;
      if (re == null) continue;
      for (final m in re.allMatches(text)) {
        if (m.end <= m.start) continue;
        final url = rule.expandUrl(m);
        if (url.isEmpty) continue;
        hits.add(CustomLinkHit(m.start, m.end, url));
      }
    }
    return hits;
  }
}
