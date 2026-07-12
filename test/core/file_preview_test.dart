import 'package:flutter_test/flutter_test.dart';
import 'package:termora/core/widgets/file_preview.dart';

void main() {
  group('FilePreviewDialog.kindOf', () {
    test('文本类扩展名', () {
      for (final n in ['a.txt', 'log.log', 'main.dart', 'x.json', 'q.sql']) {
        expect(FilePreviewDialog.kindOf(n), FilePreviewKind.text, reason: n);
      }
    });

    test('无扩展名的常见文档按文本', () {
      expect(FilePreviewDialog.kindOf('README'), FilePreviewKind.text);
      expect(FilePreviewDialog.kindOf('Dockerfile'), FilePreviewKind.text);
      expect(FilePreviewDialog.kindOf('LICENSE'), FilePreviewKind.text);
    });

    test('Markdown', () {
      expect(FilePreviewDialog.kindOf('a.md'), FilePreviewKind.markdown);
      expect(FilePreviewDialog.kindOf('A.MARKDOWN'), FilePreviewKind.markdown);
    });

    test('图片', () {
      for (final n in ['a.png', 'b.JPG', 'c.gif', 'd.webp']) {
        expect(FilePreviewDialog.kindOf(n), FilePreviewKind.image, reason: n);
      }
    });

    test('未知/二进制 → other', () {
      for (final n in ['a.bin', 'x.tar.gz', 'app', 'v.mp4', 'p.pdf']) {
        expect(FilePreviewDialog.kindOf(n), FilePreviewKind.other, reason: n);
      }
    });
  });
}
