import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termora/features/notes/data/note_asset_store.dart';
import 'package:termora/features/notes/domain/markdown_editing.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('termora_img_test');
    NoteAssetStore.debugDirectoryOverride = tempDir;
  });

  tearDown(() {
    NoteAssetStore.debugDirectoryOverride = null;
    tempDir.deleteSync(recursive: true);
  });

  test('importImage 复制进 assets 并保留扩展名,重复导入名字不撞', () async {
    final src = File('${tempDir.path}/原图.PNG')
      ..writeAsBytesSync([1, 2, 3]);
    final a = await NoteAssetStore.importImage(src.path);
    final b = await NoteAssetStore.importImage(src.path);

    expect(a, contains('/notes/assets/'));
    expect(a, endsWith('.png')); // 扩展名归一小写
    expect(File(a).readAsBytesSync(), [1, 2, 3]);
    expect(a, isNot(b)); // 时间戳命名,不覆盖
    expect(File(b).existsSync(), isTrue);
  });

  test('importFile 保留任意扩展名(视频/压缩包等),不强加 .png', () async {
    final src = File('${tempDir.path}/演示.MP4')..writeAsBytesSync([5]);
    final path = await NoteAssetStore.importFile(src.path);
    expect(path, endsWith('.mp4'));
    expect(File(path).readAsBytesSync(), [5]);

    final noExt = File('${tempDir.path}/blob')..writeAsBytesSync([6]);
    final stored = await NoteAssetStore.importFile(noExt.path);
    expect(stored.split('/').last, isNot(contains('.')));
  });

  test('insertStoredAssets:显示名取原文件名,图片/附件语法分流', () {
    final v = MarkdownEditing.insertStoredAssets(
      const TextEditingValue(
        text: '',
        selection: TextSelection.collapsed(offset: 0),
      ),
      [
        ('/Users/x/照片.PNG', '/assets/img_a.png'),
        ('/Users/x/演示视频.mp4', '/assets/img_b.mp4'),
      ],
    );
    expect(
      v.text,
      '![照片.PNG](/assets/img_a.png)\n[演示视频.mp4](/assets/img_b.mp4)',
    );
  });

  test('saveBytes 落盘 png', () async {
    final path = await NoteAssetStore.saveBytes([9, 8, 7]);
    expect(path, endsWith('.png'));
    expect(File(path).readAsBytesSync(), [9, 8, 7]);
  });

  test('无扩展名的源文件按 .png 落地', () async {
    final src = File('${tempDir.path}/noext')..writeAsBytesSync([1]);
    final path = await NoteAssetStore.importImage(src.path);
    expect(path, endsWith('.png'));
  });

  group('insertText(智能粘贴的文本分支)', () {
    test('CR/CRLF 换行归一成 LF(PDF/Excel/Windows 复制源不丢换行)', () {
      final v = MarkdownEditing.insertText(
        const TextEditingValue(
          text: '',
          selection: TextSelection.collapsed(offset: 0),
        ),
        '第一行\r第二行\r\n第三行\n第四行',
      );
      expect(v.text, '第一行\n第二行\n第三行\n第四行');
      expect(v.selection.baseOffset, v.text.length);
    });

    test('光标处插入,有选区则替换,光标落在插入内容后', () {
      final collapsed = MarkdownEditing.insertText(
        const TextEditingValue(
          text: '前后',
          selection: TextSelection.collapsed(offset: 1),
        ),
        '中',
      );
      expect(collapsed.text, '前中后');
      expect(collapsed.selection.baseOffset, 2);

      final replaced = MarkdownEditing.insertText(
        const TextEditingValue(
          text: '甲乙丙',
          selection: TextSelection(baseOffset: 1, extentOffset: 2),
        ),
        'XY',
      );
      expect(replaced.text, '甲XY丙');
      expect(replaced.selection.baseOffset, 3);
    });
  });
}
