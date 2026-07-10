part of '../terminal_page.dart';

class _TerminalOutputText extends StatefulWidget {
  const _TerminalOutputText({
    required this.line,
    required this.monoStyle,
    required this.metrics,
    required this.columns,
    this.cursorColumn,
    this.cursorShape = TerminalCursorShape.block,
    required this.cursorColor,
    required this.cursorGlyphColor,
    required this.colorForLine,
    required this.textStyleForSpan,
    required this.trimLinkText,
    required this.onOpenLink,
    this.proportional = false,
  });

  final TerminalLine line;
  final TextStyle monoStyle;
  final _TerminalCellMetrics metrics;
  final int columns;
  final int? cursorColumn;

  /// When true (the normal buffer), wide characters advance by their real
  /// glyph width instead of `2 * cellWidth`, avoiding gaps after CJK text.
  /// The alt buffer keeps the strict uniform grid so TUIs stay aligned.
  final bool proportional;
  final TerminalCursorShape cursorShape;
  final Color cursorColor;

  /// 实心块状光标下反显字符用的颜色(终端背景色)
  final Color cursorGlyphColor;
  final Color Function(TerminalLineType type) colorForLine;
  final TextStyle Function(
    TextStyle baseStyle,
    TerminalLineType type,
    TerminalSpan span,
  )
  textStyleForSpan;
  final String Function(String value) trimLinkText;
  final ValueChanged<String> onOpenLink;

  @override
  State<_TerminalOutputText> createState() => _TerminalOutputTextState();
}

class _TerminalOutputTextState extends State<_TerminalOutputText> {
  @override
  Widget build(BuildContext context) {
    if (widget.line.type == TerminalLineType.prompt) {
      return Text.rich(
        _buildPlainTextSpan(),
        softWrap: true,
        style: widget.monoStyle.copyWith(
          color: widget.colorForLine(widget.line.type),
        ),
      );
    }
    final runs = _buildRuns();
    final Widget visible;
    if (!widget.proportional) {
      // 备用屏(vim/htop 等全屏应用):单画布逐格绘制。组件路径里合并
      // run 内部的 CJK/图标字形按字体天然宽度流动,行内会渐渐漂离格子;
      // 画布路径把背景块和每个字形都严格落在 column*cellWidth 上,
      // 与真终端(Terminal.app/xterm)的网格语义一致。
      visible = SizedBox(
        height: widget.metrics.lineHeight,
        width: double.infinity,
        child: ClipRect(
          child: CustomPaint(
            size: Size.infinite,
            painter: _TerminalGridPainter(
              runs: runs,
              metrics: widget.metrics,
              cursorColumn: widget.cursorColumn,
              cursorShape: widget.cursorShape,
              cursorColor: widget.cursorColor,
              cursorGlyphColor: widget.cursorGlyphColor,
            ),
          ),
        ),
      );
    } else {
      final contentColumns = math.max(
        1,
        math.max(widget.line.length, (widget.cursorColumn ?? 0) + 1),
      );
      final wrapAt = math.max(1, widget.columns);
      // 内容比视口窄:单行(原路径)。超宽:按视口列数折成多个可视行,
      // 右侧内容不再被裁到屏幕外(真终端就是这么换行的)。
      if (contentColumns <= wrapAt) {
        visible = _buildVisualRow(runs, 0, contentColumns, widget.cursorColumn);
      } else {
        final maxColumn = math.max(wrapAt, contentColumns);
        final offsets = _buildColumnPixelOffsets(maxColumn);
        final rowCount = (contentColumns + wrapAt - 1) ~/ wrapAt;
        final rows = <Widget>[];
        for (var r = 0; r < rowCount; r++) {
          final startCol = r * wrapAt;
          final endCol = math.min(startCol + wrapAt, maxColumn);
          final cursor = widget.cursorColumn;
          final cursorInRow =
              cursor != null && cursor >= startCol && cursor < endCol
              ? cursor
              : null;
          rows.add(
            _buildVisualRow(
              _sliceRuns(runs, startCol, endCol),
              startCol,
              endCol - startCol,
              cursorInRow,
              offsets: offsets,
            ),
          );
        }
        visible = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: rows,
        );
      }
    }
    return _selectableLine(visible);
  }

  /// 视觉层(画布/定位 Text)本身选不中或会重复选中;在其上叠一层
  /// 透明的等宽 Text 供 SelectionArea 选择与复制,视觉层则禁用选择。
  Widget _selectableLine(Widget visible) {
    return Stack(
      children: [
        SelectionContainer.disabled(child: visible),
        Positioned.fill(
          child: Text(
            widget.line.text,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.clip,
            style: widget.monoStyle.copyWith(color: const Color(0x00000000)),
          ),
        ),
      ],
    );
  }

  /// 渲染一个可视行:列窗口 [rowStartCol, rowStartCol+rowColumns)。
  /// [runs] 已是该窗口内、按窗口起点重新定位的片段;[offsets] 传入时按
  /// 整行像素偏移减去窗口起点,保证 CJK 宽度与整行一致。
  Widget _buildVisualRow(
    List<_TerminalGridRun> runs,
    int rowStartCol,
    int rowColumns,
    int? cursorColumn, {
    List<double>? offsets,
  }) {
    final lineOffsets =
        offsets ?? _buildColumnPixelOffsets(math.max(rowColumns, 1));
    final rowStartPx = _pixelForColumn(lineOffsets, rowStartCol);
    final rowEndPx = _pixelForColumn(lineOffsets, rowStartCol + rowColumns);
    final rowWidth = math.max(1.0, rowEndPx - rowStartPx);
    return SizedBox(
      height: widget.metrics.lineHeight,
      width: double.infinity,
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: 0,
          maxWidth: rowWidth,
          minHeight: widget.metrics.lineHeight,
          maxHeight: widget.metrics.lineHeight,
          child: SizedBox(
            width: rowWidth,
            height: widget.metrics.lineHeight,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                for (final run in runs) _buildRun(run, lineOffsets, rowStartPx),
                if (cursorColumn != null)
                  _buildCursor(cursorColumn, lineOffsets, rowStartPx),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 把整行的 runs 裁到列窗口 [startCol, endCol),跨界的 run 按格宽切开。
  /// 返回的 run 仍用绝对列号(定位时统一减去窗口起点像素)。
  List<_TerminalGridRun> _sliceRuns(
    List<_TerminalGridRun> runs,
    int startCol,
    int endCol,
  ) {
    final out = <_TerminalGridRun>[];
    for (final run in runs) {
      final runEnd = run.column + run.width;
      if (runEnd <= startCol || run.column >= endCol) continue;
      if (run.column >= startCol && runEnd <= endCol) {
        out.add(run);
        continue;
      }
      final cutFrom = math.max(0, startCol - run.column);
      final cutTo = math.min(run.width, endCol - run.column);
      final piece = _sliceRunText(run, cutFrom, cutTo);
      if (piece != null) out.add(piece);
    }
    return out;
  }

  /// 从 run 里抠出格偏移 [cutFrom, cutTo) 的文本,组合字符跟随前一个字形
  _TerminalGridRun? _sliceRunText(_TerminalGridRun run, int cutFrom, int cutTo) {
    if (cutTo <= cutFrom) return null;
    final buffer = StringBuffer();
    var cell = 0;
    var width = 0;
    for (final rune in run.text.runes) {
      final w = terminalRuneCellWidth(rune);
      if (w == 0) {
        if (buffer.isNotEmpty) buffer.writeCharCode(rune);
        continue;
      }
      if (cell >= cutFrom && cell < cutTo) {
        buffer.writeCharCode(rune);
        width += w;
      }
      cell += w;
      if (cell >= cutTo) break;
    }
    if (buffer.isEmpty) return null;
    return _TerminalGridRun(
      column: run.column + cutFrom,
      width: width,
      text: buffer.toString(),
      style: run.style,
      linkUrl: run.linkUrl,
    );
  }

  /// Builds the pixel x-offset of each column's left edge, using the real wide
  /// glyph advance so CJK text lays out without gaps. `offsets[c]` is the left
  /// edge of column `c`; the list is extended to cover at least [minColumns].
  List<double> _buildColumnPixelOffsets(int minColumns) {
    final cellWidth = widget.metrics.cellWidth;
    final halfWide = widget.metrics.wideCellWidth / 2;
    final offsets = <double>[0.0];
    var px = 0.0;
    for (final span in widget.line.spans) {
      for (final rune in span.text.runes) {
        final width = terminalRuneCellWidth(rune);
        if (width == 0) continue;
        if (width == 2) {
          px += halfWide;
          offsets.add(px);
          px += halfWide;
          offsets.add(px);
        } else {
          px += cellWidth;
          offsets.add(px);
        }
      }
    }
    while (offsets.length <= minColumns) {
      px += cellWidth;
      offsets.add(px);
    }
    return offsets;
  }

  double _pixelForColumn(List<double>? offsets, int column) {
    final cellWidth = widget.metrics.cellWidth;
    if (offsets == null) return column * cellWidth;
    if (column < 0) return 0;
    if (column < offsets.length) return offsets[column];
    return offsets.last + (column - (offsets.length - 1)) * cellWidth;
  }

  Widget _buildCursor(int column, List<double>? offsets, [double originPx = 0]) {
    final safeColumn = math.max(0, column);
    final left = _pixelForColumn(offsets, safeColumn) - originPx;
    final cursorWidth = math.max(2.0, widget.metrics.cellWidth);
    final cursorHeight = widget.metrics.lineHeight;
    switch (widget.cursorShape) {
      case TerminalCursorShape.underline:
        return Positioned(
          left: left,
          top: math.max(0.0, cursorHeight - 2),
          width: cursorWidth,
          height: 2.0,
          child: DecoratedBox(
            decoration: BoxDecoration(color: widget.cursorColor),
          ),
        );
      case TerminalCursorShape.bar:
        return Positioned(
          left: left,
          top: 0,
          width: 2.0,
          height: cursorHeight,
          child: DecoratedBox(
            decoration: BoxDecoration(color: widget.cursorColor),
          ),
        );
      case TerminalCursorShape.block:
        break;
    }
    // 块状光标:一格宽的描边框(四边),不再用半透明填充 + 单侧竖线
    // (那会让填充看着像光标右侧的"阴影",竖线又和字符错位)
    return Positioned(
      left: left,
      top: 0,
      width: cursorWidth,
      height: cursorHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: widget.cursorColor.withValues(alpha: 0.10),
          border: Border.all(color: widget.cursorColor, width: 1),
        ),
      ),
    );
  }

  TextSpan _buildPlainTextSpan() {
    return TextSpan(
      children: [
        for (final span in widget.line.spans)
          TextSpan(
            text: span.text,
            style: widget.textStyleForSpan(
              widget.monoStyle,
              widget.line.type,
              span,
            ),
          ),
      ],
    );
  }

  Widget _buildRun(
    _TerminalGridRun run,
    List<double>? offsets, [
    double originPx = 0,
  ]) {
    final style = run.style.copyWith(height: 1);
    final left = _pixelForColumn(offsets, run.column) - originPx;
    final allocatedWidth =
        _pixelForColumn(offsets, run.column + run.width) -
        _pixelForColumn(offsets, run.column);
    final content = Text(
      run.text,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.visible,
      style: style,
    );
    final child = run.linkUrl == null
        ? content
        : _HoverLink(
            text: run.text,
            style: style,
            url: run.linkUrl!,
            onOpen: widget.onOpenLink,
          );

    return Positioned(
      left: left,
      top: 0,
      width: math.max(0, allocatedWidth),
      height: widget.metrics.lineHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(color: run.backgroundColor),
        child: child,
      ),
    );
  }

  List<_TerminalGridRun> _buildRuns() {
    final runs = <_TerminalGridRun>[];
    var column = 0;
    for (final span in widget.line.spans) {
      final style = widget.textStyleForSpan(
        widget.monoStyle,
        widget.line.type,
        span,
      );
      final linkUrl = span.linkUrl;
      if (linkUrl != null && linkUrl.isNotEmpty) {
        column = _appendRuns(
          runs,
          span.text,
          column,
          style,
          widget.trimLinkText(linkUrl),
        );
      } else {
        column = _appendTextWithDetectedLinks(runs, span.text, column, style);
      }
    }
    return runs;
  }

  int _appendTextWithDetectedLinks(
    List<_TerminalGridRun> runs,
    String text,
    int startColumn,
    TextStyle style,
  ) {
    // 内置 URL 检测 + 自定义正则规则(xterm.js registerLinkMatcher 式),
    // 统一收集后按起点排序、丢弃与已接受区间重叠的命中(URL 优先)。
    final segments = <({int start, int end, String url, bool builtin})>[
      for (final m in _TerminalSessionViewState._terminalLinkPattern
          .allMatches(text))
        (start: m.start, end: m.end, url: '', builtin: true),
      for (final hit in LinkMatcherStore.findHits(text))
        (start: hit.start, end: hit.end, url: hit.url, builtin: false),
    ];
    if (segments.isEmpty) {
      return _appendRuns(runs, text, startColumn, style, null);
    }
    segments.sort(
      (a, b) => a.start != b.start
          ? a.start - b.start
          // 同起点:内置 URL 优先,其次取更长的
          : a.builtin != b.builtin
          ? (a.builtin ? -1 : 1)
          : b.end - a.end,
    );

    var cursor = 0;
    var column = startColumn;
    for (final seg in segments) {
      if (seg.start < cursor) continue; // 与已接受的重叠,跳过
      if (seg.start > cursor) {
        column = _appendRuns(
          runs,
          text.substring(cursor, seg.start),
          column,
          style,
          null,
        );
      }
      final raw = text.substring(seg.start, seg.end);
      if (seg.builtin) {
        // URL:剥掉尾随标点后剩余部分按普通文本排
        final linkText = widget.trimLinkText(raw);
        if (linkText.isNotEmpty) {
          column = _appendRuns(runs, linkText, column, style, linkText);
        }
        final trailing = raw.substring(linkText.length);
        if (trailing.isNotEmpty) {
          column = _appendRuns(runs, trailing, column, style, null);
        }
      } else {
        column = _appendRuns(runs, raw, column, style, seg.url);
      }
      cursor = seg.end;
    }
    if (cursor < text.length) {
      column = _appendRuns(runs, text.substring(cursor), column, style, null);
    }
    return column;
  }

  int _appendRuns(
    List<_TerminalGridRun> runs,
    String text,
    int startColumn,
    TextStyle style,
    String? linkUrl,
  ) {
    var column = startColumn;
    final effectiveStyle = linkUrl == null ? style : _linkTextStyle(style);
    for (final rune in text.runes) {
      final char = String.fromCharCode(rune);
      final width = terminalRuneCellWidth(rune);
      if (width == 0) {
        if (runs.isNotEmpty) {
          runs[runs.length - 1] = runs.last.copyWith(
            text: runs.last.text + char,
          );
        }
        continue;
      }
      final isBlank = char == ' ' || char == '\t';
      final hasBackground = style.backgroundColor != null;
      if (!isBlank || hasBackground || linkUrl != null) {
        _appendRun(
          runs,
          _TerminalGridRun(
            column: column,
            width: width,
            text: char,
            style: effectiveStyle,
            linkUrl: linkUrl,
          ),
        );
      }
      column += width;
    }
    return column;
  }

  /// 链接常态样式:只上品牌色(可发现),下划线留到悬停时才加。
  TextStyle _linkTextStyle(TextStyle style) {
    return style.copyWith(color: AppTheme.brandColor);
  }

  void _appendRun(List<_TerminalGridRun> runs, _TerminalGridRun nextRun) {
    if (runs.isEmpty) {
      runs.add(nextRun);
      return;
    }
    final last = runs.last;
    if (last.canMerge(nextRun)) {
      runs[runs.length - 1] = last.merge(nextRun);
      return;
    }
    runs.add(nextRun);
  }
}

class _TerminalGridRun {
  const _TerminalGridRun({
    required this.column,
    required this.width,
    required this.text,
    required this.style,
    this.linkUrl,
  });

  final int column;
  final int width;
  final String text;
  final TextStyle style;
  final String? linkUrl;

  Color? get backgroundColor => style.backgroundColor;

  int get endColumn => column + width;

  bool canMerge(_TerminalGridRun other) {
    return endColumn == other.column &&
        style == other.style &&
        linkUrl == other.linkUrl;
  }

  _TerminalGridRun merge(_TerminalGridRun other) {
    return _TerminalGridRun(
      column: column,
      width: width + other.width,
      text: text + other.text,
      style: style,
      linkUrl: linkUrl,
    );
  }

  _TerminalGridRun copyWith({String? text}) {
    return _TerminalGridRun(
      column: column,
      width: width,
      text: text ?? this.text,
      style: style,
      linkUrl: linkUrl,
    );
  }
}

class _TerminalCellMetrics {
  const _TerminalCellMetrics({
    required this.cellWidth,
    required this.wideCellWidth,
    required this.lineHeight,
  });

  final double cellWidth;

  /// The actual rendered advance of a full-width (CJK) glyph. With a truly
  /// monospace CJK font this equals `2 * cellWidth`, but proportional UI fonts
  /// (e.g. PingFang SC) render CJK narrower, so measuring it lets us lay wide
  /// characters out without leaving gaps.
  final double wideCellWidth;

  final double lineHeight;

  static _TerminalCellMetrics fromStyle(TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: '0000000000', style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final widePainter = TextPainter(
      text: TextSpan(text: '中中中中中', style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final fontSize = style.fontSize ?? 13;
    final height = fontSize * (style.height ?? 1.45);
    final cellWidth = math.max(1.0, painter.width / 10);
    return _TerminalCellMetrics(
      cellWidth: cellWidth,
      wideCellWidth: math.max(cellWidth, widePainter.width / 5),
      lineHeight: math.max(height, painter.height),
    );
  }
}

/// 可点击链接的一段文本:常态只上色,悬停时加下划线并变手型,
/// 同时用 Tooltip 预览完整 URL(对标 xterm.js web-links)。
class _HoverLink extends StatefulWidget {
  const _HoverLink({
    required this.text,
    required this.style,
    required this.url,
    required this.onOpen,
  });

  final String text;
  final TextStyle style;
  final String url;
  final ValueChanged<String> onOpen;

  @override
  State<_HoverLink> createState() => _HoverLinkState();
}

class _HoverLinkState extends State<_HoverLink> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final style = _hovered
        ? widget.style.copyWith(
            decoration: TextDecoration.underline,
            decorationColor: AppTheme.brandColor,
          )
        : widget.style;
    return Tooltip(
      message: widget.url,
      waitDuration: const Duration(milliseconds: 400),
      preferBelow: false,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => widget.onOpen(widget.url),
          child: Text(
            widget.text,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.visible,
            style: style,
          ),
        ),
      ),
    );
  }
}

/// 备用屏的行画布:一次 paint 完成背景块、字形、光标,全部严格落格。
/// ASCII 连续段整段画(等宽字体天然逐格);CJK/图标/制表符等回退字体
/// 字形逐个画并在自己的格子里居中,宽度不齐也不会带偏后面的列。
class _TerminalGridPainter extends CustomPainter {
  _TerminalGridPainter({
    required this.runs,
    required this.metrics,
    required this.cursorColumn,
    required this.cursorShape,
    required this.cursorColor,
    required this.cursorGlyphColor,
  });

  final List<_TerminalGridRun> runs;
  final _TerminalCellMetrics metrics;
  final int? cursorColumn;
  final TerminalCursorShape cursorShape;
  final Color cursorColor;

  /// 实心块状光标下,反显字符用的颜色(终端背景色)
  final Color cursorGlyphColor;

  @override
  void paint(Canvas canvas, Size size) {
    final cell = metrics.cellWidth;
    final height = metrics.lineHeight;
    final bgPaint = Paint();
    for (final run in runs) {
      final bg = run.backgroundColor;
      if (bg == null) continue;
      bgPaint.color = bg;
      canvas.drawRect(
        Rect.fromLTWH(run.column * cell, 0, run.width * cell, height),
        bgPaint,
      );
    }
    for (final run in runs) {
      _paintRunText(canvas, run);
    }
    final column = cursorColumn;
    if (column != null && column >= 0) _paintCursor(canvas, column);
  }

  void _paintRunText(Canvas canvas, _TerminalGridRun run) {
    // 背景已按格宽画过,字形样式里剥掉 backgroundColor 防止按文本宽二次上色
    final style = run.style.copyWith(height: 1.0, backgroundColor: Colors.transparent);
    final cell = metrics.cellWidth;
    var column = run.column;
    final ascii = StringBuffer();
    var asciiStart = run.column;

    void flushAscii() {
      if (ascii.isEmpty) return;
      _paintText(canvas, ascii.toString(), style, asciiStart * cell, null);
      ascii.clear();
    }

    for (final rune in run.text.runes) {
      final width = terminalRuneCellWidth(rune);
      if (width == 0) {
        // 组合字符依附前一个字形;缓冲区空(依附对象已单独画掉)则丢弃
        if (ascii.isNotEmpty) ascii.write(String.fromCharCode(rune));
        continue;
      }
      final isAscii = rune >= 0x20 && rune < 0x7F;
      if (isAscii) {
        if (ascii.isEmpty) asciiStart = column;
        ascii.write(String.fromCharCode(rune));
        column += 1;
        continue;
      }
      flushAscii();
      _paintText(
        canvas,
        String.fromCharCode(rune),
        style,
        column * cell,
        width * cell,
      );
      column += width;
    }
    flushAscii();
  }

  /// [boxWidth] 非 null 时字形在该宽度盒子里水平居中(单个非 ASCII 字形)
  void _paintText(
    Canvas canvas,
    String text,
    TextStyle style,
    double x,
    double? boxWidth,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final dx = boxWidth == null
        ? x
        : x + math.max(0, (boxWidth - painter.width) / 2);
    final dy = (metrics.lineHeight - painter.height) / 2;
    painter.paint(canvas, Offset(dx, dy));
    painter.dispose();
  }

  void _paintCursor(Canvas canvas, int column) {
    final cell = metrics.cellWidth;
    final left = column * cell;
    final height = metrics.lineHeight;
    final paint = Paint()..color = cursorColor;
    switch (cursorShape) {
      case TerminalCursorShape.underline:
        canvas.drawRect(
          Rect.fromLTWH(left, math.max(0.0, height - 2), cell, 2),
          paint,
        );
      case TerminalCursorShape.bar:
        canvas.drawRect(Rect.fromLTWH(left, 0, 2, height), paint);
      case TerminalCursorShape.block:
        // 实心块 + 反显字符(真终端的块状光标):高亮所在格,再把该格
        // 字符用背景色重画一遍,而不是画个空心瘦高框("长方块")
        final glyph = _cellAt(column);
        final widthCells = glyph?.width ?? 1;
        final blockWidth = math.max(2.0, widthCells * cell);
        canvas.drawRect(Rect.fromLTWH(left, 0, blockWidth, height), paint);
        if (glyph != null && glyph.text.trim().isNotEmpty) {
          _paintText(
            canvas,
            glyph.text,
            glyph.style.copyWith(
              height: 1.0,
              color: cursorGlyphColor,
              backgroundColor: Colors.transparent,
            ),
            left,
            widthCells > 1 ? blockWidth : null,
          );
        }
    }
  }

  /// 光标所在格的字符(含样式、格宽);空格或越界返回 null
  ({String text, int width, TextStyle style})? _cellAt(int column) {
    for (final run in runs) {
      if (column < run.column || column >= run.column + run.width) continue;
      var cell = run.column;
      for (final rune in run.text.runes) {
        final w = terminalRuneCellWidth(rune);
        if (w == 0) continue;
        if (cell == column) {
          return (text: String.fromCharCode(rune), width: w, style: run.style);
        }
        cell += w;
        if (cell > column) break;
      }
      return null;
    }
    return null;
  }

  @override
  bool shouldRepaint(covariant _TerminalGridPainter oldDelegate) => true;
}

class _TerminalIconButton extends StatelessWidget {
  const _TerminalIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.size = 34,
    this.iconSize = 16,
    this.ghost = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final double size;
  final double iconSize;
  final bool ghost;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 250),
      child: SizedBox(
        width: size,
        height: size,
        child: IconButton(
          padding: EdgeInsets.zero,
          style: IconButton.styleFrom(
            backgroundColor: ghost
                ? Colors.transparent
                : AppTheme.subtleSurfaceColor.withValues(alpha: 0.65),
            disabledBackgroundColor: ghost
                ? Colors.transparent
                : AppTheme.subtleSurfaceColor.withValues(alpha: 0.35),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          icon: Icon(
            icon,
            size: iconSize,
            color: enabled ? AppTheme.headingColor : AppTheme.subtleTextColor,
          ),
          onPressed: onPressed,
        ),
      ),
    );
  }
}

/// A session chip in the bottom tab bar. Tapping focuses the matching pane;
/// long-press drags it to rearrange the split layout.
class _TerminalSessionTab extends ConsumerWidget {
  const _TerminalSessionTab({
    required this.sessionKey,
    required this.title,
    required this.isActive,
    required this.canClose,
    this.isRemote = false,
    required this.onSelect,
    required this.onClose,
  });

  final String sessionKey;
  final String title;
  final bool isActive;
  final bool canClose;
  final bool isRemote;
  final VoidCallback onSelect;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final running = ref.watch(
      terminalUiControllerProvider(sessionKey).select((s) => s.isRunning),
    );
    final tab = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onSelect,
        borderRadius: BorderRadius.circular(7),
        child: Container(
          padding: EdgeInsets.fromLTRB(10, 5, canClose ? 4 : 10, 5),
          decoration: BoxDecoration(
            color: isActive
                ? AppTheme.softBrandColor
                : AppTheme.subtleSurfaceColor.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
              color: isActive
                  ? AppTheme.brandColor.withValues(alpha: 0.4)
                  : AppTheme.borderColor,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: running
                      ? AppTheme.successColor
                      : AppTheme.subtleTextColor.withValues(alpha: 0.45),
                ),
              ),
              if (isRemote) ...[
                const SizedBox(width: 6),
                Icon(
                  LucideIcons.server300,
                  size: 11,
                  color: isActive
                      ? AppTheme.brandColor
                      : AppTheme.subtleTextColor,
                ),
              ],
              const SizedBox(width: 8),
              Text(
                title,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                  color: isActive ? AppTheme.brandColor : AppTheme.headingColor,
                ),
              ),
              if (canClose) ...[
                const SizedBox(width: 4),
                _TerminalIconButton(
                  tooltip: '关闭终端',
                  icon: LucideIcons.x300,
                  size: 20,
                  iconSize: 12,
                  ghost: true,
                  onPressed: () async {
                    final confirmed = await _showCloseTerminalConfirm(
                      context,
                      title: title,
                      running: running,
                    );
                    if (confirmed) onClose();
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
    return LongPressDraggable<_TerminalDragData>(
      data: _TerminalDragData(sessionKey),
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: _TerminalDragFeedback(title: title),
      child: tab,
    );
  }
}

/// Confirmation dialog shown before a terminal (and its process) is closed.
Future<bool> _showCloseTerminalConfirm(
  BuildContext context, {
  required String title,
  required bool running,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: AppTheme.surfaceColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      title: Text(
        '关闭 $title?',
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: AppTheme.headingColor,
        ),
      ),
      content: Text(
        running ? '该终端正在运行,关闭会结束当前进程。' : '关闭后该终端会话将被移除。',
        style: TextStyle(fontSize: 13.5, color: AppTheme.bodyColor),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text('取消', style: TextStyle(color: AppTheme.subtleTextColor)),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(
            '关闭',
            style: TextStyle(
              color: AppTheme.errorColor,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

/// A draggable divider used between split panes.
class _PaneDivider extends StatefulWidget {
  const _PaneDivider({required this.axis, required this.onDragDelta});

  final Axis axis;
  final ValueChanged<double> onDragDelta;

  @override
  State<_PaneDivider> createState() => _PaneDividerState();
}

class _PaneDividerState extends State<_PaneDivider> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final horizontal = widget.axis == Axis.horizontal;
    final lineColor = _hovered
        ? AppTheme.brandColor.withValues(alpha: 0.7)
        : AppTheme.borderColor;
    return MouseRegion(
      cursor: horizontal
          ? SystemMouseCursors.resizeColumn
          : SystemMouseCursors.resizeRow,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: horizontal
            ? (details) => widget.onDragDelta(details.delta.dx)
            : null,
        onVerticalDragUpdate: horizontal
            ? null
            : (details) => widget.onDragDelta(details.delta.dy),
        child: SizedBox(
          width: horizontal ? 6 : null,
          height: horizontal ? null : 6,
          child: Center(
            child: Container(
              width: horizontal ? 1 : double.infinity,
              height: horizontal ? double.infinity : 1,
              color: lineColor,
            ),
          ),
        ),
      ),
    );
  }
}

/// A small pill shown in the terminal footer status bar.
class _TerminalFooterChip extends StatelessWidget {
  const _TerminalFooterChip({required this.label, required this.tone});

  final String label;
  final _FooterChipTone tone;

  @override
  Widget build(BuildContext context) {
    late final Color background;
    late final Color foreground;
    switch (tone) {
      case _FooterChipTone.active:
        background = AppTheme.softBrandColor;
        foreground = AppTheme.brandColor;
      case _FooterChipTone.warning:
        background = AppTheme.warningColor.withValues(alpha: 0.16);
        foreground = AppTheme.warningColor;
      case _FooterChipTone.neutral:
        background = AppTheme.subtleSurfaceColor.withValues(alpha: 0.7);
        foreground = AppTheme.subtleTextColor;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        maxLines: 1,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w500,
          color: foreground,
        ),
      ),
    );
  }
}

/// The floating chip shown under the pointer while dragging a session to
/// rearrange the split layout.
class _TerminalDragFeedback extends StatelessWidget {
  const _TerminalDragFeedback({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: AppTheme.surfaceColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.brandColor.withValues(alpha: 0.6)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              LucideIcons.squareTerminal300,
              size: 15,
              color: AppTheme.brandColor,
            ),
            const SizedBox(width: 7),
            Text(
              title,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: AppTheme.headingColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Overlays a pane with drag-and-drop zones (left/right/top/bottom/center) so a
/// dragged session can be dropped to re-split or swap the layout.
class _PaneDropTarget extends StatefulWidget {
  const _PaneDropTarget({
    required this.paneId,
    required this.onDrop,
    required this.child,
  });

  final int paneId;
  final void Function(int paneId, _DropRegion region, String sessionKey) onDrop;
  final Widget child;

  @override
  State<_PaneDropTarget> createState() => _PaneDropTargetState();
}

class _PaneDropTargetState extends State<_PaneDropTarget> {
  final GlobalKey _boxKey = GlobalKey();
  _DropRegion? _hovered;

  _DropRegion? _regionForGlobal(Offset globalOffset) {
    final box = _boxKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return _dropRegionFor(box.globalToLocal(globalOffset), box.size);
  }

  @override
  Widget build(BuildContext context) {
    return DragTarget<_TerminalDragData>(
      onWillAcceptWithDetails: (_) => true,
      onMove: (details) {
        final region = _regionForGlobal(details.offset);
        if (region != _hovered) setState(() => _hovered = region);
      },
      onLeave: (_) {
        if (_hovered != null) setState(() => _hovered = null);
      },
      onAcceptWithDetails: (details) {
        final region = _regionForGlobal(details.offset) ?? _DropRegion.center;
        widget.onDrop(widget.paneId, region, details.data.sessionKey);
        setState(() => _hovered = null);
      },
      builder: (context, candidate, rejected) {
        final region = candidate.isNotEmpty ? _hovered : null;
        return Stack(
          key: _boxKey,
          fit: StackFit.expand,
          children: [
            widget.child,
            if (region != null)
              Positioned.fill(
                child: IgnorePointer(child: _buildDropHighlight(region)),
              ),
          ],
        );
      },
    );
  }

  Widget _buildDropHighlight(_DropRegion region) {
    final zone = DecoratedBox(
      decoration: BoxDecoration(
        color: AppTheme.brandColor.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: AppTheme.brandColor.withValues(alpha: 0.7),
          width: 2,
        ),
      ),
    );
    switch (region) {
      case _DropRegion.center:
        return Padding(
          padding: const EdgeInsets.all(14),
          child: FractionallySizedBox(
            widthFactor: 0.6,
            heightFactor: 0.6,
            child: zone,
          ),
        );
      case _DropRegion.left:
        return Align(
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: 0.5,
            heightFactor: 1,
            child: Padding(padding: const EdgeInsets.all(3), child: zone),
          ),
        );
      case _DropRegion.right:
        return Align(
          alignment: Alignment.centerRight,
          child: FractionallySizedBox(
            widthFactor: 0.5,
            heightFactor: 1,
            child: Padding(padding: const EdgeInsets.all(3), child: zone),
          ),
        );
      case _DropRegion.top:
        return Align(
          alignment: Alignment.topCenter,
          child: FractionallySizedBox(
            widthFactor: 1,
            heightFactor: 0.5,
            child: Padding(padding: const EdgeInsets.all(3), child: zone),
          ),
        );
      case _DropRegion.bottom:
        return Align(
          alignment: Alignment.bottomCenter,
          child: FractionallySizedBox(
            widthFactor: 1,
            heightFactor: 0.5,
            child: Padding(padding: const EdgeInsets.all(3), child: zone),
          ),
        );
    }
  }
}

/// Maps a local pointer position within a pane to a drop region. The central
/// ~30% margin resolves to [_DropRegion.center]; otherwise the nearest edge.
_DropRegion _dropRegionFor(Offset local, Size size) {
  if (size.width <= 0 || size.height <= 0) return _DropRegion.center;
  final fx = (local.dx / size.width).clamp(0.0, 1.0);
  final fy = (local.dy / size.height).clamp(0.0, 1.0);
  final distances = <_DropRegion, double>{
    _DropRegion.left: fx,
    _DropRegion.right: 1 - fx,
    _DropRegion.top: fy,
    _DropRegion.bottom: 1 - fy,
  };
  var nearest = _DropRegion.left;
  var nearestDistance = double.infinity;
  distances.forEach((region, distance) {
    if (distance < nearestDistance) {
      nearestDistance = distance;
      nearest = region;
    }
  });
  if (nearestDistance > 0.3) return _DropRegion.center;
  return nearest;
}

/// Centered icon + message used for empty/error states in the details panel.
Widget _panelMessage(IconData icon, String message) {
  return Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 26,
            color: AppTheme.subtleTextColor.withValues(alpha: 0.6),
          ),
          const SizedBox(height: 10),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: AppTheme.subtleTextColor),
          ),
        ],
      ),
    ),
  );
}

String _panelBaseName(String path) {
  final parts = path
      .split(Platform.pathSeparator)
      .where((segment) => segment.isNotEmpty)
      .toList();
  return parts.isEmpty ? path : parts.last;
}

/// A lazily-expanding file tree of the terminal's working directory.
class _TerminalFilesTab extends StatefulWidget {
  const _TerminalFilesTab({
    super.key,
    required this.cwd,
    required this.onInsertPath,
    this.onCdInTerminal,
    this.remoteLister,
    this.remoteUploader,
    this.remoteUploadDir,
    this.remoteDownloader,
    this.remoteRename,
    this.remoteDelete,
    this.remoteMakeDir,
    this.elevated = false,
    this.onElevate,
    this.onDropElevation,
  });

  /// 起始目录:本地为绝对路径;远端为命令行当前目录(空串 = 远端家目录)
  final String cwd;
  final void Function(String fullPath) onInsertPath;

  /// 「在终端进入此目录」;非空(远端)时目录右键菜单出现该项
  final void Function(String remotePath)? onCdInTerminal;

  /// 非空 = 远端 SFTP 模式,用它列目录而非本地 dart:io
  final Future<List<TerminalDirEntry>> Function(String path)? remoteLister;

  /// 上传本地文件到远端目录,返回 0..1 进度流(远端模式才有)
  final Stream<double> Function(String localPath, String remoteDir)?
  remoteUploader;

  /// 上传整个本地目录(递归)到远端目录
  final Stream<double> Function(String localDir, String remoteDir)?
  remoteUploadDir;

  /// 下载远端文件/目录到本地路径,返回 0..1 进度流
  final Stream<double> Function(String remotePath, String localPath, bool isDir)?
  remoteDownloader;

  /// 重命名(同目录改名)/ 删除 / 新建目录;非空才显示对应操作
  final Future<void> Function(String path, String newName)? remoteRename;
  final Future<void> Function(String path, bool isDir)? remoteDelete;
  final Future<void> Function(String parentDir, String name)? remoteMakeDir;

  /// 提权:当前是否已 root;触发提权(成功返回 true);退出提权
  final bool elevated;
  final Future<bool> Function()? onElevate;
  final VoidCallback? onDropElevation;

  @override
  State<_TerminalFilesTab> createState() => _TerminalFilesTabState();
}

/// 详情面板里的一个传输项(上传/下载)
class _PanelTransfer {
  _PanelTransfer({required this.label, required this.isUpload});
  final String label;
  final bool isUpload;
  double progress = 0;
  bool done = false;
  bool failed = false;
  bool cancelled = false;
  String? error;
  StreamSubscription<double>? sub;

  bool get running => !done && !failed && !cancelled;
}

class _TerminalFilesTabState extends State<_TerminalFilesTab> {
  final TextEditingController _findController = TextEditingController();
  final List<_FileNode> _nodes = [];
  final List<_PanelTransfer> _transfers = [];
  String _query = '';
  bool _showHidden = false;
  bool _loading = false;
  bool _dragOver = false;
  bool _needsElevation = false;
  String? _error;

  bool get _isRemote => widget.remoteLister != null;
  bool get _canTransfer =>
      _isRemote && widget.remoteUploader != null;

  /// 当前实际展示的根目录(远端空串 = 家目录,由上层解析);
  /// 探测目录列失败回落家目录后,它会变成 ''
  late String _currentRoot = widget.cwd;

  /// 地址栏显示的绝对路径(从加载到的条目反推,空目录时退回 _currentRoot)
  String _displayPath = '';

  /// 上传目标 / 面板根目录
  String get _rootDir => _currentRoot;

  @override
  void initState() {
    super.initState();
    _loadRoot();
  }

  /// 切换到某个目录作为新的根(地址栏回车 / 上一级)
  void _navigateTo(String path) {
    setState(() {
      _currentRoot = path;
      _query = '';
      _findController.clear();
    });
    _loadRoot();
  }

  void _goUp() {
    final p = _displayPath;
    if (p.isEmpty || p == '/') return;
    final slash = p.lastIndexOf('/');
    _navigateTo(slash <= 0 ? '/' : p.substring(0, slash));
  }

  /// 提权:弹框校验成功后重列当前目录
  Future<void> _elevate() async {
    final onElevate = widget.onElevate;
    if (onElevate == null) return;
    final ok = await onElevate();
    if (ok && mounted) {
      setState(() => _needsElevation = false);
      _loadRoot();
    }
  }

  /// 从加载结果反推当前绝对路径:_currentRoot 已是绝对路径就用它;
  /// 否则(空串=家目录 / ~ 相对)取任一条目的父目录(远端 home 展开后的真值)
  String _deriveDisplayPath(List<_FileNode> children) {
    if (_currentRoot.startsWith('/')) return _currentRoot;
    if (children.isNotEmpty) {
      final p = children.first.path;
      final slash = p.lastIndexOf('/');
      return slash <= 0 ? '/' : p.substring(0, slash);
    }
    return _currentRoot.isEmpty ? '~' : _currentRoot;
  }

  @override
  void didUpdateWidget(covariant _TerminalFilesTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cwd != widget.cwd) {
      _query = '';
      _findController.clear();
      _currentRoot = widget.cwd;
      _loadRoot();
    }
  }

  @override
  void dispose() {
    _findController.dispose();
    for (final t in _transfers) {
      t.sub?.cancel();
    }
    super.dispose();
  }

  // ── 传输(上传/下载)──

  void _startTransfer(_PanelTransfer transfer, Stream<double> stream) {
    setState(() => _transfers.insert(0, transfer));
    transfer.sub = stream.listen(
      (p) {
        if (!mounted) return;
        setState(() => transfer.progress = p.clamp(0.0, 1.0));
      },
      onError: (Object e) {
        if (!mounted || transfer.cancelled) return;
        setState(() {
          transfer.failed = true;
          transfer.error = '$e';
        });
      },
      onDone: () {
        if (!mounted || transfer.cancelled) return;
        setState(() {
          transfer.done = true;
          transfer.progress = 1;
        });
        _loadRoot();
      },
    );
  }

  Future<void> _pickAndUpload(String remoteDir) async {
    final uploader = widget.remoteUploader;
    if (uploader == null) return;
    final initial = await FilePickerHelper.getInitialDirectory();
    final result = await FilePicker.pickFiles(
      dialogTitle: '选择要上传的文件',
      allowMultiple: true,
      initialDirectory: initial,
    );
    final paths = [
      for (final f in result?.files ?? const <PlatformFile>[])
        if (f.path != null && f.path!.isNotEmpty) f.path!,
    ];
    if (paths.isEmpty) return;
    FilePickerHelper.updateLastDirectory(paths.first);
    _uploadPaths(paths, remoteDir);
  }

  Future<void> _pickAndUploadDir(String remoteDir) async {
    final uploadDir = widget.remoteUploadDir;
    if (uploadDir == null) return;
    final initial = await FilePickerHelper.getInitialDirectory();
    final localDir = await FilePicker.getDirectoryPath(
      dialogTitle: '选择要上传的目录',
      initialDirectory: initial,
    );
    if (localDir == null || localDir.isEmpty) return;
    FilePickerHelper.updateLastDirectoryFromPath(localDir);
    final name = localDir.split('/').where((s) => s.isNotEmpty).last;
    _startTransfer(
      _PanelTransfer(label: '$name/', isUpload: true),
      uploadDir(localDir, remoteDir),
    );
  }

  /// 新建空文件:本地建一个空临时文件再上传(复用上传通道)
  Future<void> _newFileIn(String remoteDir) async {
    final uploader = widget.remoteUploader;
    if (uploader == null) return;
    final name = await _promptName(title: '新建文件', confirm: '创建');
    if (name == null || name.isEmpty) return;
    try {
      final tempDir = await Directory.systemTemp.createTemp('termora_newfile_');
      final localPath = '${tempDir.path}/$name';
      await File(localPath).create();
      _startTransfer(
        _PanelTransfer(label: name, isUpload: true),
        uploader(localPath, remoteDir),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('新建文件失败:$e')),
      );
    }
  }

  void _uploadPaths(List<String> localPaths, String remoteDir) {
    final uploader = widget.remoteUploader;
    if (uploader == null) return;
    for (final localPath in localPaths) {
      final name = localPath.split('/').last;
      _startTransfer(
        _PanelTransfer(label: name, isUpload: true),
        uploader(localPath, remoteDir),
      );
    }
  }

  Future<void> _downloadEntry(_FileNode node) async {
    final downloader = widget.remoteDownloader;
    if (downloader == null) return;
    final initial = await FilePickerHelper.getInitialDirectory();
    final String? localPath;
    if (node.isDir) {
      localPath = await FilePicker.getDirectoryPath(
        dialogTitle: '下载目录「${node.name}」到…',
        initialDirectory: initial,
      );
    } else {
      localPath = await FilePicker.saveFile(
        dialogTitle: '下载到…',
        fileName: node.name,
        initialDirectory: initial,
      );
    }
    if (localPath == null || localPath.isEmpty) return;
    FilePickerHelper.updateLastDirectoryFromPath(
      node.isDir ? localPath : File(localPath).parent.path,
    );
    _startTransfer(
      _PanelTransfer(label: node.isDir ? '${node.name}/' : node.name, isUpload: false),
      downloader(node.path, localPath, node.isDir),
    );
  }

  void _clearFinishedTransfers() {
    setState(() => _transfers.removeWhere((t) => !t.running));
  }

  // ── 增改删 ──

  Future<void> _runFileOp(Future<void> Function() op) async {
    try {
      await op();
      if (!mounted) return;
      _loadRoot();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('操作失败:$e')),
      );
    }
  }

  Future<void> _renameNode(_FileNode node) async {
    final rename = widget.remoteRename;
    if (rename == null) return;
    final name = await _promptName(
      title: '重命名',
      confirm: '重命名',
      initial: node.name,
    );
    if (name == null || name.isEmpty || name == node.name) return;
    await _runFileOp(() => rename(node.path, name));
  }

  Future<void> _deleteNode(_FileNode node) async {
    final del = widget.remoteDelete;
    if (del == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(node.isDir ? '删除目录' : '删除文件'),
        content: Text(
          node.isDir
              ? '确定删除目录「${node.name}」吗?(仅能删除空目录)'
              : '确定删除「${node.name}」吗?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.errorColor),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _runFileOp(() => del(node.path, node.isDir));
  }

  Future<void> _makeDirIn(String parentDir) async {
    final mkdir = widget.remoteMakeDir;
    if (mkdir == null) return;
    final name = await _promptName(title: '新建目录', confirm: '创建');
    if (name == null || name.isEmpty) return;
    await _runFileOp(() => mkdir(parentDir, name));
  }

  Future<void> _copyNodePath(_FileNode node) async {
    await Clipboard.setData(ClipboardData(text: node.path));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text('已复制路径:${node.path}')),
    );
  }

  Future<String?> _promptName({
    required String title,
    required String confirm,
    String initial = '',
  }) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(fontSize: 13, color: AppTheme.headingColor),
          decoration: const InputDecoration(
            isDense: true,
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.brandColor),
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: Text(confirm),
          ),
        ],
      ),
    );
  }

  Future<void> _showRowMenu(Offset globalPosition, _FileNode node) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final canDownload = widget.remoteDownloader != null;
    final canRename = widget.remoteRename != null;
    final canDelete = widget.remoteDelete != null;
    final action = await showMenu<String>(
      context: context,
      color: AppTheme.surfaceColor,
      position: RelativeRect.fromRect(
        globalPosition & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: [
        if (node.isDir)
          const PopupMenuItem(value: 'open', height: 34, child: Text('打开')),
        if (node.isDir && widget.onCdInTerminal != null)
          const PopupMenuItem(
            value: 'cd',
            height: 34,
            child: Text('在终端进入此目录'),
          ),
        if (!node.isDir)
          const PopupMenuItem(
            value: 'insert',
            height: 34,
            child: Text('插入路径到命令行'),
          ),
        if (canDownload)
          PopupMenuItem(
            value: 'download',
            height: 34,
            child: Text(node.isDir ? '下载目录' : '下载'),
          ),
        if (canRename)
          const PopupMenuItem(value: 'rename', height: 34, child: Text('重命名')),
        const PopupMenuItem(
          value: 'copyPath',
          height: 34,
          child: Text('复制远端路径'),
        ),
        if (canDelete) const PopupMenuDivider(),
        if (canDelete)
          PopupMenuItem(
            value: 'delete',
            height: 34,
            child: Text('删除', style: TextStyle(color: AppTheme.errorColor)),
          ),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'open':
        _onOpen(node);
      case 'cd':
        widget.onCdInTerminal?.call(node.path);
      case 'insert':
        widget.onInsertPath(node.path);
      case 'download':
        unawaited(_downloadEntry(node));
      case 'rename':
        unawaited(_renameNode(node));
      case 'copyPath':
        unawaited(_copyNodePath(node));
      case 'delete':
        unawaited(_deleteNode(node));
    }
  }

  /// 拖出到 Finder:立即发起拖拽,落点(接收方请求数据)时才下载。
  /// 目录不支持拖出(仍可用下载按钮)。返回 null 则不发起拖拽。
  Future<sdd.DragItem?> _dragItemFor(_FileNode node) async {
    final downloader = widget.remoteDownloader;
    if (downloader == null || node.isDir) return null;
    final item = sdd.DragItem(suggestedName: node.name);
    // 通用文件格式;数据惰性提供:Finder 落点时才触发 SFTP 下载
    const format = scb.SimpleFileFormat(
      uniformTypeIdentifiers: ['public.data'],
      mimeTypes: ['application/octet-stream'],
    );
    item.add(
      format.lazy(() async {
        final tempDir = await Directory.systemTemp.createTemp('termora_drag_');
        final localPath = '${tempDir.path}/${node.name}';
        final completer = Completer<void>();
        final sub = downloader(node.path, localPath, false).listen(
          (_) {},
          onError: (Object e) {
            if (!completer.isCompleted) completer.completeError(e);
          },
          onDone: () {
            if (!completer.isCompleted) completer.complete();
          },
          cancelOnError: true,
        );
        await completer.future;
        await sub.cancel();
        return File(localPath).readAsBytes();
      }),
    );
    return item;
  }

  Future<List<_FileNode>> _listDir(String path) async {
    final lister = widget.remoteLister;
    if (lister != null) {
      final entries = await lister(path);
      final nodes = [
        for (final e in entries)
          _FileNode(
            path: e.path,
            name: e.name,
            isDir: e.isDir,
            size: e.size,
            modified: e.modified,
          ),
      ];
      nodes.sort(_nodeSort);
      return nodes;
    }
    final entities = await Directory(path).list(followLinks: false).toList();
    final now = DateTime.now();
    final nodes = <_FileNode>[];
    for (final entity in entities) {
      final isDir = entity is Directory;
      var size = 0;
      var modified = '';
      try {
        final st = await entity.stat();
        size = st.size;
        modified = _formatLocalTime(st.modified, now);
      } catch (_) {}
      nodes.add(
        _FileNode(
          path: entity.path,
          name: _panelBaseName(entity.path),
          isDir: isDir,
          size: isDir ? 0 : size,
          modified: modified,
        ),
      );
    }
    nodes.sort(_nodeSort);
    return nodes;
  }

  int _nodeSort(_FileNode a, _FileNode b) {
    if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }

  String _formatLocalTime(DateTime t, DateTime now) {
    String two(int v) => v.toString().padLeft(2, '0');
    if (t.year == now.year) {
      return '${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
    }
    return '${t.year}-${two(t.month)}-${two(t.day)}';
  }

  Future<void> _loadRoot() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final children = await _listDir(_currentRoot);
      if (!mounted) return;
      setState(() {
        _nodes
          ..clear()
          ..addAll(children);
        _displayPath = _deriveDisplayPath(children);
        _loading = false;
        _needsElevation = false;
      });
    } catch (error) {
      // 权限拒绝且能提权、且尚未提权 → 给提权入口(不回落、不当普通错误)
      if (_isRemote &&
          !widget.elevated &&
          widget.onElevate != null &&
          '$error'.contains('Permission denied')) {
        if (!mounted) return;
        setState(() {
          _needsElevation = true;
          _loading = false;
          _nodes.clear();
        });
        return;
      }
      // 远端:探测到的目录不可用(常见于跨用户 su 后 ~ 展开偏差,
      // 终端 home 与 SFTP home 不同)→ 回落到远端家目录,避免卡报错
      if (_isRemote && _currentRoot.isNotEmpty) {
        try {
          final children = await _listDir('');
          if (!mounted) return;
          setState(() {
            _currentRoot = '';
            _nodes
              ..clear()
              ..addAll(children);
            _displayPath = _deriveDisplayPath(children);
            _loading = false;
            _error = null;
          });
          return;
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _loading = false;
        _nodes.clear();
      });
    }
  }

  /// 双击打开:目录进入(扁平导航,替换列表);文件下载(有下载通道)或插入路径
  void _onOpen(_FileNode node) {
    if (node.isDir) {
      _navigateTo(node.path);
      return;
    }
    if (widget.remoteDownloader != null) {
      unawaited(_downloadEntry(node));
    } else {
      widget.onInsertPath(node.path);
    }
  }

  List<_FileNode> get _visible {
    final query = _query.trim().toLowerCase();
    return [
      for (final node in _nodes)
        if ((_showHidden || !node.name.startsWith('.')) &&
            (query.isEmpty || node.name.toLowerCase().contains(query)))
          node,
    ];
  }

  @override
  Widget build(BuildContext context) {
    Widget content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_isRemote) _buildPathBar(),
        _buildFindBar(),
        Divider(height: 1, thickness: 1, color: AppTheme.borderColor),
        Expanded(child: _buildBody()),
        if (_transfers.isNotEmpty) _buildTransfersFooter(),
      ],
    );
    if (!_canTransfer) return content;
    // 远端可传输:整块作为 Finder 拖入的上传目标(拖到当前根目录)
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragOver = true),
      onDragExited: (_) => setState(() => _dragOver = false),
      onDragDone: (detail) {
        setState(() => _dragOver = false);
        final paths = [
          for (final f in detail.files)
            if (f.path.isNotEmpty) f.path,
        ];
        if (paths.isNotEmpty) _uploadPaths(paths, _rootDir);
      },
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(
            color: _dragOver ? AppTheme.brandColor : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: content,
      ),
    );
  }

  Widget _buildPathBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 8, 0),
      child: Row(
        children: [
          _TerminalIconButton(
            tooltip: '上一级',
            icon: LucideIcons.cornerLeftUp300,
            size: 26,
            iconSize: 13,
            ghost: true,
            onPressed: (_displayPath.isEmpty || _displayPath == '/')
                ? null
                : _goUp,
          ),
          const SizedBox(width: 2),
          Expanded(
            child: _PanelPathBar(
              path: _displayPath,
              enabled: !_loading,
              onSubmit: _navigateTo,
            ),
          ),
          if (widget.elevated)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Tooltip(
                message: '已提权(root)— 点击退出',
                child: InkWell(
                  borderRadius: BorderRadius.circular(4),
                  onTap: () {
                    widget.onDropElevation?.call();
                    _loadRoot();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.warningColor.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          LucideIcons.shieldCheck300,
                          size: 11,
                          color: AppTheme.warningColor,
                        ),
                        const SizedBox(width: 3),
                        Text(
                          'root',
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.warningColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            )
          else if (widget.onElevate != null)
            _TerminalIconButton(
              tooltip: '提权(sudo / su root)',
              icon: LucideIcons.shieldCheck300,
              size: 26,
              iconSize: 13,
              ghost: true,
              onPressed: () => unawaited(_elevate()),
            ),
        ],
      ),
    );
  }

  Widget _buildFindBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 32,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: AppTheme.subtleSurfaceColor.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.borderColor),
              ),
              child: Row(
                children: [
                  Icon(
                    LucideIcons.search300,
                    size: 14,
                    color: AppTheme.subtleTextColor,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: TextField(
                      controller: _findController,
                      onChanged: (value) => setState(() => _query = value),
                      style: TextStyle(
                        fontSize: 12.5,
                        color: AppTheme.headingColor,
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: 'Find',
                        hintStyle: TextStyle(
                          fontSize: 12.5,
                          color: AppTheme.subtleTextColor,
                        ),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 4),
          if (_hasCreateActions) _buildCreateMenuButton(),
          _TerminalIconButton(
            tooltip: _showHidden ? '隐藏隐藏文件' : '显示隐藏文件',
            icon: _showHidden ? LucideIcons.eye300 : LucideIcons.eyeOff300,
            size: 28,
            iconSize: 14,
            ghost: true,
            onPressed: () => setState(() => _showHidden = !_showHidden),
          ),
          _TerminalIconButton(
            tooltip: '刷新',
            icon: LucideIcons.refreshCw300,
            size: 28,
            iconSize: 14,
            ghost: true,
            onPressed: _loadRoot,
          ),
        ],
      ),
    );
  }

  bool get _hasCreateActions =>
      _canTransfer ||
      widget.remoteUploadDir != null ||
      widget.remoteMakeDir != null;

  Widget _buildCreateMenuButton() {
    return SizedBox(
      width: 28,
      height: 28,
      child: PopupMenuButton<String>(
        tooltip: '新建 / 上传',
        icon: Icon(
          LucideIcons.plus300,
          size: 14,
          color: AppTheme.subtleTextColor,
        ),
        iconSize: 14,
        splashRadius: 14,
        padding: EdgeInsets.zero,
        color: AppTheme.surfaceColor,
        itemBuilder: (context) => [
          if (_canTransfer)
            const PopupMenuItem(value: 'uploadFiles', height: 36, child: Text('上传文件…')),
          if (widget.remoteUploadDir != null)
            const PopupMenuItem(value: 'uploadDir', height: 36, child: Text('上传目录…')),
          if (_canTransfer)
            const PopupMenuItem(value: 'newFile', height: 36, child: Text('新建文件')),
          if (widget.remoteMakeDir != null)
            const PopupMenuItem(value: 'newDir', height: 36, child: Text('新建文件夹')),
        ],
        onSelected: (v) {
          switch (v) {
            case 'uploadFiles':
              unawaited(_pickAndUpload(_rootDir));
            case 'uploadDir':
              unawaited(_pickAndUploadDir(_rootDir));
            case 'newFile':
              unawaited(_newFileIn(_rootDir));
            case 'newDir':
              unawaited(_makeDirIn(_rootDir));
          }
        },
      ),
    );
  }

  Widget _buildTransfersFooter() {
    final running = _transfers.where((t) => t.running).length;
    return Container(
      constraints: const BoxConstraints(maxHeight: 150),
      decoration: BoxDecoration(
        color: AppTheme.subtleSurfaceColor.withValues(alpha: 0.3),
        border: Border(top: BorderSide(color: AppTheme.borderColor)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 4, 0),
            child: Row(
              children: [
                Text(
                  running > 0 ? '传输中 $running 项' : '传输记录',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.subtleTextColor,
                  ),
                ),
                const Spacer(),
                if (_transfers.any((t) => t.done || t.failed))
                  TextButton(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    onPressed: _clearFinishedTransfers,
                    child: Text(
                      '清除已完成',
                      style: TextStyle(
                        fontSize: 11,
                        color: AppTheme.subtleTextColor,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(10, 2, 10, 6),
              itemCount: _transfers.length,
              itemBuilder: (context, index) =>
                  _buildTransferRow(_transfers[index]),
            ),
          ),
        ],
      ),
    );
  }

  void _cancelPanelTransfer(_PanelTransfer transfer) {
    if (!transfer.running) return;
    // sub 取消会触发上游 StreamController.onCancel → 杀掉传输进程
    transfer.sub?.cancel();
    setState(() => transfer.cancelled = true);
  }

  Widget _buildTransferRow(_PanelTransfer transfer) {
    final Color color = transfer.failed
        ? AppTheme.errorColor
        : transfer.cancelled
        ? AppTheme.subtleTextColor
        : transfer.done
        ? AppTheme.successColor
        : AppTheme.brandColor;
    final label = transfer.failed
        ? '失败'
        : transfer.cancelled
        ? '已取消'
        : transfer.done
        ? '完成'
        : '${(transfer.progress * 100).round()}%';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            transfer.isUpload ? LucideIcons.upload300 : LucideIcons.download300,
            size: 12,
            color: color,
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 96,
            child: Tooltip(
              message: transfer.error ?? transfer.label,
              child: Text(
                transfer.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: AppTheme.headingColor),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                minHeight: 4,
                value: transfer.done ? 1.0 : (transfer.failed ? 0.0 : transfer.progress),
                backgroundColor: AppTheme.borderColor.withValues(alpha: 0.5),
                color: color,
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 34,
            child: Text(
              label,
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 10.5, color: color),
            ),
          ),
          SizedBox(
            width: 20,
            height: 20,
            child: transfer.running
                ? IconButton(
                    tooltip: '取消',
                    padding: EdgeInsets.zero,
                    splashRadius: 10,
                    icon: Icon(
                      LucideIcons.circleX300,
                      size: 12,
                      color: AppTheme.subtleTextColor,
                    ),
                    onPressed: () => _cancelPanelTransfer(transfer),
                  )
                : null,
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_needsElevation && !_loading) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                LucideIcons.lock300,
                size: 24,
                color: AppTheme.subtleTextColor.withValues(alpha: 0.6),
              ),
              const SizedBox(height: 10),
              Text(
                '没有权限访问该目录',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.headingColor,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'SFTP 以登录用户身份运行。提权后可 root 浏览/下载。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.4,
                  color: AppTheme.subtleTextColor,
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.brandColor,
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () => unawaited(_elevate()),
                icon: const Icon(LucideIcons.shieldCheck300, size: 13),
                label: const Text('提权访问', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
      );
    }
    if (_loading && _nodes.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_error != null) {
      return _panelMessage(LucideIcons.folder300, '无法读取目录\n$_error');
    }
    final visible = _visible;
    if (visible.isEmpty) {
      return _panelMessage(
        LucideIcons.folder300,
        _query.isEmpty ? '空目录' : '无匹配项',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: visible.length,
      itemBuilder: (context, index) => _buildNodeRow(visible[index]),
    );
  }

  Widget _buildNodeRow(_FileNode node) {
    return _PanelFileRow(
      node: node,
      onOpen: () => _onOpen(node),
      onDownload: widget.remoteDownloader == null
          ? null
          : () => _downloadEntry(node),
      onRename: widget.remoteRename == null ? null : () => _renameNode(node),
      onDelete: widget.remoteDelete == null ? null : () => _deleteNode(node),
      onContextMenu: _isRemote ? (pos) => _showRowMenu(pos, node) : null,
      dragItemProvider: widget.remoteDownloader == null || node.isDir
          ? null
          : () => _dragItemFor(node),
    );
  }
}

/// 文件面板里的一行(扁平):双击打开;悬停出下载/重命名/删除;显示大小+修改时间。
/// 提供 [dragItemProvider] 时(远端文件)可拖出到 Finder 下载。
class _PanelFileRow extends StatefulWidget {
  const _PanelFileRow({
    required this.node,
    required this.onOpen,
    this.onDownload,
    this.onRename,
    this.onDelete,
    this.onContextMenu,
    this.dragItemProvider,
  });

  final _FileNode node;
  final VoidCallback onOpen;
  final VoidCallback? onDownload;
  final VoidCallback? onRename;
  final VoidCallback? onDelete;
  final ValueChanged<Offset>? onContextMenu;
  final Future<sdd.DragItem?> Function()? dragItemProvider;

  @override
  State<_PanelFileRow> createState() => _PanelFileRowState();
}

class _PanelFileRowState extends State<_PanelFileRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final row = _buildRow();
    final provider = widget.dragItemProvider;
    if (provider == null) return row;
    // 拖出到 Finder:落点处触发下载(见 _dragItemFor)
    return sdd.DragItemWidget(
      allowedOperations: () => [sdd.DropOperation.copy],
      dragItemProvider: (_) => provider(),
      child: sdd.DraggableWidget(child: row),
    );
  }

  Widget _rowAction(String tooltip, IconData icon, VoidCallback onPressed, {Color? color}) {
    return SizedBox(
      width: 22,
      height: 22,
      child: IconButton(
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        splashRadius: 11,
        icon: Icon(icon, size: 13, color: color ?? AppTheme.subtleTextColor),
        onPressed: onPressed,
      ),
    );
  }

  Widget _buildRow() {
    final node = widget.node;
    final onContextMenu = widget.onContextMenu;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onSecondaryTapUp: onContextMenu == null
            ? null
            : (d) => onContextMenu(d.globalPosition),
        child: Material(
          color: _hovered
              ? AppTheme.subtleSurfaceColor.withValues(alpha: 0.5)
              : Colors.transparent,
          child: InkWell(
            onDoubleTap: widget.onOpen,
            onTap: () {},
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 4.5, 4, 4.5),
              child: Row(
                children: [
                  Icon(
                    node.isDir ? LucideIcons.folder300 : LucideIcons.file300,
                    size: 14,
                    color: node.isDir
                        ? AppTheme.brandColor
                        : AppTheme.subtleTextColor,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      node.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: AppTheme.headingColor,
                      ),
                    ),
                  ),
                  if (_hovered) ...[
                    if (widget.onDownload != null)
                      _rowAction(
                        node.isDir ? '下载目录' : '下载',
                        node.isDir
                            ? LucideIcons.folderDown300
                            : LucideIcons.download300,
                        widget.onDownload!,
                      ),
                    if (widget.onRename != null)
                      _rowAction('重命名', LucideIcons.penLine300, widget.onRename!),
                    if (widget.onDelete != null)
                      _rowAction(
                        '删除',
                        LucideIcons.trash300,
                        widget.onDelete!,
                        color: AppTheme.errorColor,
                      ),
                    const SizedBox(width: 4),
                  ] else ...[
                    SizedBox(
                      width: 58,
                      child: Text(
                        node.sizeLabel,
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          fontSize: 11,
                          color: AppTheme.subtleTextColor,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 80,
                      child: Text(
                        node.modified,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: AppTheme.subtleTextColor,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 文件面板顶部地址栏:显示当前远端路径,可编辑、回车跳转;
/// Esc/失焦恢复,外部导航后自动同步。
class _PanelPathBar extends StatefulWidget {
  const _PanelPathBar({
    required this.path,
    required this.enabled,
    required this.onSubmit,
  });

  final String path;
  final bool enabled;
  final ValueChanged<String> onSubmit;

  @override
  State<_PanelPathBar> createState() => _PanelPathBarState();
}

class _PanelPathBarState extends State<_PanelPathBar> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.path,
  );
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _controller.text = widget.path;
      setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant _PanelPathBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.path != oldWidget.path && !_focus.hasFocus) {
      _controller.text = widget.path;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          _controller.text = widget.path;
          _focus.unfocus();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: SizedBox(
        height: 28,
        child: TextField(
          controller: _controller,
          focusNode: _focus,
          enabled: widget.enabled,
          maxLines: 1,
          style: TextStyle(
            fontSize: 11.5,
            color: _focus.hasFocus
                ? AppTheme.headingColor
                : AppTheme.subtleTextColor,
            fontFamily: 'Menlo',
          ),
          decoration: InputDecoration(
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 8,
              vertical: 6,
            ),
            filled: true,
            fillColor: _focus.hasFocus
                ? AppTheme.subtleSurfaceColor.withValues(alpha: 0.6)
                : AppTheme.subtleSurfaceColor.withValues(alpha: 0.3),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(
                color: AppTheme.borderColor.withValues(alpha: 0.6),
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: AppTheme.brandColor),
            ),
            disabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(
                color: AppTheme.borderColor.withValues(alpha: 0.3),
              ),
            ),
          ),
          onSubmitted: (value) {
            final path = value.trim();
            if (path.isEmpty || path == widget.path) {
              _controller.text = widget.path;
              return;
            }
            widget.onSubmit(path);
          },
        ),
      ),
    );
  }
}

class _FileNode {
  _FileNode({
    required this.path,
    required this.name,
    required this.isDir,
    this.size = 0,
    this.modified = '',
  });

  final String path;
  final String name;
  final bool isDir;
  final int size;
  final String modified;

  String get sizeLabel {
    if (isDir) return '—';
    final s = size;
    if (s < 1024) return '$s B';
    if (s < 1024 * 1024) return '${(s / 1024).toStringAsFixed(1)} KB';
    if (s < 1024 * 1024 * 1024) {
      return '${(s / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(s / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

/// Shows the git branch and working-tree status of the terminal's cwd.
class _TerminalGitTab extends StatefulWidget {
  const _TerminalGitTab({
    super.key,
    required this.cwd,
    required this.runGit,
    required this.onInsertPath,
  });

  final String cwd;
  final Future<ProcessResult?> Function(List<String> args) runGit;
  final void Function(String fullPath) onInsertPath;

  @override
  State<_TerminalGitTab> createState() => _TerminalGitTabState();
}

class _TerminalGitTabState extends State<_TerminalGitTab> {
  bool _loading = true;
  bool _isRepo = false;
  String _branch = '';
  List<(String, String)> _entries = const [];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didUpdateWidget(covariant _TerminalGitTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cwd != widget.cwd) _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final inside = await widget.runGit(['rev-parse', '--is-inside-work-tree']);
    if (!mounted) return;
    if (inside == null ||
        inside.exitCode != 0 ||
        inside.stdout.toString().trim() != 'true') {
      setState(() {
        _isRepo = false;
        _loading = false;
      });
      return;
    }
    final branchResult = await widget.runGit([
      'rev-parse',
      '--abbrev-ref',
      'HEAD',
    ]);
    final statusResult = await widget.runGit(['status', '--porcelain']);
    if (!mounted) return;
    final entries = <(String, String)>[];
    for (final line in (statusResult?.stdout.toString() ?? '').split('\n')) {
      if (line.trim().isEmpty) continue;
      final code = line.length >= 2 ? line.substring(0, 2).trim() : '?';
      final path = line.length > 3 ? line.substring(3) : line;
      entries.add((code.isEmpty ? '?' : code, path));
    }
    setState(() {
      _isRepo = true;
      _branch = branchResult?.stdout.toString().trim() ?? '';
      _entries = entries;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (!_isRepo) {
      return _panelMessage(LucideIcons.gitBranch300, '当前目录不是 Git 仓库');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          child: Row(
            children: [
              Icon(
                LucideIcons.gitBranch300,
                size: 15,
                color: AppTheme.brandColor,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _branch.isEmpty ? '(游离 HEAD)' : _branch,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.headingColor,
                  ),
                ),
              ),
              _TerminalIconButton(
                tooltip: '刷新',
                icon: LucideIcons.refreshCw300,
                size: 28,
                iconSize: 14,
                ghost: true,
                onPressed: _refresh,
              ),
            ],
          ),
        ),
        Divider(height: 1, thickness: 1, color: AppTheme.borderColor),
        Expanded(
          child: _entries.isEmpty
              ? _panelMessage(LucideIcons.gitBranch300, '工作区干净')
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: _entries.length,
                  itemBuilder: (context, index) {
                    final (code, path) = _entries[index];
                    return Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () => widget.onInsertPath(
                          '${widget.cwd}${Platform.pathSeparator}$path',
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          child: Row(
                            children: [
                              _buildGitCodeChip(code),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  path,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: AppTheme.headingColor,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildGitCodeChip(String code) {
    final Color color;
    if (code.contains('?')) {
      color = AppTheme.subtleTextColor;
    } else if (code.contains('A')) {
      color = AppTheme.successColor;
    } else if (code.contains('D')) {
      color = AppTheme.errorColor;
    } else {
      color = AppTheme.warningColor;
    }
    return Container(
      width: 24,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        code,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}
