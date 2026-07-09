/// SQL 脚本变量 — DBeaver 风格的 `${name}` 占位符 + `$1` 位置参数
class SqlVariables {
  SqlVariables._();

  static final RegExp _pattern = RegExp(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}');

  /// 提取 SQL 中引用的所有变量名(按出现顺序去重)
  static List<String> extract(String sql) {
    final seen = <String>{};
    final names = <String>[];
    for (final match in _pattern.allMatches(sql)) {
      final name = match.group(1)!;
      if (seen.add(name)) names.add(name);
    }
    return names;
  }

  /// 用 [values] 替换 SQL 中的 `${name}` 占位符;未提供的变量原样保留
  static String substitute(String sql, Map<String, String> values) {
    return sql.replaceAllMapped(_pattern, (match) {
      final name = match.group(1)!;
      return values.containsKey(name) ? values[name]! : match.group(0)!;
    });
  }

  /// 提取 `$1` `$2` 位置参数(跳过字符串/注释/dollar-quote,按序号排序去重)
  static List<String> extractPositional(String sql) {
    final numbers = <int>{};
    _scan(sql, onParameter: numbers.add);
    final sorted = numbers.toList()..sort();
    return [for (final n in sorted) '\$$n'];
  }

  /// 替换位置参数为字面量。[values] 的 key 形如 `$1`。
  /// 数字/布尔/NULL 原样内联,其余按 SQL 字符串字面量转义包裹。
  static String substitutePositional(String sql, Map<String, String> values) {
    final buffer = StringBuffer();
    var last = 0;
    _scan(
      sql,
      onParameterSpan: (start, end, number) {
        final key = '\$$number';
        if (!values.containsKey(key)) return;
        buffer
          ..write(sql.substring(last, start))
          ..write(toLiteral(values[key]!));
        last = end;
      },
    );
    buffer.write(sql.substring(last));
    return buffer.toString();
  }

  /// 把用户输入变成 SQL 字面量:数字/true/false/null 原样,其余单引号包裹转义
  static String toLiteral(String value) {
    final trimmed = value.trim();
    final isRaw =
        RegExp(r'^-?\d+(\.\d+)?$').hasMatch(trimmed) ||
        RegExp(r'^(true|false|null)$', caseSensitive: false).hasMatch(trimmed);
    if (isRaw) return trimmed;
    return "'${value.replaceAll("'", "''")}'";
  }

  /// 扫描 SQL,跳过字符串('' "")、行/块注释、dollar-quote,
  /// 对每个 `$数字` 位置参数触发回调
  static void _scan(
    String sql, {
    void Function(int number)? onParameter,
    void Function(int start, int end, int number)? onParameterSpan,
  }) {
    var i = 0;
    while (i < sql.length) {
      final ch = sql[i];
      final next = i + 1 < sql.length ? sql[i + 1] : '';

      if (ch == '-' && next == '-') {
        final end = sql.indexOf('\n', i);
        i = end < 0 ? sql.length : end;
        continue;
      }
      if (ch == '/' && next == '*') {
        final end = sql.indexOf('*/', i + 2);
        i = end < 0 ? sql.length : end + 2;
        continue;
      }
      if (ch == "'" || ch == '"') {
        i = _quoteEnd(sql, i, ch);
        continue;
      }
      if (ch == r'$') {
        // dollar-quote: $tag$ ... $tag$(排除 $ 后紧跟数字的位置参数)
        final tagMatch = RegExp(
          r'^\$[A-Za-z_][A-Za-z0-9_]*\$|^\$\$',
        ).firstMatch(sql.substring(i));
        if (tagMatch != null) {
          final tag = tagMatch.group(0)!;
          final end = sql.indexOf(tag, i + tag.length);
          i = end < 0 ? sql.length : end + tag.length;
          continue;
        }
        final numMatch = RegExp(r'^\$(\d+)').firstMatch(sql.substring(i));
        if (numMatch != null) {
          final number = int.parse(numMatch.group(1)!);
          onParameter?.call(number);
          onParameterSpan?.call(i, i + numMatch.group(0)!.length, number);
          i += numMatch.group(0)!.length;
          continue;
        }
      }
      i++;
    }
  }

  static int _quoteEnd(String sql, int start, String quote) {
    var i = start + 1;
    while (i < sql.length) {
      if (sql[i] == quote) {
        if (i + 1 < sql.length && sql[i + 1] == quote) {
          i += 2;
          continue;
        }
        return i + 1;
      }
      i++;
    }
    return sql.length;
  }
}
