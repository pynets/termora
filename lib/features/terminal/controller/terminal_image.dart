import 'dart:typed_data';

/// 一张内联终端图片:统一存成可被 Image.memory 直接解码的字节。
/// - Sixel:解码成 RGB 位图后编码为 24 位 BMP;
/// - iTerm2 OSC 1337:载荷本就是 PNG/JPEG/GIF,原样存。
class TerminalImage {
  const TerminalImage({
    required this.bytes,
    required this.pixelWidth,
    required this.pixelHeight,
  });

  /// 可直接喂给 Image.memory 的编码字节(BMP / PNG / JPEG…)
  final Uint8List bytes;
  final int pixelWidth;
  final int pixelHeight;

  double get aspectRatio =>
      pixelHeight == 0 ? 1 : pixelWidth / pixelHeight;
}

/// 解码 Sixel(DCS q 之后的正文)为 [TerminalImage];失败返回 null。
///
/// 支持:颜色定义/选择 `#`、RLE `!`、回车 `$`、换带 `-`、光栅属性 `"`、
/// 以及 `?`..`~` 的六像素数据。两趟:先量尺寸再填像素。
TerminalImage? decodeSixel(String data) {
  final qi = data.indexOf('q');
  final body = qi < 0 ? data : data.substring(qi + 1);
  if (body.isEmpty) return null;

  final palette = _defaultSixelPalette();

  // 第一趟:测量宽高
  var measuredW = 0;
  var measuredH = 0;
  _runSixel(body, palette, (x, y, _) {
    if (x + 1 > measuredW) measuredW = x + 1;
    if (y + 1 > measuredH) measuredH = y + 1;
  });
  if (measuredW <= 0 || measuredH <= 0) return null;
  // 上限护栏:避免恶意/异常序列吃爆内存
  if (measuredW > 4096 || measuredH > 4096) return null;

  // 第二趟:填充 RGB(默认黑底)
  final rgb = Uint8List(measuredW * measuredH * 3);
  _runSixel(body, palette, (x, y, colorIdx) {
    if (x < 0 || y < 0 || x >= measuredW || y >= measuredH) return;
    final rgbInt = palette[colorIdx & 0xFF];
    final i = (y * measuredW + x) * 3;
    rgb[i] = (rgbInt >> 16) & 0xFF;
    rgb[i + 1] = (rgbInt >> 8) & 0xFF;
    rgb[i + 2] = rgbInt & 0xFF;
  });

  return TerminalImage(
    bytes: encodeBmp24(rgb, measuredW, measuredH),
    pixelWidth: measuredW,
    pixelHeight: measuredH,
  );
}

/// Kitty 图形协议的原始像素(f=24 RGB / f=32 RGBA)→ [TerminalImage]。
/// RGBA 在黑底上做 alpha 合成(BMP 不带 alpha),尺寸非法返回 null。
TerminalImage? decodeRawPixels(
  Uint8List raw,
  int width,
  int height, {
  required bool hasAlpha,
}) {
  if (width <= 0 || height <= 0 || width > 4096 || height > 4096) return null;
  final stride = hasAlpha ? 4 : 3;
  if (raw.length < width * height * stride) return null;
  final rgb = Uint8List(width * height * 3);
  for (var i = 0; i < width * height; i++) {
    final s = i * stride;
    final d = i * 3;
    if (hasAlpha) {
      final a = raw[s + 3];
      // 黑底合成:out = src*a/255
      rgb[d] = raw[s] * a ~/ 255;
      rgb[d + 1] = raw[s + 1] * a ~/ 255;
      rgb[d + 2] = raw[s + 2] * a ~/ 255;
    } else {
      rgb[d] = raw[s];
      rgb[d + 1] = raw[s + 1];
      rgb[d + 2] = raw[s + 2];
    }
  }
  return TerminalImage(
    bytes: encodeBmp24(rgb, width, height),
    pixelWidth: width,
    pixelHeight: height,
  );
}

/// 遍历 Sixel 正文,对每个被点亮的像素回调 [plot](x, y, colorIndex)。
void _runSixel(
  String body,
  List<int> palette,
  void Function(int x, int y, int colorIndex) plot,
) {
  var x = 0;
  var band = 0; // 当前带的顶行像素 y = band*6
  var color = 0;
  var i = 0;
  final n = body.length;

  int readInt() {
    var v = 0;
    var any = false;
    while (i < n) {
      final c = body.codeUnitAt(i);
      if (c >= 0x30 && c <= 0x39) {
        v = v * 10 + (c - 0x30);
        any = true;
        i++;
      } else {
        break;
      }
    }
    return any ? v : -1;
  }

  List<int> readParams() {
    final params = <int>[];
    while (true) {
      final v = readInt();
      params.add(v < 0 ? 0 : v);
      if (i < n && body.codeUnitAt(i) == 0x3B) {
        i++; // ';'
        continue;
      }
      break;
    }
    return params;
  }

  while (i < n) {
    final c = body.codeUnitAt(i);
    if (c == 0x23) {
      // '#': 颜色定义或选择
      i++;
      final params = readParams();
      final reg = params.isEmpty ? 0 : params[0];
      if (params.length >= 5 && params[1] == 2) {
        // RGB,分量 0..100
        final r = (params[2] * 255 / 100).round().clamp(0, 255);
        final g = (params[3] * 255 / 100).round().clamp(0, 255);
        final b = (params[4] * 255 / 100).round().clamp(0, 255);
        palette[reg & 0xFF] = (r << 16) | (g << 8) | b;
      } else if (params.length >= 5 && params[1] == 1) {
        // HLS,分量 H 0..360, L/S 0..100
        palette[reg & 0xFF] = _hlsToRgb(params[2], params[3], params[4]);
      }
      color = reg & 0xFF;
      continue;
    }
    if (c == 0x21) {
      // '!Pn': 重复下一个 sixel 字符
      i++;
      final count = readInt();
      if (i < n) {
        final sc = body.codeUnitAt(i);
        i++;
        _emitSixel(sc, count < 1 ? 1 : count, x, band, color, plot);
        if (sc >= 0x3F && sc <= 0x7E) x += count < 1 ? 1 : count;
      }
      continue;
    }
    if (c == 0x24) {
      // '$': 回到行首(同一带)
      x = 0;
      i++;
      continue;
    }
    if (c == 0x2D) {
      // '-': 换到下一带(下移 6 像素)
      x = 0;
      band++;
      i++;
      continue;
    }
    if (c == 0x22) {
      // '"Pan;Pad;Ph;Pv': 光栅属性 — 跳过(尺寸靠测量)
      i++;
      readParams();
      continue;
    }
    if (c >= 0x3F && c <= 0x7E) {
      _emitSixel(c, 1, x, band, color, plot);
      x++;
      i++;
      continue;
    }
    // 其它(换行/空白/未知)忽略
    i++;
  }
}

void _emitSixel(
  int sixelChar,
  int repeat,
  int x,
  int band,
  int color,
  void Function(int, int, int) plot,
) {
  if (sixelChar < 0x3F || sixelChar > 0x7E) return;
  final bits = sixelChar - 0x3F; // 低 6 位 = 6 个竖直像素
  final baseY = band * 6;
  for (var r = 0; r < repeat; r++) {
    final px = x + r;
    for (var k = 0; k < 6; k++) {
      if ((bits & (1 << k)) != 0) {
        plot(px, baseY + k, color);
      }
    }
  }
}

int _hlsToRgb(int h, int l, int s) {
  final ln = l / 100.0;
  final sn = s / 100.0;
  final c = (1 - (2 * ln - 1).abs()) * sn;
  final hp = (h % 360) / 60.0;
  final xx = c * (1 - (hp % 2 - 1).abs());
  double r = 0, g = 0, b = 0;
  if (hp < 1) {
    r = c;
    g = xx;
  } else if (hp < 2) {
    r = xx;
    g = c;
  } else if (hp < 3) {
    g = c;
    b = xx;
  } else if (hp < 4) {
    g = xx;
    b = c;
  } else if (hp < 5) {
    r = xx;
    b = c;
  } else {
    r = c;
    b = xx;
  }
  final m = ln - c / 2;
  final ri = ((r + m) * 255).round().clamp(0, 255);
  final gi = ((g + m) * 255).round().clamp(0, 255);
  final bi = ((b + m) * 255).round().clamp(0, 255);
  return (ri << 16) | (gi << 8) | bi;
}

/// VT340 默认 16 色调色板(其余寄存器初始为黑)。
List<int> _defaultSixelPalette() {
  final p = List<int>.filled(256, 0x000000);
  const defaults = <int>[
    0x000000, 0x3333CC, 0xCC2121, 0x33CC33, 0xCC33CC, 0x33CCCC, 0xCCCC33,
    0x878787, 0x424242, 0x545499, 0x994242, 0x429942, 0x994299, 0x429999,
    0x999942, 0xCCCCCC,
  ];
  for (var i = 0; i < defaults.length; i++) {
    p[i] = defaults[i];
  }
  return p;
}

/// 把 RGB(每像素 3 字节)编码成未压缩的 24 位 BMP。
Uint8List encodeBmp24(Uint8List rgb, int width, int height) {
  final rowSize = (width * 3 + 3) & ~3; // 4 字节对齐
  final pixelArraySize = rowSize * height;
  const headerSize = 54;
  final fileSize = headerSize + pixelArraySize;
  final out = Uint8List(fileSize);
  final bd = ByteData.view(out.buffer);

  // BITMAPFILEHEADER
  out[0] = 0x42; // 'B'
  out[1] = 0x4D; // 'M'
  bd.setUint32(2, fileSize, Endian.little);
  bd.setUint32(10, headerSize, Endian.little);
  // BITMAPINFOHEADER
  bd.setUint32(14, 40, Endian.little);
  bd.setInt32(18, width, Endian.little);
  bd.setInt32(22, height, Endian.little); // 正=自底向上
  bd.setUint16(26, 1, Endian.little); // planes
  bd.setUint16(28, 24, Endian.little); // bpp
  bd.setUint32(30, 0, Endian.little); // 无压缩
  bd.setUint32(34, pixelArraySize, Endian.little);

  // 像素:BMP 自底向上,BGR
  for (var y = 0; y < height; y++) {
    final srcY = height - 1 - y;
    var dst = headerSize + y * rowSize;
    var src = srcY * width * 3;
    for (var xx = 0; xx < width; xx++) {
      final r = rgb[src];
      final g = rgb[src + 1];
      final b = rgb[src + 2];
      out[dst] = b;
      out[dst + 1] = g;
      out[dst + 2] = r;
      dst += 3;
      src += 3;
    }
  }
  return out;
}
