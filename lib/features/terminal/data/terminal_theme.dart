import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一套终端配色方案:16 ANSI 色 + 前景 / 背景 / 光标。
/// [ansi] 为空表示「跟随应用」(用引擎内置深/浅默认),fg/bg/cursor 也可为空。
@immutable
class TerminalTheme {
  const TerminalTheme({
    required this.name,
    this.ansi,
    this.foreground,
    this.background,
    this.cursor,
  });

  final String name;

  /// 16 项:0-7 常规,8-15 明亮;null=跟随应用默认
  final List<Color>? ansi;
  final Color? foreground;
  final Color? background;
  final Color? cursor;

  bool get isDefault => ansi == null && background == null;
}

/// 内置配色方案。第一个「跟随应用」不覆盖任何颜色。
const List<TerminalTheme> kTerminalThemes = <TerminalTheme>[
  TerminalTheme(name: '跟随应用'),
  TerminalTheme(
    name: 'Dracula',
    background: Color(0xFF282A36),
    foreground: Color(0xFFF8F8F2),
    cursor: Color(0xFFF8F8F2),
    ansi: [
      Color(0xFF21222C), Color(0xFFFF5555), Color(0xFF50FA7B), Color(0xFFF1FA8C),
      Color(0xFFBD93F9), Color(0xFFFF79C6), Color(0xFF8BE9FD), Color(0xFFF8F8F2),
      Color(0xFF6272A4), Color(0xFFFF6E6E), Color(0xFF69FF94), Color(0xFFFFFFA5),
      Color(0xFFD6ACFF), Color(0xFFFF92DF), Color(0xFFA4FFFF), Color(0xFFFFFFFF),
    ],
  ),
  TerminalTheme(
    name: 'Solarized Dark',
    background: Color(0xFF002B36),
    foreground: Color(0xFF839496),
    cursor: Color(0xFF93A1A1),
    ansi: [
      Color(0xFF073642), Color(0xFFDC322F), Color(0xFF859900), Color(0xFFB58900),
      Color(0xFF268BD2), Color(0xFFD33682), Color(0xFF2AA198), Color(0xFFEEE8D5),
      Color(0xFF002B36), Color(0xFFCB4B16), Color(0xFF586E75), Color(0xFF657B83),
      Color(0xFF839496), Color(0xFF6C71C4), Color(0xFF93A1A1), Color(0xFFFDF6E3),
    ],
  ),
  TerminalTheme(
    name: 'Nord',
    background: Color(0xFF2E3440),
    foreground: Color(0xFFD8DEE9),
    cursor: Color(0xFFD8DEE9),
    ansi: [
      Color(0xFF3B4252), Color(0xFFBF616A), Color(0xFFA3BE8C), Color(0xFFEBCB8B),
      Color(0xFF81A1C1), Color(0xFFB48EAD), Color(0xFF88C0D0), Color(0xFFE5E9F0),
      Color(0xFF4C566A), Color(0xFFBF616A), Color(0xFFA3BE8C), Color(0xFFEBCB8B),
      Color(0xFF81A1C1), Color(0xFFB48EAD), Color(0xFF8FBCBB), Color(0xFFECEFF4),
    ],
  ),
  TerminalTheme(
    name: 'Gruvbox Dark',
    background: Color(0xFF282828),
    foreground: Color(0xFFEBDBB2),
    cursor: Color(0xFFEBDBB2),
    ansi: [
      Color(0xFF282828), Color(0xFFCC241D), Color(0xFF98971A), Color(0xFFD79921),
      Color(0xFF458588), Color(0xFFB16286), Color(0xFF689D6A), Color(0xFFA89984),
      Color(0xFF928374), Color(0xFFFB4934), Color(0xFFB8BB26), Color(0xFFFABD2F),
      Color(0xFF83A598), Color(0xFFD3869B), Color(0xFF8EC07C), Color(0xFFEBDBB2),
    ],
  ),
  TerminalTheme(
    name: 'One Dark',
    background: Color(0xFF282C34),
    foreground: Color(0xFFABB2BF),
    cursor: Color(0xFF528BFF),
    ansi: [
      Color(0xFF282C34), Color(0xFFE06C75), Color(0xFF98C379), Color(0xFFE5C07B),
      Color(0xFF61AFEF), Color(0xFFC678DD), Color(0xFF56B6C2), Color(0xFFABB2BF),
      Color(0xFF5C6370), Color(0xFFE06C75), Color(0xFF98C379), Color(0xFFE5C07B),
      Color(0xFF61AFEF), Color(0xFFC678DD), Color(0xFF56B6C2), Color(0xFFFFFFFF),
    ],
  ),
  TerminalTheme(
    name: 'Solarized Light',
    background: Color(0xFFFDF6E3),
    foreground: Color(0xFF657B83),
    cursor: Color(0xFF586E75),
    ansi: [
      Color(0xFFEEE8D5), Color(0xFFDC322F), Color(0xFF859900), Color(0xFFB58900),
      Color(0xFF268BD2), Color(0xFFD33682), Color(0xFF2AA198), Color(0xFF073642),
      Color(0xFFFDF6E3), Color(0xFFCB4B16), Color(0xFF93A1A1), Color(0xFF839496),
      Color(0xFF657B83), Color(0xFF6C71C4), Color(0xFF586E75), Color(0xFF002B36),
    ],
  ),
];

/// 终端主题库 — 全局(所有会话共享一套);持久化选中的主题名。
class TerminalThemeStore {
  TerminalThemeStore._();

  static const _key = 'terminal_theme_name_v1';

  static final ValueNotifier<TerminalTheme> current =
      ValueNotifier<TerminalTheme>(kTerminalThemes.first);

  static bool _loaded = false;

  static Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final name = prefs.getString(_key);
      if (name == null) return;
      current.value = kTerminalThemes.firstWhere(
        (t) => t.name == name,
        orElse: () => kTerminalThemes.first,
      );
    } catch (_) {}
  }

  static Future<void> select(TerminalTheme theme) async {
    current.value = theme;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, theme.name);
    } catch (_) {}
  }
}
