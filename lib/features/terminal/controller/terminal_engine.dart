import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:termora/features/terminal/controller/terminal_model.dart';

/// Encodes keyboard and mouse input into xterm-compatible byte sequences.
///
/// This is pure logic extracted from the terminal widget so it can be reasoned
/// about and unit-tested in isolation. Construct it with the terminal's current
/// input modes; instances are cheap and immutable.
class TerminalInputEncoder {
  const TerminalInputEncoder({
    this.applicationCursorMode = false,
    this.applicationKeypadMode = false,
    this.modifyOtherKeysMode = 0,
  });

  final bool applicationCursorMode;
  final bool applicationKeypadMode;
  final int modifyOtherKeysMode;

  /// Encodes [event] into the bytes to write to the PTY, or null when the key
  /// should be ignored. Meta-modified keys return null (they are handled by the
  /// widget as app shortcuts before reaching here).
  String? payloadForKey(
    KeyEvent event, {
    required bool control,
    required bool meta,
    required bool shift,
    required bool alt,
  }) {
    final key = event.logicalKey;
    if (meta) return null;
    if (control) {
      final controlPayload = _controlPayloadForKey(key);
      if (controlPayload != null) return controlPayload;
    }

    final modifier = xtermModifier(shift: shift, alt: alt, control: control);
    if (applicationKeypadMode && modifier == 1) {
      final keypadPayload = _applicationKeypadPayloadForKey(key);
      if (keypadPayload != null) return keypadPayload;
    }
    String? payload;
    switch (key) {
      case LogicalKeyboardKey.escape:
        payload = '\x1b';
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        payload = '\r';
      case LogicalKeyboardKey.tab:
        payload = shift ? '\x1b[Z' : '\t';
      case LogicalKeyboardKey.backspace:
        payload = '\x7f';
      case LogicalKeyboardKey.delete:
        payload = tildeSequence(3, modifier);
      case LogicalKeyboardKey.insert:
        payload = tildeSequence(2, modifier);
      case LogicalKeyboardKey.home:
        payload = cursorSequence('H', modifier);
      case LogicalKeyboardKey.end:
        payload = cursorSequence('F', modifier);
      case LogicalKeyboardKey.pageUp:
        payload = tildeSequence(5, modifier);
      case LogicalKeyboardKey.pageDown:
        payload = tildeSequence(6, modifier);
      case LogicalKeyboardKey.arrowUp:
        payload = cursorSequence('A', modifier);
      case LogicalKeyboardKey.arrowDown:
        payload = cursorSequence('B', modifier);
      case LogicalKeyboardKey.arrowRight:
        payload = cursorSequence('C', modifier);
      case LogicalKeyboardKey.arrowLeft:
        payload = cursorSequence('D', modifier);
      case LogicalKeyboardKey.f1:
        payload = modifier == 1 ? '\x1bOP' : '\x1b[1;${modifier}P';
      case LogicalKeyboardKey.f2:
        payload = modifier == 1 ? '\x1bOQ' : '\x1b[1;${modifier}Q';
      case LogicalKeyboardKey.f3:
        payload = modifier == 1 ? '\x1bOR' : '\x1b[1;${modifier}R';
      case LogicalKeyboardKey.f4:
        payload = modifier == 1 ? '\x1bOS' : '\x1b[1;${modifier}S';
      case LogicalKeyboardKey.f5:
        payload = tildeSequence(15, modifier);
      case LogicalKeyboardKey.f6:
        payload = tildeSequence(17, modifier);
      case LogicalKeyboardKey.f7:
        payload = tildeSequence(18, modifier);
      case LogicalKeyboardKey.f8:
        payload = tildeSequence(19, modifier);
      case LogicalKeyboardKey.f9:
        payload = tildeSequence(20, modifier);
      case LogicalKeyboardKey.f10:
        payload = tildeSequence(21, modifier);
      case LogicalKeyboardKey.f11:
        payload = tildeSequence(23, modifier);
      case LogicalKeyboardKey.f12:
        payload = tildeSequence(24, modifier);
      default:
        payload = null;
    }
    if (payload != null) return payload;

    final character = event.character;
    if (character == null || character.isEmpty) return null;
    final modifiedPayload = _modifiedPrintablePayload(
      character,
      modifier,
      alt: alt,
      control: control,
    );
    if (modifiedPayload != null) return modifiedPayload;
    if (alt) return '\x1b$character';
    return character;
  }

  /// The xterm modifier parameter (1 = none, +1 shift, +2 alt, +4 control).
  static int xtermModifier({
    required bool shift,
    required bool alt,
    required bool control,
  }) {
    var modifier = 1;
    if (shift) modifier += 1;
    if (alt) modifier += 2;
    if (control) modifier += 4;
    return modifier;
  }

  /// Cursor-key sequence for [finalChar] (A/B/C/D/H/F) with the given modifier,
  /// honouring DECCKM (application cursor mode).
  String cursorSequence(String finalChar, int modifier) {
    if (modifier != 1) return '\x1b[1;$modifier$finalChar';
    if (applicationCursorMode) return '\x1bO$finalChar';
    return '\x1b[$finalChar';
  }

  /// `CSI code ~` style sequence (Insert/Delete/PageUp/…/function keys).
  String tildeSequence(int code, int modifier) {
    if (modifier == 1) return '\x1b[$code~';
    return '\x1b[$code;$modifier~';
  }

  String? _modifiedPrintablePayload(
    String character,
    int modifier, {
    required bool alt,
    required bool control,
  }) {
    if (modifyOtherKeysMode <= 0) return null;
    if (!alt && !control) return null;
    final runes = character.runes.toList(growable: false);
    if (runes.length != 1) return null;
    return '\x1b[27;$modifier;${runes.single}~';
  }

  String? _applicationKeypadPayloadForKey(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.numpadEnter) return '\x1bOM';
    if (key == LogicalKeyboardKey.numpad0) return '\x1bOp';
    if (key == LogicalKeyboardKey.numpad1) return '\x1bOq';
    if (key == LogicalKeyboardKey.numpad2) return '\x1bOr';
    if (key == LogicalKeyboardKey.numpad3) return '\x1bOs';
    if (key == LogicalKeyboardKey.numpad4) return '\x1bOt';
    if (key == LogicalKeyboardKey.numpad5) return '\x1bOu';
    if (key == LogicalKeyboardKey.numpad6) return '\x1bOv';
    if (key == LogicalKeyboardKey.numpad7) return '\x1bOw';
    if (key == LogicalKeyboardKey.numpad8) return '\x1bOx';
    if (key == LogicalKeyboardKey.numpad9) return '\x1bOy';
    if (key == LogicalKeyboardKey.numpadDecimal) return '\x1bOn';
    if (key == LogicalKeyboardKey.numpadAdd) return '\x1bOk';
    if (key == LogicalKeyboardKey.numpadSubtract) return '\x1bOm';
    if (key == LogicalKeyboardKey.numpadMultiply) return '\x1bOj';
    if (key == LogicalKeyboardKey.numpadDivide) return '\x1bOo';
    return null;
  }

  static String? _controlPayloadForKey(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.space) return '\x00';
    if (key == LogicalKeyboardKey.bracketLeft) return '\x1b';
    if (key == LogicalKeyboardKey.backslash) return '\x1c';
    if (key == LogicalKeyboardKey.bracketRight) return '\x1d';
    if (key == LogicalKeyboardKey.digit6) return '\x1e';
    if (key == LogicalKeyboardKey.minus || key == LogicalKeyboardKey.slash) {
      return '\x1f';
    }
    final keyLabel = key.keyLabel;
    if (keyLabel.length == 1) {
      final codeUnit = keyLabel.toUpperCase().codeUnitAt(0);
      if (codeUnit >= 0x41 && codeUnit <= 0x5A) {
        return String.fromCharCode(codeUnit - 0x40);
      }
    }
    return null;
  }

  /// X10 mouse report (button/motion at column/row). Null when out of range.
  static String? legacyMouseSequence({
    required int code,
    required int column,
    required int row,
  }) {
    if (column > 223 || row > 223) return null;
    return '\x1b[M${String.fromCharCode(code + 32)}'
        '${String.fromCharCode(column + 32)}'
        '${String.fromCharCode(row + 32)}';
  }

  /// urxvt (1015) mouse report.
  static String urxvtMouseSequence({
    required int code,
    required int column,
    required int row,
  }) {
    return '\x1b[${code + 32};$column;${row}M';
  }

  /// UTF-8 (1005) mouse report. Null when out of range.
  static String? utf8MouseSequence({
    required int code,
    required int column,
    required int row,
  }) {
    if (column > 2015 || row > 2015) return null;
    return '\x1b[M${String.fromCharCode(code + 32)}'
        '${String.fromCharCode(column + 32)}'
        '${String.fromCharCode(row + 32)}';
  }
}

/// Resolves ANSI, bright, and 256-colour indices to concrete colours, honouring
/// OSC 4 palette overrides. Pure logic, unit-testable in isolation.
class TerminalPalette {
  final Map<int, Color> _custom = <int, Color>{};

  /// 深色主题下改用语义忠实的深色默认调色板;由宿主(终端组件)按
  /// 应用主题设置,引擎本身保持无 UI 依赖。
  bool darkDefaults = false;

  /// 浅色背景的 ANSI 0-7:白/亮白映射为深灰,保证浅底可读
  static const List<Color> _baseLight = <Color>[
    Color(0xFF475569),
    Color(0xFFDC2626),
    Color(0xFF16A34A),
    Color(0xFFCA8A04),
    Color(0xFF2563EB),
    Color(0xFFC026D3),
    Color(0xFF0891B2),
    Color(0xFF334155),
  ];

  static const List<Color> _brightLight = <Color>[
    Color(0xFF64748B),
    Color(0xFFEF4444),
    Color(0xFF22C55E),
    Color(0xFFEAB308),
    Color(0xFF3B82F6),
    Color(0xFFD946EF),
    Color(0xFF06B6D4),
    Color(0xFF0F172A),
  ];

  /// 深色背景的 ANSI 0-7:语义忠实(白就是亮色、黑是可见的深灰);
  /// 之前深底也用浅色特调,白/亮白被映射成近黑,vim 状态栏这类
  /// "白字"直接消失
  static const List<Color> _baseDark = <Color>[
    Color(0xFF45475A),
    Color(0xFFF87171),
    Color(0xFF4ADE80),
    Color(0xFFFACC15),
    Color(0xFF60A5FA),
    Color(0xFFE879F9),
    Color(0xFF22D3EE),
    Color(0xFFE4E4E7),
  ];

  static const List<Color> _brightDark = <Color>[
    Color(0xFF71717A),
    Color(0xFFFCA5A5),
    Color(0xFF86EFAC),
    Color(0xFFFDE047),
    Color(0xFF93C5FD),
    Color(0xFFF0ABFC),
    Color(0xFF67E8F9),
    Color(0xFFFFFFFF),
  ];

  /// 主题基色(16 项:0-7 常规、8-15 明亮);null=用内置深/浅默认。
  /// 作为「基础默认」,程序的 OSC 4 覆盖(_custom)仍叠在其上。
  List<Color>? _themeAnsi;

  void applyThemeAnsi(List<Color>? sixteen) {
    _themeAnsi = (sixteen != null && sixteen.length >= 16) ? sixteen : null;
  }

  List<Color> get _base =>
      _themeAnsi?.sublist(0, 8) ?? (darkDefaults ? _baseDark : _baseLight);
  List<Color> get _bright =>
      _themeAnsi?.sublist(8, 16) ?? (darkDefaults ? _brightDark : _brightLight);

  /// One of the 8 standard ANSI colours (index 0-7), or its palette override.
  Color ansi(int index) {
    final safe = index.clamp(0, _base.length - 1);
    return _custom[safe] ?? _base[safe];
  }

  /// One of the 8 bright ANSI colours (index 0-7 → palette 8-15).
  Color ansiBright(int index) {
    final safe = index.clamp(0, _bright.length - 1);
    return _custom[safe + 8] ?? _bright[safe];
  }

  /// A colour from the 256-colour cube (0-255), honouring overrides.
  Color ansi256(int value) {
    final safe = value.clamp(0, 255);
    final custom = _custom[safe];
    if (custom != null) return custom;
    if (safe < 8) return ansi(safe);
    if (safe < 16) return ansiBright(safe - 8);
    if (safe >= 232) {
      final level = 8 + (safe - 232) * 10;
      return Color.fromARGB(255, level, level, level);
    }
    final color = safe - 16;
    final red = color ~/ 36;
    final green = (color % 36) ~/ 6;
    final blue = color % 6;
    int component(int channel) => channel == 0 ? 0 : 55 + channel * 40;
    return Color.fromARGB(
      255,
      component(red),
      component(green),
      component(blue),
    );
  }

  void setColor(int index, Color color) => _custom[index] = color;
  void resetColor(int index) => _custom.remove(index);
  void clear() => _custom.clear();

  /// Formats a colour as an xterm `rgb:RRRR/GGGG/BBBB` string (OSC replies).
  static String xtermRgb(Color color) {
    String component(double value) {
      final channel = (value.clamp(0.0, 1.0) * 65535).round();
      return channel.toRadixString(16).padLeft(4, '0');
    }

    return 'rgb:${component(color.r)}/${component(color.g)}/${component(color.b)}';
  }
}

/// Maps printable characters through the active DEC charset. When line-drawing
/// (DEC Special Graphics) is selected for the active G0/G1 slot, ASCII letters
/// are translated into box-drawing glyphs. Pure logic, unit-testable.
class TerminalCharset {
  const TerminalCharset({
    this.g0LineDrawing = false,
    this.g1LineDrawing = false,
    this.useG1 = false,
  });

  final bool g0LineDrawing;
  final bool g1LineDrawing;
  final bool useG1;

  /// Translates [char] for the active charset slot, or returns it unchanged.
  String map(String char) {
    final useLineDrawing = useG1 ? g1LineDrawing : g0LineDrawing;
    if (!useLineDrawing) return char;
    return lineDrawing(char);
  }

  /// The DEC Special Graphics glyph for [char], or [char] if not a mapped key.
  static String lineDrawing(String char) {
    switch (char) {
      case '`':
        return '◆';
      case 'a':
        return '▒';
      case 'f':
        return '°';
      case 'g':
        return '±';
      case 'j':
        return '┘';
      case 'k':
        return '┐';
      case 'l':
        return '┌';
      case 'm':
        return '└';
      case 'n':
        return '┼';
      case 'o':
        return '⎺';
      case 'p':
        return '⎻';
      case 'q':
        return '─';
      case 'r':
        return '⎼';
      case 's':
        return '⎽';
      case 't':
        return '├';
      case 'u':
        return '┤';
      case 'v':
        return '┴';
      case 'w':
        return '┬';
      case 'x':
        return '│';
      case 'y':
        return '≤';
      case 'z':
        return '≥';
      case '{':
        return 'π';
      case '|':
        return '≠';
      case '}':
        return '£';
      case '~':
        return '·';
      default:
        return char;
    }
  }
}

/// Parses, applies, and serializes SGR (`CSI … m`) graphic-rendition
/// parameters. Pure logic over [AnsiStyle] + a [TerminalPalette].
class TerminalSgr {
  const TerminalSgr._();

  /// Base sentinel for the colon-form extended underline styles (`4:0`…`4:5`),
  /// encoded by [parse] as negative pseudo-parameters.
  static const int extendedUnderlineBase = -4000;

  /// Applies the SGR parameter string [params] to [style]; empty resets (SGR 0).
  static AnsiStyle apply(
    AnsiStyle style,
    String params,
    TerminalPalette palette,
  ) {
    final values = parse(params);
    for (var index = 0; index < values.length; index++) {
      final value = values[index];
      switch (value) {
        case 0:
          style = const AnsiStyle();
        case 1:
          style = style.copyWith(bold: true);
        case 2:
          style = style.copyWith(dim: true);
        case 3:
          style = style.copyWith(italic: true);
        case 4:
          style = style.copyWith(
            underline: true,
            underlineStyle: TextDecorationStyle.solid,
          );
        case 5: // 慢闪
        case 6: // 快闪(同等对待)
          style = style.copyWith(blink: true);
        case 7:
          style = style.copyWith(inverse: true);
        case 8:
          style = style.copyWith(invisible: true);
        case 9:
          style = style.copyWith(strikethrough: true);
        case 21:
          style = style.copyWith(
            underline: true,
            underlineStyle: TextDecorationStyle.double,
          );
        case 22:
          style = style.copyWith(bold: false, dim: false);
        case 23:
          style = style.copyWith(italic: false);
        case 24:
          style = style.copyWith(underline: false, clearUnderlineStyle: true);
        case 25:
          style = style.copyWith(blink: false);
        case 27:
          style = style.copyWith(inverse: false);
        case 28:
          style = style.copyWith(invisible: false);
        case 29:
          style = style.copyWith(strikethrough: false);
        case 39:
          style = style.copyWith(clearForeground: true);
        case 49:
          style = style.copyWith(clearBackground: true);
        case 53:
          style = style.copyWith(overline: true);
        case 55:
          style = style.copyWith(overline: false);
        case 58:
          final color = _readExtendedColor(values, index, palette);
          if (color.$1 != null) {
            style = style.copyWith(decorationColor: color.$1);
          }
          index = color.$2;
        case 59:
          style = style.copyWith(clearDecorationColor: true);
        case <= extendedUnderlineBase && >= extendedUnderlineBase - 5:
          style = _applyExtendedUnderline(style, extendedUnderlineBase - value);
        case >= 30 && <= 37:
          style = style.copyWith(foreground: palette.ansi(value - 30));
        case >= 90 && <= 97:
          style = style.copyWith(foreground: palette.ansiBright(value - 90));
        case >= 40 && <= 47:
          style = style.copyWith(background: palette.ansi(value - 40));
        case >= 100 && <= 107:
          style = style.copyWith(background: palette.ansiBright(value - 100));
        case 38:
          final color = _readExtendedColor(values, index, palette);
          if (color.$1 != null) {
            style = style.copyWith(foreground: color.$1);
          }
          index = color.$2;
        case 48:
          final color = _readExtendedColor(values, index, palette);
          if (color.$1 != null) {
            style = style.copyWith(background: color.$1);
          }
          index = color.$2;
        default:
          break;
      }
    }
    return style;
  }

  static (Color?, int) _readExtendedColor(
    List<int> values,
    int index,
    TerminalPalette palette,
  ) {
    if (index + 1 >= values.length) return (null, index);
    final mode = values[index + 1];
    if (mode == 2 && index + 4 < values.length) {
      return (
        Color.fromARGB(
          255,
          values[index + 2].clamp(0, 255),
          values[index + 3].clamp(0, 255),
          values[index + 4].clamp(0, 255),
        ),
        index + 4,
      );
    }
    if (mode == 5 && index + 2 < values.length) {
      return (palette.ansi256(values[index + 2]), index + 2);
    }
    return (null, index);
  }

  static AnsiStyle _applyExtendedUnderline(
    AnsiStyle style,
    int underlineStyle,
  ) {
    switch (underlineStyle) {
      case 0:
        return style.copyWith(underline: false, clearUnderlineStyle: true);
      case 2:
        return style.copyWith(
          underline: true,
          underlineStyle: TextDecorationStyle.double,
        );
      case 3:
        return style.copyWith(
          underline: true,
          underlineStyle: TextDecorationStyle.wavy,
        );
      case 4:
        return style.copyWith(
          underline: true,
          underlineStyle: TextDecorationStyle.dotted,
        );
      case 5:
        return style.copyWith(
          underline: true,
          underlineStyle: TextDecorationStyle.dashed,
        );
      default:
        return style.copyWith(
          underline: true,
          underlineStyle: TextDecorationStyle.solid,
        );
    }
  }

  /// Serializes [style] back to an SGR parameter string (for DECRQSS replies).
  static String toParameters(AnsiStyle style) {
    final values = <String>[];
    if (style.bold) values.add('1');
    if (style.dim) values.add('2');
    if (style.italic) values.add('3');
    if (style.underline) values.add(_underlineParameter(style.underlineStyle));
    if (style.blink) values.add('5');
    if (style.inverse) values.add('7');
    if (style.invisible) values.add('8');
    if (style.strikethrough) values.add('9');
    if (style.overline) values.add('53');
    final foreground = style.foreground;
    if (foreground != null) values.add(_rgbParameter(38, foreground));
    final background = style.background;
    if (background != null) values.add(_rgbParameter(48, background));
    final decorationColor = style.decorationColor;
    if (decorationColor != null) values.add(_rgbParameter(58, decorationColor));
    return values.isEmpty ? '0' : values.join(';');
  }

  static String _underlineParameter(TextDecorationStyle? style) {
    return switch (style) {
      TextDecorationStyle.double => '21',
      TextDecorationStyle.wavy => '4:3',
      TextDecorationStyle.dotted => '4:4',
      TextDecorationStyle.dashed => '4:5',
      _ => '4',
    };
  }

  static String _rgbParameter(int prefix, Color color) {
    return '$prefix;2;${_colorChannel(color.r)};'
        '${_colorChannel(color.g)};${_colorChannel(color.b)}';
  }

  static int _colorChannel(double value) =>
      (value.clamp(0.0, 1.0) * 255).round();

  /// Parses an SGR parameter string into a flat integer list, encoding
  /// colon-form extended underline styles as negative sentinels.
  static List<int> parse(String params) {
    if (params.isEmpty) return <int>[0];
    final values = <int>[];
    for (final part in params.split(';')) {
      if (part.contains(':')) {
        values.addAll(_parseColon(part));
      } else {
        values.add(int.tryParse(part) ?? 0);
      }
    }
    return values.isEmpty ? <int>[0] : values;
  }

  static List<int> _parseColon(String part) {
    final segments = part.split(':');
    if (segments.isEmpty) return const [0];
    final head = int.tryParse(segments.first);
    if (head == 4) {
      final style = segments.length > 1 ? int.tryParse(segments[1]) ?? 1 : 1;
      return <int>[extendedUnderlineBase - style.clamp(0, 5)];
    }
    if (head != 38 && head != 48 && head != 58) {
      return [for (final segment in segments) int.tryParse(segment) ?? 0];
    }
    final headValue = head ?? 0;
    final values = <int>[headValue];
    final tail = segments
        .skip(1)
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    final mode = tail.isEmpty ? null : int.tryParse(tail.first);
    if (mode == 2) {
      final numericTail = tail
          .skip(1)
          .map((segment) => int.tryParse(segment) ?? 0)
          .toList(growable: false);
      final rgb = numericTail.length >= 3
          ? numericTail.sublist(numericTail.length - 3)
          : numericTail;
      values
        ..add(2)
        ..addAll(rgb.take(3));
      while (values.length < 5) {
        values.add(0);
      }
      return values;
    }
    if (mode == 5) {
      final colorIndex = tail.length > 1
          ? int.tryParse(tail.elementAt(1)) ?? 0
          : 0;
      return <int>[headValue, 5, colorIndex];
    }
    return [for (final segment in segments) int.tryParse(segment) ?? 0];
  }
}

/// Horizontal tab stops for the terminal grid. Stops are column indices; the
/// default grid places one every 8 columns. Pure logic, unit-testable.
class TerminalTabStops {
  final Set<int> _stops = <int>{};

  /// Clears all stops and re-seeds the default every-8-columns grid up to
  /// [coverColumns].
  void reset(int coverColumns) {
    _stops.clear();
    ensureCovers(coverColumns);
  }

  /// Ensures default stops exist up to [coverColumns] (does not remove any).
  void ensureCovers(int coverColumns) {
    for (var column = 8; column <= coverColumns; column += 8) {
      _stops.add(column);
    }
  }

  void setAt(int column) => _stops.add(column);
  void clearAt(int column) => _stops.remove(column);
  void clearAll() => _stops.clear();

  /// The column after advancing [count] tab stops from [from], clamped to the
  /// last column of a [columns]-wide grid.
  int next(int from, int columns, [int count = 1]) {
    var column = from;
    final maxColumn = math.max(0, columns - 1);
    for (var i = 0; i < count; i++) {
      final candidates = _stops.where((stop) => stop > column).toList()..sort();
      column = candidates.isEmpty
          ? maxColumn
          : math.min(candidates.first, maxColumn);
    }
    return column;
  }

  /// The column after moving back [count] tab stops from [from] (min 0).
  int previous(int from, [int count = 1]) {
    var column = from;
    for (var i = 0; i < count; i++) {
      final candidates = _stops.where((stop) => stop < column).toList()..sort();
      column = candidates.isEmpty ? 0 : candidates.last;
    }
    return math.max(0, column);
  }
}

/// The terminal window title plus its save/restore stack (XTPUSHTITLE /
/// XTPOPTITLE and OSC 0/2). Pure state, unit-testable.
class TerminalTitleStack {
  static const int _maxDepth = 20;

  String? current;
  final List<String?> _stack = <String?>[];

  /// The title to display, falling back to a default when none is set.
  String get effective {
    final title = current;
    return (title != null && title.isNotEmpty) ? title : 'Termora Terminal';
  }

  void save() {
    _stack.add(current);
    if (_stack.length > _maxDepth) _stack.removeAt(0);
  }

  void restore() {
    if (_stack.isEmpty) return;
    current = _stack.removeLast();
  }

  void reset() {
    current = null;
    _stack.clear();
  }
}
