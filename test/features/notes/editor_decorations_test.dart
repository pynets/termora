import 'package:flutter_test/flutter_test.dart';
import 'package:termora/features/notes/domain/markdown_source_highlighter.dart';
import 'package:termora/features/notes/view/widgets/editor_decorations.dart';

void main() {
  List<(MdSourceToken, MdSourceToken)> groupsOf(String source) =>
      blockBackgroundGroups(MarkdownSourceHighlighter.tokenize(source));

  test('两个代码块夹普通段落:分成两组,段落不被底色吞掉', () {
    const src = '```\nadb connect\nflutter run\n```\n\n'
        '远程服务器:\n密码: x\n\n'
        '```\nbrew install\n```';
    final groups = groupsOf(src);
    expect(groups, hasLength(2));
    // 第一组止于 flutter run,第二组起于 brew install
    expect(src.substring(groups[0].$1.start, groups[0].$2.end),
        'adb connect\nflutter run');
    expect(src.substring(groups[1].$1.start, groups[1].$2.end),
        'brew install');
  });

  test('围栏内空行不断组:一个块一块底色', () {
    const src = '```\n\nadb devices\n\nadb tcpip\n```';
    final groups = groupsOf(src);
    expect(groups, hasLength(1));
    expect(
      src.substring(groups.single.$1.start, groups.single.$2.end),
      'adb devices\n\nadb tcpip',
    );
  });

  test('代码块与公式块相邻也各自成组', () {
    const src = '```\ncode\n```\n\$\$\nE=mc^2\n\$\$';
    final groups = groupsOf(src);
    expect(groups, hasLength(2));
  });

  test('标题/段落紧贴闭合围栏不并入底色', () {
    const src = '```\ncode\n```\n# 标题';
    final groups = groupsOf(src);
    expect(groups, hasLength(1));
    expect(src.substring(groups.single.$1.start, groups.single.$2.end), 'code');
  });

  test('纯空行围栏(无内容)不产生底色组', () {
    expect(groupsOf('```\n\n```'), isEmpty);
    expect(groupsOf('正文而已'), isEmpty);
  });
}
