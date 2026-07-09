import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termora/features/terminal/controller/terminal_model.dart';
import 'package:termora/features/terminal/data/highlight_store.dart';

TerminalLine _line(List<TerminalSpan> spans) =>
    TerminalLine(spans, TerminalLineType.stdout);

const _red = Color(0xFFFF0000);

void main() {
  group('HighlightStore.apply', () {
    test('无规则时原样返回同一对象', () {
      final line = _line([TerminalSpan('hello', const AnsiStyle())]);
      expect(identical(HighlightStore.apply(line, const []), line), isTrue);
    });

    test('整行规则命中:所有 span 前景被覆盖', () {
      final line = _line([
        TerminalSpan('build ', const AnsiStyle()),
        TerminalSpan('ERROR here', const AnsiStyle(foreground: Color(0xFF00FF00))),
      ]);
      final rule = HighlightRule(
        id: '1',
        name: 'e',
        pattern: 'ERROR',
        color: _red,
      );
      final out = HighlightStore.apply(line, [rule]);
      expect(out.text, 'build ERROR here');
      for (final s in out.spans) {
        expect(s.style.foreground, _red);
        expect(s.style.bold, isTrue);
      }
    });

    test('不命中:原样返回', () {
      final line = _line([TerminalSpan('all good', const AnsiStyle())]);
      final rule = HighlightRule(
        id: '1',
        name: 'e',
        pattern: 'ERROR',
        color: _red,
      );
      expect(HighlightStore.apply(line, [rule]).text, 'all good');
      expect(
        HighlightStore.apply(line, [rule]).spans.first.style.foreground,
        isNull,
      );
    });

    test('片段规则:只有命中子串被上色,跨 span 切分正确', () {
      final line = _line([
        TerminalSpan('warn:', const AnsiStyle()),
        TerminalSpan('FAILok', const AnsiStyle()),
      ]);
      final rule = HighlightRule(
        id: '2',
        name: 'f',
        pattern: 'FAIL',
        color: _red,
        wholeLine: false,
      );
      final out = HighlightStore.apply(line, [rule]);
      expect(out.text, 'warn:FAILok');
      // 拼出 (文本, 是否红) 序列,验证只有 FAIL 段是红
      final colored = {
        for (final s in out.spans) s.text: s.style.foreground == _red,
      };
      expect(colored['FAIL'], isTrue);
      expect(colored.entries.where((e) => e.value).map((e) => e.key).join(),
          'FAIL');
    });

    test('禁用的规则不生效', () {
      final line = _line([TerminalSpan('ERROR', const AnsiStyle())]);
      final rule = HighlightRule(
        id: '3',
        name: 'e',
        pattern: 'ERROR',
        color: _red,
        enabled: false,
      );
      expect(HighlightStore.apply(line, [rule]).spans.first.style.foreground,
          isNull);
    });

    test('大小写不敏感(默认)命中', () {
      final line = _line([TerminalSpan('error', const AnsiStyle())]);
      final rule = HighlightRule(
        id: '4',
        name: 'e',
        pattern: 'ERROR',
        color: _red,
      );
      expect(HighlightStore.apply(line, [rule]).spans.first.style.foreground,
          _red);
    });

    test('无命中缓存:同行同文本跳过重扫,文本变化后重新命中', () {
      final line = _line([TerminalSpan('all good', const AnsiStyle())]);
      final rules = [
        const HighlightRule(id: 'c', name: 'e', pattern: 'ERROR', color: _red),
      ];
      // 第一次无命中(写入缓存),第二次走缓存,都返回原对象
      expect(identical(HighlightStore.apply(line, rules), line), isTrue);
      expect(identical(HighlightStore.apply(line, rules), line), isTrue);
      // 行文本变化(模拟活动行被改写)→ 缓存失效,重新命中
      line.spans
        ..clear()
        ..add(const TerminalSpan('an ERROR here', AnsiStyle()));
      final out = HighlightStore.apply(line, rules);
      expect(out.spans.first.style.foreground, _red);
    });

    test('非法正则被安全忽略', () {
      final line = _line([TerminalSpan('a(b', const AnsiStyle())]);
      final rule = HighlightRule(
        id: '5',
        name: 'bad',
        pattern: '(',
        color: _red,
        isRegex: true,
      );
      expect(HighlightStore.apply(line, [rule]).text, 'a(b');
      expect(HighlightStore.apply(line, [rule]).spans.first.style.foreground,
          isNull);
    });
  });
}
