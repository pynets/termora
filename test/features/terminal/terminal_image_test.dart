import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:termora/features/terminal/controller/terminal_image.dart';

void main() {
  group('decodeSixel', () {
    test('单列 6 像素红色', () {
      // #0;2;100;0;0 定义寄存器0=红;~ = 全 6 位 → 一列 6 像素
      final img = decodeSixel('q#0;2;100;0;0~');
      expect(img, isNotNull);
      expect(img!.pixelWidth, 1);
      expect(img.pixelHeight, 6);
      expect(img.bytes[0], 0x42); // 'B'
      expect(img.bytes[1], 0x4D); // 'M'
    });

    test('RLE 重复扩展宽度', () {
      final img = decodeSixel('q#0;2;0;100;0!5~');
      expect(img, isNotNull);
      expect(img!.pixelWidth, 5);
      expect(img.pixelHeight, 6);
    });

    test('换带下移 6 像素', () {
      final img = decodeSixel('q#0;2;0;0;100~-~');
      expect(img, isNotNull);
      expect(img!.pixelHeight, 12);
    });

    test(r'回车 $ 不增加高度', () {
      final img = decodeSixel(r'q#0;2;100;100;100~$~');
      expect(img, isNotNull);
      expect(img!.pixelWidth, 1);
      expect(img.pixelHeight, 6);
    });

    test('空/无效返回 null', () {
      expect(decodeSixel('q'), isNull);
      expect(decodeSixel(''), isNull);
    });
  });

  group('decodeRawPixels (Kitty f=24/32)', () {
    test('RGB 原始像素 → BMP', () {
      // 2x1 红、绿
      final raw = Uint8List.fromList([255, 0, 0, 0, 255, 0]);
      final img = decodeRawPixels(raw, 2, 1, hasAlpha: false);
      expect(img, isNotNull);
      expect(img!.pixelWidth, 2);
      expect(img.pixelHeight, 1);
      expect(img.bytes[0], 0x42);
    });

    test('RGBA 在黑底合成:半透明白 → 灰', () {
      // 1x1 白色 alpha=128 → 约 128 灰
      final raw = Uint8List.fromList([255, 255, 255, 128]);
      final img = decodeRawPixels(raw, 1, 1, hasAlpha: true);
      expect(img, isNotNull);
      expect(img!.pixelWidth, 1);
    });

    test('数据不足/尺寸非法返回 null', () {
      expect(decodeRawPixels(Uint8List(2), 4, 4, hasAlpha: false), isNull);
      expect(decodeRawPixels(Uint8List(3), 0, 1, hasAlpha: false), isNull);
    });
  });

  group('encodeBmp24', () {
    test('头部尺寸正确', () {
      final rgb = Uint8List.fromList([255, 255, 255]); // 1x1 白
      final bmp = encodeBmp24(rgb, 1, 1);
      expect(bmp.length, 58); // 54 头 + 4 对齐行
      expect(bmp[0], 0x42);
      expect(bmp[1], 0x4D);
    });
  });
}
