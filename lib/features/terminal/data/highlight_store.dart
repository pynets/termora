import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:termora/features/terminal/controller/terminal_model.dart';

/// 一条触发器高亮规则(WindTerm 式 trigger/highlight):终端输出里匹配
/// 关键字 / 正则的文本自动上色,便于快速定位 ERROR / WARN 等。
@immutable
class HighlightRule {
  const HighlightRule({
    required this.id,
    required this.name,
    required this.pattern,
    required this.color,
    this.isRegex = false,
    this.caseSensitive = false,
    this.wholeLine = true,
    this.bold = true,
    this.enabled = true,
  });

  final String id;
  final String name;

  /// 匹配文本:isRegex=false 时按普通子串;true 时按正则
  final String pattern;

  /// 命中后使用的前景色
  final Color color;
  final bool isRegex;
  final bool caseSensitive;

  /// true 整行上色;false 只给命中的片段上色
  final bool wholeLine;
  final bool bold;
  final bool enabled;

  /// 预编译正则;pattern 非法或为空时返回 null(该规则视为不匹配)。
  RegExp? get regex {
    if (pattern.isEmpty) return null;
    try {
      return RegExp(
        isRegex ? pattern : RegExp.escape(pattern),
        caseSensitive: caseSensitive,
      );
    } catch (_) {
      return null;
    }
  }

  HighlightRule copyWith({
    String? name,
    String? pattern,
    Color? color,
    bool? isRegex,
    bool? caseSensitive,
    bool? wholeLine,
    bool? bold,
    bool? enabled,
  }) => HighlightRule(
    id: id,
    name: name ?? this.name,
    pattern: pattern ?? this.pattern,
    color: color ?? this.color,
    isRegex: isRegex ?? this.isRegex,
    caseSensitive: caseSensitive ?? this.caseSensitive,
    wholeLine: wholeLine ?? this.wholeLine,
    bold: bold ?? this.bold,
    enabled: enabled ?? this.enabled,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'pattern': pattern,
    'color': color.toARGB32(),
    'isRegex': isRegex,
    'caseSensitive': caseSensitive,
    'wholeLine': wholeLine,
    'bold': bold,
    'enabled': enabled,
  };

  factory HighlightRule.fromJson(Map<String, dynamic> json) => HighlightRule(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
    pattern: json['pattern'] as String? ?? '',
    color: Color((json['color'] as num?)?.toInt() ?? 0xFFFF5555),
    isRegex: json['isRegex'] as bool? ?? false,
    caseSensitive: json['caseSensitive'] as bool? ?? false,
    wholeLine: json['wholeLine'] as bool? ?? true,
    bold: json['bold'] as bool? ?? true,
    enabled: json['enabled'] as bool? ?? true,
  );
}

/// 高亮规则库 — shared_preferences 持久化,ValueNotifier 供 UI / 渲染订阅。
class HighlightStore {
  HighlightStore._();

  static const _key = 'terminal_highlight_rules_v1';

  static final ValueNotifier<List<HighlightRule>> rules =
      ValueNotifier<List<HighlightRule>>(const []);

  static bool _loaded = false;

  static Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return;
      rules.value = (json.decode(raw) as List<dynamic>)
          .map((e) => HighlightRule.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {}
  }

  static Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _key,
        json.encode([for (final r in rules.value) r.toJson()]),
      );
    } catch (_) {}
  }

  static Future<void> upsert(HighlightRule rule) async {
    final list = [...rules.value];
    final i = list.indexWhere((r) => r.id == rule.id);
    if (i >= 0) {
      list[i] = rule;
    } else {
      list.add(rule);
    }
    rules.value = list;
    await _save();
  }

  static Future<void> remove(String id) async {
    rules.value = [
      for (final r in rules.value)
        if (r.id != id) r,
    ];
    await _save();
  }

  /// 把高亮规则应用到一行:命中的文本(整行或片段)前景色被覆盖。
  /// 无命中时原样返回同一个对象(零拷贝,渲染热路径友好)。
  static TerminalLine apply(TerminalLine line, List<HighlightRule> rules) {
    if (rules.isEmpty || line.spans.isEmpty) return line;
    final text = line.text;
    if (text.isEmpty) return line;

    // 收集需要覆盖的 [起, 止) 区间及其目标样式(后加入的规则覆盖先加入的)。
    final overrides = <_Override>[];
    var wholeLineRule = false;
    for (final rule in rules) {
      if (!rule.enabled) continue;
      final re = rule.regex;
      if (re == null) continue;
      final matches = re.allMatches(text);
      var matched = false;
      for (final m in matches) {
        matched = true;
        if (!rule.wholeLine) {
          overrides.add(_Override(m.start, m.end, rule.color, rule.bold));
        }
      }
      if (matched && rule.wholeLine) {
        wholeLineRule = true;
        overrides.add(_Override(0, text.length, rule.color, rule.bold));
      }
    }
    if (overrides.isEmpty) return line;

    // 整行规则命中时,直接给所有 span 上色(最常见,走快路)。
    if (wholeLineRule) {
      final o = overrides.lastWhere((e) => e.start == 0 && e.end == text.length);
      return TerminalLine([
        for (final s in line.spans)
          s.copyWith(
            style: s.style.copyWith(foreground: o.color, bold: o.bold),
          ),
      ], line.type)
        ..isWrapped = line.isWrapped;
    }

    // 片段规则:按字符偏移切分 span,只给命中区间上色。
    final result = <TerminalSpan>[];
    var offset = 0;
    for (final span in line.spans) {
      final start = offset;
      final end = offset + span.text.length;
      offset = end;
      // 找出落在本 span 内的所有区间,按边界切片。
      final cuts = <int>{start, end};
      for (final o in overrides) {
        if (o.end <= start || o.start >= end) continue;
        cuts.add(o.start.clamp(start, end));
        cuts.add(o.end.clamp(start, end));
      }
      final sorted = cuts.toList()..sort();
      for (var i = 0; i < sorted.length - 1; i++) {
        final a = sorted[i];
        final b = sorted[i + 1];
        if (b <= a) continue;
        final piece = span.text.substring(a - start, b - start);
        _Override? hit;
        for (final o in overrides) {
          if (o.start <= a && o.end >= b) hit = o; // 后者覆盖前者
        }
        result.add(
          hit == null
              ? span.copyWith(text: piece)
              : span.copyWith(
                  text: piece,
                  style: span.style.copyWith(
                    foreground: hit.color,
                    bold: hit.bold,
                  ),
                ),
        );
      }
    }
    return TerminalLine(result, line.type)..isWrapped = line.isWrapped;
  }
}

class _Override {
  const _Override(this.start, this.end, this.color, this.bold);
  final int start;
  final int end;
  final Color color;
  final bool bold;
}
