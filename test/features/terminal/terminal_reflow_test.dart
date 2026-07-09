import 'package:flutter_test/flutter_test.dart';
import 'package:termora/features/terminal/controller/terminal_model.dart';
import 'package:termora/features/terminal/controller/terminal_reflow.dart';

TerminalLine _line(String text, {bool wrapped = false}) {
  final l = TerminalLine([TerminalSpan(text, const AnsiStyle())],
      TerminalLineType.stdout);
  l.isWrapped = wrapped;
  return l;
}

void main() {
  group('reflowTerminalLines', () {
    test('变窄:长逻辑行按新宽度重新拆分', () {
      // 一条 10 字符的逻辑行(单物理行,未折行),缩到 4 列
      final lines = [_line('abcdefghij')];
      final r = reflowTerminalLines(lines, 4);
      expect(r.lines.map((l) => l.text).toList(), ['abcd', 'efgh', 'ij']);
      expect(r.lines[0].isWrapped, isFalse);
      expect(r.lines[1].isWrapped, isTrue);
      expect(r.lines[2].isWrapped, isTrue);
    });

    test('变宽:被软折行的行合并回去', () {
      // 原来在宽 4 时被拆成 3 段(续接标记),放宽到 10 应合并成一行
      final lines = [
        _line('abcd'),
        _line('efgh', wrapped: true),
        _line('ij', wrapped: true),
      ];
      final r = reflowTerminalLines(lines, 10);
      expect(r.lines.map((l) => l.text).toList(), ['abcdefghij']);
      expect(r.lines.single.isWrapped, isFalse);
    });

    test('硬换行(非续接)的行不被合并', () {
      final lines = [_line('abc'), _line('def')];
      final r = reflowTerminalLines(lines, 10);
      expect(r.lines.map((l) => l.text).toList(), ['abc', 'def']);
    });

    test('光标映射:变窄后落到正确的物理行/列', () {
      // 逻辑行 'abcdefghij',光标在第 0 行第 6 列(指向 'g')→ 宽 4 时
      // 第 1 行(efgh)之后,应落到第 1 行末尾进位:offset6 → row1 col2
      final lines = [_line('abcdefghij')];
      final r = reflowTerminalLines(lines, 4, cursorRow: 0, cursorCol: 6);
      expect(r.cursorRow, 1);
      expect(r.cursorCol, 2);
    });

    test('光标映射:变宽合并后回到单行', () {
      // 光标在第 2 段(ij)的第 1 列 → 合并后 offset = 4+4+1 = 9
      final lines = [
        _line('abcd'),
        _line('efgh', wrapped: true),
        _line('ij', wrapped: true),
      ];
      final r = reflowTerminalLines(lines, 10, cursorRow: 2, cursorCol: 1);
      expect(r.cursorRow, 0);
      expect(r.cursorCol, 9);
    });

    test('样式在拆分后被保留', () {
      final lines = [
        TerminalLine([
          const TerminalSpan('ab', AnsiStyle(bold: true)),
          const TerminalSpan('cd', AnsiStyle(italic: true)),
        ], TerminalLineType.stdout),
      ];
      final r = reflowTerminalLines(lines, 2);
      expect(r.lines.map((l) => l.text).toList(), ['ab', 'cd']);
      expect(r.lines[0].spans.single.style.bold, isTrue);
      expect(r.lines[1].spans.single.style.italic, isTrue);
    });

    test('宽字符不被拦腰截断', () {
      // '中' 宽 2;宽 3 列里 '中中' 应拆成每行一个中(第一个占2,剩1放不下第二个)
      final lines = [_line('中中')];
      final r = reflowTerminalLines(lines, 3);
      expect(r.lines.map((l) => l.text).toList(), ['中', '中']);
    });

    test('Shell 集成标记(OSC 133)落在逻辑行首行', () {
      final l = _line('abcdefghij')
        ..isPromptStart = true
        ..commandExitCode = 0;
      final r = reflowTerminalLines([l], 4);
      // 拆成 3 行,标记只在首行
      expect(r.lines[0].isPromptStart, isTrue);
      expect(r.lines[0].commandExitCode, 0);
      expect(r.lines[1].isPromptStart, isFalse);
      expect(r.lines[2].isPromptStart, isFalse);
    });

    test('空缓冲区/非法列宽原样返回', () {
      final empty = <TerminalLine>[];
      expect(reflowTerminalLines(empty, 10).lines, isEmpty);
      final one = [_line('x')];
      expect(reflowTerminalLines(one, 0).lines, same(one));
    });
  });
}
