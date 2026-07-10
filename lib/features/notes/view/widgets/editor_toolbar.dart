import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:termora/app/theme/app_theme.dart';
import 'package:termora/features/notes/domain/markdown_editing.dart';

/// 浮动格式工具栏(marktext 式):选中文字时浮现在选区上方,
/// 提供行内格式操作。挂在 Overlay 里,由 notes_page 定位。
class FloatingFormatToolbar extends StatelessWidget {
  const FloatingFormatToolbar({
    super.key,
    required this.controller,
    required this.focusNode,
    this.onPickImage,
  });

  final TextEditingController controller;
  final FocusNode focusNode;

  /// 选择图片文件插入(null 时退回插入占位语法)
  final VoidCallback? onPickImage;

  /// 定位用的估算宽度(7 个按钮 + 内边距)
  static const double estimatedWidth = 7 * 27 + 12;
  static const double height = 34;

  void _apply(TextEditingValue Function(TextEditingValue) transform) {
    controller.value = transform(controller.value);
    focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    // TextFieldTapRegion:点工具栏不算"点在编辑器外",避免失焦收起
    return TextFieldTapRegion(
      child: Material(
        color: Colors.transparent,
        child: Container(
          height: height,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: AppTheme.surfaceColor,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: AppTheme.borderColor, width: 0.6),
            boxShadow: const [
              BoxShadow(
                color: Color(0x22000000),
                blurRadius: 12,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _button(
                LucideIcons.bold,
                '粗体 (⌘B)',
                () => _apply((v) => MarkdownEditing.toggleInline(v, '**')),
              ),
              _button(
                LucideIcons.italic,
                '斜体 (⌘I)',
                () => _apply((v) => MarkdownEditing.toggleInline(v, '*')),
              ),
              _button(
                LucideIcons.strikethrough,
                '删除线',
                () => _apply((v) => MarkdownEditing.toggleInline(v, '~~')),
              ),
              _button(
                LucideIcons.code,
                '行内代码',
                () => _apply((v) => MarkdownEditing.toggleInline(v, '`')),
              ),
              _button(
                LucideIcons.link,
                '链接 (⌘K)',
                () => _apply(MarkdownEditing.insertLink),
              ),
              _button(
                LucideIcons.image,
                '插入图片',
                onPickImage ?? () => _apply(MarkdownEditing.insertImage),
              ),
              _button(
                LucideIcons.removeFormatting,
                '清除格式',
                () => _apply(MarkdownEditing.clearInline),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _button(IconData icon, String tooltip, VoidCallback onPressed) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          child: Icon(icon, size: 15, color: AppTheme.bodyColor),
        ),
      ),
    );
  }
}

/// 「插入」菜单 — marktext 段落菜单的精简版:
/// 块级元素(标题/引用/列表/表格/代码块/公式/分隔线)+ 链接图片
class NoteInsertMenu extends StatelessWidget {
  const NoteInsertMenu({
    super.key,
    required this.controller,
    required this.focusNode,
    this.onPickImage,
    this.onPickFile,
  });

  final TextEditingController controller;
  final FocusNode focusNode;

  /// 选择图片文件插入(null 时退回插入占位语法)
  final VoidCallback? onPickImage;

  /// 选择视频/任意文件作为附件插入
  final VoidCallback? onPickFile;

  void _apply(TextEditingValue Function(TextEditingValue) transform) {
    controller.value = transform(controller.value);
    focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final actions = <(IconData, String, TextEditingValue Function(TextEditingValue))>[
      (LucideIcons.heading1, '一级标题', (v) => MarkdownEditing.setHeading(v, 1)),
      (LucideIcons.heading2, '二级标题', (v) => MarkdownEditing.setHeading(v, 2)),
      (LucideIcons.heading3, '三级标题', (v) => MarkdownEditing.setHeading(v, 3)),
      (LucideIcons.textQuote, '引用', (v) => MarkdownEditing.toggleLinePrefix(v, '> ')),
      (LucideIcons.list, '无序列表', (v) => MarkdownEditing.toggleLinePrefix(v, '- ')),
      (LucideIcons.listOrdered, '有序列表', MarkdownEditing.toggleOrderedList),
      (LucideIcons.listTodo, '任务列表', (v) => MarkdownEditing.toggleLinePrefix(v, '- [ ] ')),
      (
        LucideIcons.table,
        '表格',
        (v) => MarkdownEditing.insertBlock(
          v,
          '| 列1 | 列2 |\n| --- | --- |\n|  |  |',
          caretOffset: 2,
        ),
      ),
      (
        LucideIcons.squareCode,
        '代码块',
        (v) => MarkdownEditing.insertBlock(v, '```\n\n```', caretOffset: 4),
      ),
      (
        LucideIcons.sigma,
        '公式块',
        (v) => MarkdownEditing.insertBlock(v, '\$\$\n\n\$\$', caretOffset: 3),
      ),
      (LucideIcons.minus, '分隔线', (v) => MarkdownEditing.insertBlock(v, '---')),
      (LucideIcons.link, '链接', MarkdownEditing.insertLink),
      (
        LucideIcons.image,
        '图片…',
        (v) {
          // 有选图回调走文件选择器(异步流程自行插入),此处不动文本
          final pick = onPickImage;
          if (pick == null) return MarkdownEditing.insertImage(v);
          pick();
          return v;
        },
      ),
      if (onPickFile != null)
        (
          LucideIcons.paperclip,
          '文件 / 视频…',
          (v) {
            onPickFile!();
            return v;
          },
        ),
    ];

    return PopupMenuButton<int>(
      tooltip: '插入',
      position: PopupMenuPosition.under,
      onSelected: (index) => _apply(actions[index].$3),
      itemBuilder: (context) => [
        for (final (index, item) in actions.indexed)
          PopupMenuItem(
            value: index,
            height: 34,
            child: Row(
              children: [
                Icon(item.$1, size: 15, color: AppTheme.subtleTextColor),
                const SizedBox(width: 10),
                Text(
                  item.$2,
                  style: TextStyle(fontSize: 13, color: AppTheme.headingColor),
                ),
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.plus, size: 15, color: AppTheme.subtleTextColor),
            Icon(
              LucideIcons.chevronDown,
              size: 11,
              color: AppTheme.subtleTextColor,
            ),
          ],
        ),
      ),
    );
  }
}
