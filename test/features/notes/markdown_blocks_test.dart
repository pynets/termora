import 'package:flutter_test/flutter_test.dart';
import 'package:termora/features/notes/domain/markdown_blocks.dart';

void main() {
  group('split', () {
    test('按空行与结构块切分,类型与区间正确', () {
      const src = '# 标题\n正文一\n\n'
          '```js\ncode\n```\n\n'
          '| a | b |\n|---|---|\n| 1 | 2 |\n\n'
          '---\n\n'
          '![图](/tmp/x.png)\n\n'
          '\$\$\nE=mc^2\n\$\$';
      final blocks = MarkdownBlockSplitter.split(src);
      expect(blocks.map((b) => b.kind), [
        SourceBlockKind.text,
        SourceBlockKind.code,
        SourceBlockKind.table,
        SourceBlockKind.divider,
        SourceBlockKind.image,
        SourceBlockKind.math,
      ]);
      // 区间往返:substring == source
      for (final b in blocks) {
        expect(src.substring(b.start, b.end), b.source);
      }
      expect(blocks[0].source, '# 标题\n正文一');
      expect(blocks[1].source, '```js\ncode\n```');
    });

    test('未闭合围栏吃到文末;紧贴文本的表格从文本块中切出', () {
      final blocks = MarkdownBlockSplitter.split(
        '段落\n| a | b |\n|---|---|\n没了\n```\nx',
      );
      expect(blocks.map((b) => b.kind), [
        SourceBlockKind.text,
        SourceBlockKind.table,
        SourceBlockKind.text, // 表格到非 | 行为止,"没了"回归文本块
        SourceBlockKind.code,
      ]);
      expect(blocks[1].source, '| a | b |\n|---|---|');
      expect(blocks[3].source, '```\nx');
    });

    test('空文档与纯空行无块', () {
      expect(MarkdownBlockSplitter.split(''), isEmpty);
      expect(MarkdownBlockSplitter.split('\n\n  \n'), isEmpty);
    });
  });

  group('replaceBlock / appendBlock', () {
    test('中间块替换,前后内容不动', () {
      const src = '甲\n\n乙\n\n丙';
      final blocks = MarkdownBlockSplitter.split(src);
      final next = MarkdownBlockSplitter.replaceBlock(src, blocks[1], '乙改');
      expect(next, '甲\n\n乙改\n\n丙');
    });

    test('空内容删除块并收拢空行', () {
      const src = '甲\n\n乙\n\n丙';
      final blocks = MarkdownBlockSplitter.split(src);
      final next = MarkdownBlockSplitter.replaceBlock(src, blocks[1], '  ');
      expect(MarkdownBlockSplitter.split(next).map((b) => b.source), [
        '甲',
        '丙',
      ]);
      expect(next.contains('\n\n\n'), isFalse);
    });

    test('appendBlock 保证隔一个空行;空文档直接就是内容', () {
      expect(MarkdownBlockSplitter.appendBlock('甲\n', '乙'), '甲\n\n乙');
      expect(MarkdownBlockSplitter.appendBlock('', '乙'), '乙');
    });
  });

  group('moveBlock(拖拽排序)', () {
    const src = '甲\n\n乙\n\n丙';

    test('向后/向前移动,间隔规整为单空行', () {
      expect(MarkdownBlockSplitter.moveBlock(src, 0, 2), '乙\n\n丙\n\n甲');
      expect(MarkdownBlockSplitter.moveBlock(src, 2, 0), '丙\n\n甲\n\n乙');
      // 多余空行在重排后被规整
      expect(
        MarkdownBlockSplitter.moveBlock('甲\n\n\n\n乙', 1, 0),
        '乙\n\n甲',
      );
    });

    test('同位/越界原样返回', () {
      expect(MarkdownBlockSplitter.moveBlock(src, 1, 1), src);
      expect(MarkdownBlockSplitter.moveBlock(src, 5, 0), src);
      expect(MarkdownBlockSplitter.moveBlock(src, 0, 5), src);
    });
  });
}
