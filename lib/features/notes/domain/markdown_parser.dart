/// 轻量 markdown 解析器 — 只依赖 Dart 核心库,产出块级 AST 供预览渲染。
///
/// 覆盖笔记场景的常用子集(对齐 gpt_markdown 的支持面,公式除外):
/// 标题 / 段落 / 围栏代码块 / 引用(可嵌套) / 有序·无序·任务列表(缩进嵌套+续行) /
/// 水平线 / 管道表格(含列对齐);行内支持粗斜删的任意嵌套组合、行内代码、
/// 反斜杠转义、链接(内部可再嵌样式)、图片、裸 URL 自动成链。
library;

// ══════════════ 行内节点 ══════════════

/// 一段行内文本及其叠加样式。样式用布尔标志而非互斥类型,
/// 这样 `**粗中带*斜***`、链接内加粗等嵌套组合都能表达。
class MdInline {
  const MdInline(
    this.text, {
    this.bold = false,
    this.italic = false,
    this.strikethrough = false,
    this.code = false,
    this.url,
    this.imageUrl,
  });

  final String text;
  final bool bold;
  final bool italic;
  final bool strikethrough;

  /// 行内代码(内部不再解析其他标记)
  final bool code;

  /// 非空 = 链接,值为目标地址
  final String? url;

  /// 非空 = 图片,值为图片地址(此时 text 是 alt)
  final String? imageUrl;

  bool get isPlain =>
      !bold &&
      !italic &&
      !strikethrough &&
      !code &&
      url == null &&
      imageUrl == null;

  /// 样式与目标完全一致(合并相邻文本片段用)
  bool sameStyle(MdInline other) =>
      bold == other.bold &&
      italic == other.italic &&
      strikethrough == other.strikethrough &&
      code == other.code &&
      url == other.url &&
      imageUrl == null &&
      other.imageUrl == null;

  @override
  String toString() {
    final flags = [
      if (bold) 'b',
      if (italic) 'i',
      if (strikethrough) 's',
      if (code) 'c',
      if (url != null) 'url=$url',
      if (imageUrl != null) 'img=$imageUrl',
    ].join(',');
    return 'MdInline("$text"${flags.isEmpty ? '' : ' $flags'})';
  }
}

// ══════════════ 块级节点 ══════════════

sealed class MdBlock {
  const MdBlock();
}

class MdHeading extends MdBlock {
  const MdHeading(this.level, this.spans);
  final int level; // 1..6
  final List<MdInline> spans;
}

class MdParagraph extends MdBlock {
  const MdParagraph(this.spans);
  final List<MdInline> spans;
}

class MdCodeBlock extends MdBlock {
  const MdCodeBlock(this.code, {this.language});
  final String code;
  final String? language;
}

class MdQuote extends MdBlock {
  const MdQuote(this.children);
  final List<MdBlock> children;
}

class MdListItem {
  const MdListItem(
    this.spans, {
    this.indent = 0,
    this.checked,
    this.number,
    this.taskIndex,
  });
  final List<MdInline> spans;

  /// 嵌套层级(每 2 个空格缩进算一层)
  final int indent;

  /// 任务列表勾选态;null = 普通列表项
  final bool? checked;

  /// 有序列表的序号;null = 无序
  final int? number;

  /// 全文任务项序号(从 0 起,按源码行序);供预览点击勾选框
  /// 映射回源码(MarkdownEditing.toggleTaskAt 同口径)。非任务项为 null。
  final int? taskIndex;
}

class MdList extends MdBlock {
  const MdList(this.items, {required this.ordered});
  final bool ordered;
  final List<MdListItem> items;
}

class MdDivider extends MdBlock {
  const MdDivider();
}

/// $$ 包裹的块级 LaTeX 公式。只支持块级,不做行内 $...$:
/// 笔记里 $ 大多是金额,行内匹配误伤率太高。
class MdMathBlock extends MdBlock {
  const MdMathBlock(this.tex);
  final String tex;
}

enum MdTableAlign { left, center, right }

class MdTable extends MdBlock {
  const MdTable(this.header, this.rows, {this.alignments = const []});
  final List<List<MdInline>> header;
  final List<List<List<MdInline>>> rows;

  /// 分隔行声明的各列对齐(:---: 居中,---: 右对齐);可能短于列数
  final List<MdTableAlign> alignments;

  MdTableAlign alignAt(int column) =>
      column < alignments.length ? alignments[column] : MdTableAlign.left;
}

// ══════════════ 解析器 ══════════════

/// 全文任务项计数(引用递归时共享,保持源码行序)
class _TaskCounter {
  int _value = 0;
  int next() => _value++;
}

class MarkdownParser {
  MarkdownParser._();

  static final _fenceRe = RegExp(r'^(```|~~~)\s*(\S*)\s*$');
  static final _headingRe = RegExp(r'^(#{1,6})\s+(.*)$');
  static final _dividerRe = RegExp(r'^([-*_])\s*(\1\s*){2,}$');
  static final _listItemRe =
      RegExp(r'^(\s*)(?:([-*+])|(\d{1,9})[.)])\s+(.*)$');
  static final _taskRe = RegExp(r'^\[([ xX])\]\s+(.*)$');
  static final _tableSeparatorRe = RegExp(r'^\s*\|?[\s:|-]+\|[\s:|-]*$');

  static List<MdBlock> parse(String source) {
    final lines = source.replaceAll('\r\n', '\n').split('\n');
    return _parseLines(lines, _TaskCounter());
  }

  static List<MdBlock> _parseLines(List<String> lines, _TaskCounter tasks) {
    final blocks = <MdBlock>[];
    final paragraph = <String>[];

    void flushParagraph() {
      if (paragraph.isEmpty) return;
      blocks.add(MdParagraph(parseInline(paragraph.join('\n'))));
      paragraph.clear();
    }

    var i = 0;
    while (i < lines.length) {
      final line = lines[i];
      final trimmed = line.trim();

      if (trimmed.isEmpty) {
        flushParagraph();
        i++;
        continue;
      }

      // 围栏代码块:到闭合围栏或文末
      final fence = _fenceRe.firstMatch(trimmed);
      if (fence != null) {
        flushParagraph();
        final marker = fence[1]!;
        final language = fence[2]!.isEmpty ? null : fence[2];
        final code = <String>[];
        i++;
        while (i < lines.length && lines[i].trim() != marker) {
          code.add(lines[i]);
          i++;
        }
        i++; // 跳过闭合围栏(越界安全)
        blocks.add(MdCodeBlock(code.join('\n'), language: language));
        continue;
      }

      // 块级公式:单行 $$E=mc^2$$ 或多行 $$ ... $$
      if (trimmed.startsWith(r'$$')) {
        flushParagraph();
        if (trimmed.length > 4 && trimmed.endsWith(r'$$')) {
          blocks.add(
            MdMathBlock(trimmed.substring(2, trimmed.length - 2).trim()),
          );
          i++;
          continue;
        }
        final tex = <String>[];
        final firstLineRest = trimmed.substring(2).trim();
        if (firstLineRest.isNotEmpty) tex.add(firstLineRest);
        i++;
        while (i < lines.length && lines[i].trim() != r'$$') {
          tex.add(lines[i]);
          i++;
        }
        i++; // 跳过闭合 $$(越界安全)
        blocks.add(MdMathBlock(tex.join('\n').trim()));
        continue;
      }

      final heading = _headingRe.firstMatch(trimmed);
      if (heading != null) {
        flushParagraph();
        blocks.add(
          MdHeading(heading[1]!.length, parseInline(heading[2]!.trim())),
        );
        i++;
        continue;
      }

      if (_dividerRe.hasMatch(trimmed)) {
        flushParagraph();
        blocks.add(const MdDivider());
        i++;
        continue;
      }

      // 引用:收集连续 > 行,剥前缀后递归解析
      if (trimmed.startsWith('>')) {
        flushParagraph();
        final inner = <String>[];
        while (i < lines.length && lines[i].trim().startsWith('>')) {
          inner.add(lines[i].trim().replaceFirst(RegExp(r'^>\s?'), ''));
          i++;
        }
        // 共享任务计数器,引用内的任务项与全文行序一致
        blocks.add(MdQuote(_parseLines(inner, tasks)));
        continue;
      }

      // 列表:收集连续列表项(以首项有无序号定表类型)。
      // 悬挂缩进的非项行并入上一项;项之间允许单个空行(松散列表)。
      final firstItem = _listItemRe.firstMatch(line);
      if (firstItem != null) {
        flushParagraph();
        final ordered = firstItem[3] != null;
        final items = <MdListItem>[];
        // indent, checked, number, taskIndex, 文本
        (int, bool?, int?, int?, StringBuffer)? pending;
        void flushItem() {
          final p = pending;
          if (p == null) return;
          items.add(
            MdListItem(
              parseInline(p.$5.toString()),
              indent: p.$1,
              checked: p.$2,
              number: p.$3,
              taskIndex: p.$4,
            ),
          );
          pending = null;
        }

        while (i < lines.length) {
          final current = lines[i];
          final m = _listItemRe.firstMatch(current);
          if (m != null) {
            flushItem();
            var body = m[4]!;
            bool? checked;
            final task = _taskRe.firstMatch(body);
            if (task != null) {
              checked = task[1]!.toLowerCase() == 'x';
              body = task[2]!;
            }
            pending = (
              m[1]!.length ~/ 2,
              checked,
              m[3] != null ? int.tryParse(m[3]!) : null,
              checked != null ? tasks.next() : null,
              StringBuffer(body),
            );
            i++;
            continue;
          }
          if (current.trim().isEmpty) {
            // 空行后紧跟同类型列表项则同一列表继续(松散列表),否则列表结束
            final next = i + 1 < lines.length
                ? _listItemRe.firstMatch(lines[i + 1])
                : null;
            if (next != null && (next[3] != null) == ordered) {
              i++;
              continue;
            }
            break;
          }
          // 缩进续行:并入上一项
          if (pending != null && current.startsWith('  ')) {
            pending!.$5.write('\n${current.trim()}');
            i++;
            continue;
          }
          break;
        }
        flushItem();
        blocks.add(MdList(items, ordered: ordered));
        continue;
      }

      // 表格:当前行含 | 且下一行是分隔行
      if (line.contains('|') &&
          i + 1 < lines.length &&
          _tableSeparatorRe.hasMatch(lines[i + 1]) &&
          lines[i + 1].contains('-')) {
        flushParagraph();
        final header = _splitTableRow(line);
        final alignments = _parseAlignments(lines[i + 1]);
        final rows = <List<List<MdInline>>>[];
        i += 2;
        while (i < lines.length && lines[i].contains('|')) {
          rows.add(_splitTableRow(lines[i]));
          i++;
        }
        blocks.add(MdTable(header, rows, alignments: alignments));
        continue;
      }

      paragraph.add(line.trimRight());
      i++;
    }
    flushParagraph();
    return blocks;
  }

  static List<String> _splitRowCells(String line) {
    var s = line.trim();
    if (s.startsWith('|')) s = s.substring(1);
    if (s.endsWith('|')) s = s.substring(0, s.length - 1);
    return s.split('|');
  }

  static List<List<MdInline>> _splitTableRow(String line) =>
      [for (final cell in _splitRowCells(line)) parseInline(cell.trim())];

  static List<MdTableAlign> _parseAlignments(String separatorLine) {
    return [
      for (final cell in _splitRowCells(separatorLine))
        switch ((cell.trim().startsWith(':'), cell.trim().endsWith(':'))) {
          (true, true) => MdTableAlign.center,
          (false, true) => MdTableAlign.right,
          _ => MdTableAlign.left,
        },
    ];
  }

  // ══════════════ 行内解析 ══════════════

  /// 行内标记主正则,按优先级排列:
  /// 转义 > 行内代码 > 图片 > 链接 > 粗斜体 > 粗体 > 斜体 > 删除线 > 裸链接。
  /// 下划线斜体要求词边界,避免 snake_case 误判。
  static final _inlineRe = RegExp(
    r'\\([\\`*_{}\[\]()#+\-.!~|])'          // 1: 反斜杠转义
    r'|(`{1,2})(.+?)\2'                      // 2,3: 行内代码(支持双反引号包单反引号)
    r'|!\[([^\]]*)\]\(([^)\s]*)(?:\s[^)]*)?\)' // 4,5: 图片
    r'|\[([^\]]+)\]\(([^)\s]*)(?:\s[^)]*)?\)'  // 6,7: 链接
    r'|\*\*\*(.+?)\*\*\*'                    // 8: 粗斜体
    r'|\*\*(.+?)\*\*'                        // 9: 粗体
    r'|\*([^*\s](?:[^*]*[^*\s])?)\*'         // 10: 斜体(*)
    r'|(?<![\w`])_([^_\s](?:[^_]*[^_\s])?)_(?![\w`])' // 11: 斜体(_),词边界
    r'|~~(.+?)~~'                            // 12: 删除线
    r'|(https?://[^\s<>一-鿿]+)',    // 13: 裸 URL 自动成链
  );

  /// 行内主正则,供源码实时着色(markdown_source_highlighter)复用,
  /// 组号语义见 [_inlineRe] 的注释
  static RegExp get inlinePattern => _inlineRe;

  static List<MdInline> parseInline(String text) =>
      _mergeAdjacent(_parseStyled(text));

  static List<MdInline> _parseStyled(
    String text, {
    bool bold = false,
    bool italic = false,
    bool strike = false,
    String? url,
  }) {
    final spans = <MdInline>[];

    void addText(String s) {
      if (s.isEmpty) return;
      spans.add(
        MdInline(s, bold: bold, italic: italic, strikethrough: strike, url: url),
      );
    }

    // 嵌套递归:内层继承外层样式再叠加自己的
    void recurse(String inner, {bool b = false, bool i = false, bool s = false}) {
      spans.addAll(
        _parseStyled(
          inner,
          bold: bold || b,
          italic: italic || i,
          strike: strike || s,
          url: url,
        ),
      );
    }

    var index = 0;
    for (final m in _inlineRe.allMatches(text)) {
      addText(text.substring(index, m.start));
      index = m.end;
      if (m[1] != null) {
        addText(m[1]!); // 转义:输出字面字符
      } else if (m[3] != null) {
        spans.add(
          MdInline(
            m[3]!.trim(),
            code: true,
            bold: bold,
            italic: italic,
            strikethrough: strike,
            url: url,
          ),
        );
      } else if (m[5] != null) {
        spans.add(MdInline(m[4] ?? '', imageUrl: m[5]));
      } else if (m[6] != null) {
        // 链接文本内部继续解析样式,目标地址下传
        spans.addAll(
          _parseStyled(
            m[6]!,
            bold: bold,
            italic: italic,
            strike: strike,
            url: m[7],
          ),
        );
      } else if (m[8] != null) {
        recurse(m[8]!, b: true, i: true);
      } else if (m[9] != null) {
        recurse(m[9]!, b: true);
      } else if (m[10] != null) {
        recurse(m[10]!, i: true);
      } else if (m[11] != null) {
        recurse(m[11]!, i: true);
      } else if (m[12] != null) {
        recurse(m[12]!, s: true);
      } else if (m[13] != null) {
        // 裸 URL:剥掉黏在结尾的标点
        var link = m[13]!;
        final trailing = RegExp(r'[.,;:!?)\]]+$').firstMatch(link);
        if (trailing != null) {
          link = link.substring(0, trailing.start);
          index = m.start + link.length;
        }
        if (link.isNotEmpty) {
          spans.add(
            MdInline(
              link,
              url: link,
              bold: bold,
              italic: italic,
              strikethrough: strike,
            ),
          );
        }
      }
    }
    addText(text.substring(index));
    return spans;
  }

  /// 合并相邻且样式一致的文本片段(转义等会切碎文本)
  static List<MdInline> _mergeAdjacent(List<MdInline> spans) {
    final merged = <MdInline>[];
    for (final s in spans) {
      final last = merged.lastOrNull;
      if (last != null && !last.code && !s.code && last.sameStyle(s)) {
        merged[merged.length - 1] = MdInline(
          last.text + s.text,
          bold: last.bold,
          italic: last.italic,
          strikethrough: last.strikethrough,
          url: last.url,
        );
      } else {
        merged.add(s);
      }
    }
    return merged;
  }
}
