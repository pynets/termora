import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termora/features/terminal/controller/terminal_engine.dart';
import 'package:termora/features/terminal/controller/terminal_model.dart';

void main() {
  group('TerminalTabStops', () {
    test('reset seeds default every-8-column stops', () {
      final tabs = TerminalTabStops()..reset(80);
      expect(tabs.next(0, 80), 8);
      expect(tabs.next(8, 80), 16);
      expect(tabs.next(15, 80), 16);
      expect(tabs.previous(16), 8);
      expect(tabs.previous(8), 0);
    });

    test('next advances by count and clamps to the last column', () {
      final tabs = TerminalTabStops()..reset(80);
      expect(tabs.next(0, 80, 2), 16);
      // no stop beyond 80 -> clamp to columns - 1
      expect(tabs.next(79, 80), 79);
    });

    test('setAt / clearAt / clearAll', () {
      final tabs = TerminalTabStops()
        ..clearAll()
        ..setAt(3)
        ..setAt(10);
      expect(tabs.next(0, 80), 3);
      expect(tabs.next(3, 80), 10);
      tabs.clearAt(3);
      expect(tabs.next(0, 80), 10);
      tabs.clearAll();
      expect(tabs.next(0, 80), 79);
    });
  });

  group('TerminalPalette', () {
    final palette = TerminalPalette();

    test('standard and bright ansi colours', () {
      expect(palette.ansi(0), const Color(0xFF475569));
      expect(palette.ansi(1), const Color(0xFFDC2626));
      expect(palette.ansiBright(0), const Color(0xFF64748B));
    });

    test('256-colour cube and grayscale ramp', () {
      expect(palette.ansi256(1), palette.ansi(1));
      expect(palette.ansi256(9), palette.ansiBright(1));
      expect(palette.ansi256(16), const Color(0xFF000000));
      expect(palette.ansi256(21), const Color(0xFF0000FF));
      expect(palette.ansi256(232), const Color(0xFF080808));
    });

    test('overrides and clearing', () {
      final p = TerminalPalette()..setColor(1, const Color(0xFF010203));
      expect(p.ansi(1), const Color(0xFF010203));
      p.resetColor(1);
      expect(p.ansi(1), const Color(0xFFDC2626));
    });

    test('xtermRgb formatting', () {
      expect(TerminalPalette.xtermRgb(const Color(0xFF112233)), 'rgb:1111/2222/3333');
    });

    test('主题基色作为默认,程序 OSC 4 覆盖仍生效,OSC 104 回退到主题', () {
      final themeAnsi = <Color>[
        for (var i = 0; i < 16; i++) Color(0xFF000000 | (i * 0x101010)),
      ];
      final p = TerminalPalette()..applyThemeAnsi(themeAnsi);
      expect(p.ansi(1), themeAnsi[1]); // 主题基色
      expect(p.ansiBright(0), themeAnsi[8]); // 明亮段来自主题 8-15
      p.setColor(1, const Color(0xFF999999)); // 程序覆盖
      expect(p.ansi(1), const Color(0xFF999999));
      p.clear(); // OSC 104:清程序覆盖,回到主题而非内置默认
      expect(p.ansi(1), themeAnsi[1]);
      p.applyThemeAnsi(null); // 跟随应用
      expect(p.ansi(1), const Color(0xFFDC2626));
    });
  });

  group('TerminalCharset', () {
    test('passes characters through when line-drawing is off', () {
      expect(const TerminalCharset().map('q'), 'q');
    });

    test('maps DEC special graphics when g0 line-drawing is on', () {
      const charset = TerminalCharset(g0LineDrawing: true);
      expect(charset.map('q'), '─');
      expect(charset.map('x'), '│');
      expect(charset.map('A'), 'A');
    });

    test('selects the active G0/G1 slot', () {
      expect(const TerminalCharset(g1LineDrawing: true, useG1: true).map('q'), '─');
      // useG1 but the G1 slot is not line-drawing -> passthrough
      expect(const TerminalCharset(g0LineDrawing: true, useG1: true).map('q'), 'q');
    });
  });

  group('TerminalSgr', () {
    final palette = TerminalPalette();

    test('parse basics', () {
      expect(TerminalSgr.parse(''), [0]);
      expect(TerminalSgr.parse('1;3'), [1, 3]);
    });

    test('attribute toggles', () {
      expect(TerminalSgr.apply(const AnsiStyle(), '1', palette).bold, isTrue);
      expect(TerminalSgr.apply(const AnsiStyle(), '3', palette).italic, isTrue);
      expect(
        TerminalSgr.apply(const AnsiStyle(bold: true, italic: true), '0', palette),
        const AnsiStyle(),
      );
    });

    test('blink attribute (SGR 5/6 on, 25 off)', () {
      expect(TerminalSgr.apply(const AnsiStyle(), '5', palette).blink, isTrue);
      expect(TerminalSgr.apply(const AnsiStyle(), '6', palette).blink, isTrue);
      expect(
        TerminalSgr.apply(const AnsiStyle(blink: true), '25', palette).blink,
        isFalse,
      );
      // 往返:blink 序列化回 SGR 5
      expect(
        TerminalSgr.toParameters(const AnsiStyle(blink: true)).split(';'),
        contains('5'),
      );
      // SGR 0 清除闪烁
      expect(
        TerminalSgr.apply(const AnsiStyle(blink: true), '0', palette).blink,
        isFalse,
      );
    });

    test('standard and extended colours', () {
      expect(
        TerminalSgr.apply(const AnsiStyle(), '31', palette).foreground,
        palette.ansi(1),
      );
      expect(
        TerminalSgr.apply(const AnsiStyle(), '38;5;21', palette).foreground,
        const Color(0xFF0000FF),
      );
      expect(
        TerminalSgr.apply(const AnsiStyle(), '38;2;10;20;30', palette).foreground,
        const Color.fromARGB(255, 10, 20, 30),
      );
    });

    test('underline styles including colon form', () {
      expect(
        TerminalSgr.apply(const AnsiStyle(), '4', palette).underlineStyle,
        TextDecorationStyle.solid,
      );
      expect(
        TerminalSgr.apply(const AnsiStyle(), '4:3', palette).underlineStyle,
        TextDecorationStyle.wavy,
      );
    });

    test('serialization round-trips attributes', () {
      expect(
        TerminalSgr.toParameters(const AnsiStyle(bold: true, italic: true)),
        '1;3',
      );
      expect(TerminalSgr.toParameters(const AnsiStyle()), '0');
    });
  });

  group('TerminalInputEncoder', () {
    test('cursor and tilde sequences honour modifiers and DECCKM', () {
      const normal = TerminalInputEncoder();
      const appCursor = TerminalInputEncoder(applicationCursorMode: true);
      expect(normal.cursorSequence('A', 1), '\x1b[A');
      expect(appCursor.cursorSequence('A', 1), '\x1bOA');
      expect(normal.cursorSequence('A', 2), '\x1b[1;2A');
      expect(normal.tildeSequence(3, 1), '\x1b[3~');
      expect(normal.tildeSequence(3, 2), '\x1b[3;2~');
    });

    test('xtermModifier bit packing', () {
      expect(
        TerminalInputEncoder.xtermModifier(shift: false, alt: false, control: false),
        1,
      );
      expect(
        TerminalInputEncoder.xtermModifier(shift: true, alt: false, control: false),
        2,
      );
      expect(
        TerminalInputEncoder.xtermModifier(shift: false, alt: true, control: true),
        7,
      );
    });

    test('mouse reports', () {
      expect(
        TerminalInputEncoder.legacyMouseSequence(code: 0, column: 1, row: 1),
        '\x1b[M\x20\x21\x21',
      );
      expect(
        TerminalInputEncoder.legacyMouseSequence(code: 0, column: 224, row: 1),
        isNull,
      );
      expect(
        TerminalInputEncoder.urxvtMouseSequence(code: 0, column: 5, row: 6),
        '\x1b[32;5;6M',
      );
    });

    test('payloadForKey encodes special and printable keys', () {
      const encoder = TerminalInputEncoder();
      final up = _keyDown(LogicalKeyboardKey.arrowUp, PhysicalKeyboardKey.arrowUp);
      expect(
        encoder.payloadForKey(up, control: false, meta: false, shift: false, alt: false),
        '\x1b[A',
      );
      final a = _keyDown(
        LogicalKeyboardKey.keyA,
        PhysicalKeyboardKey.keyA,
        character: 'a',
      );
      expect(
        encoder.payloadForKey(a, control: false, meta: false, shift: false, alt: false),
        'a',
      );
      // Meta-modified keys are handled as app shortcuts -> null.
      expect(
        encoder.payloadForKey(a, control: false, meta: true, shift: false, alt: false),
        isNull,
      );
    });
  });

  group('terminal_model', () {
    test('cell width handles wide and combining runes', () {
      expect(terminalCellWidth('abc'), 3);
      expect(terminalCellWidth('中'), 2);
      expect(terminalCellWidth('a中'), 3);
      expect(terminalRuneCellWidth(0x0301), 0); // combining acute accent
    });

    test('Unicode 15 零宽格式符不占格', () {
      expect(terminalRuneCellWidth(0x200D), 0); // ZWJ
      expect(terminalRuneCellWidth(0x200B), 0); // 零宽空格
      expect(terminalRuneCellWidth(0xFE0F), 0); // 变体选择符 VS16
      expect(terminalRuneCellWidth(0xFEFF), 0); // ZWNBSP/BOM
      expect(terminalRuneCellWidth(0xE0101), 0); // 变体选择符补充
    });

    test('emoji + VS16 不再多算一格', () {
      // ❤(U+2764,窄)+ VS16(0 宽)= 1 格,之前会算成 2
      expect(terminalCellWidth('❤️'), 1);
      // 单个 emoji 表情(宽)= 2 格
      expect(terminalRuneCellWidth(0x1F600), 2); // 😀
      expect(terminalRuneCellWidth(0x1F004), 2); // 🀄
      expect(terminalRuneCellWidth(0x1F251), 2); // 封闭表意补充
    });

    test('TerminalLine.plain exposes text/length/type', () {
      final line = TerminalLine.plain('hi', TerminalLineType.stdout);
      expect(line.text, 'hi');
      expect(line.length, 2);
      expect(line.type, TerminalLineType.stdout);
    });

    test('writeAt overwrites a cell in place', () {
      final line = TerminalLine.plain('abc', TerminalLineType.stdout);
      line.writeAt(1, 'X', const AnsiStyle());
      expect(line.text, 'aXc');
    });

    test('writeAt pads addressing gaps with default background', () {
      // 光标寻址跳过的格子 = 从未写过,不能带上当前 SGR 背景,
      // 否则彩底样式活跃时制表/列寻址会拖出色带
      final line = TerminalLine.plain('ab', TerminalLineType.stdout);
      const styled = AnsiStyle(background: Color(0xFF0000FF));
      line.writeAt(6, 'X', styled);
      expect(line.text, 'ab    X');
      // 空隙与前缀同为默认样式,会合并成一个 span;背景只落在 X 上
      expect(line.spans, hasLength(2));
      expect(line.spans[0].text, 'ab    ');
      expect(line.spans[0].style.background, isNull);
      expect(line.spans[1].style.background, const Color(0xFF0000FF));
    });

    test('fillBlank without background yields an empty line', () {
      final line = TerminalLine.plain('old', TerminalLineType.stdout);
      line.fillBlank(80, const AnsiStyle());
      expect(line.text, isEmpty);
    });

    test('fillBlank with background fills full width (BCE)', () {
      final line = TerminalLine.plain('old', TerminalLineType.stdout);
      const styled = AnsiStyle(background: Color(0xFF00FF00));
      line.fillBlank(10, styled);
      expect(line.text, ' ' * 10);
      expect(line.spans.single.style.background, const Color(0xFF00FF00));
    });

    test('AnsiStyle equality and copyWith', () {
      expect(const AnsiStyle(bold: true), const AnsiStyle(bold: true));
      expect(const AnsiStyle(bold: true).copyWith(bold: false).bold, isFalse);
      expect(const AnsiStyle().copyWith(italic: true).italic, isTrue);
    });
  });
}

KeyDownEvent _keyDown(
  LogicalKeyboardKey logical,
  PhysicalKeyboardKey physical, {
  String? character,
}) {
  return KeyDownEvent(
    physicalKey: physical,
    logicalKey: logical,
    character: character,
    timeStamp: Duration.zero,
  );
}
