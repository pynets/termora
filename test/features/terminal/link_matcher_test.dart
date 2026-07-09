import 'package:flutter_test/flutter_test.dart';
import 'package:termora/features/terminal/data/link_matcher_store.dart';

void main() {
  group('LinkMatcher', () {
    test(r'expandUrl 代入 $0 与捕获组', () {
      const m = LinkMatcher(
        id: '1',
        name: 'jira',
        pattern: r'JIRA-(\d+)',
        urlTemplate: r'https://jira.example.com/browse/JIRA-$1?raw=$0',
      );
      final match = m.regex!.firstMatch('fix JIRA-123 now')!;
      expect(
        m.expandUrl(match),
        'https://jira.example.com/browse/JIRA-123?raw=JIRA-123',
      );
    });

    test('组缺失代空串,非法正则返回 null', () {
      const missing = LinkMatcher(
        id: '2',
        name: '',
        pattern: r'abc',
        urlTemplate: r'https://x/$1',
      );
      final match = missing.regex!.firstMatch('abc')!;
      expect(missing.expandUrl(match), 'https://x/');
      const bad = LinkMatcher(
        id: '3',
        name: '',
        pattern: '(',
        urlTemplate: 'x',
      );
      expect(bad.regex, isNull);
    });

    test('findHits 命中启用规则,跳过禁用/非法', () {
      LinkMatcherStore.matchers.value = const [
        LinkMatcher(
          id: 'a',
          name: '',
          pattern: r'#(\d+)',
          urlTemplate: r'https://github.com/x/y/issues/$1',
        ),
        LinkMatcher(
          id: 'b',
          name: '',
          pattern: r'ERR-\d+',
          urlTemplate: 'https://err',
          enabled: false,
        ),
      ];
      final hits = LinkMatcherStore.findHits('see #42 and ERR-9');
      expect(hits.length, 1);
      expect(hits.single.url, 'https://github.com/x/y/issues/42');
      expect(hits.single.start, 4);
      expect(hits.single.end, 7);
      LinkMatcherStore.matchers.value = const [];
    });
  });
}
