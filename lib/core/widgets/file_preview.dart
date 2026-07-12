import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:termora/app/theme/app_theme.dart';
import 'package:termora/core/l10n/app_l10n.dart';
import 'package:termora/features/notes/view/widgets/markdown_preview.dart';

/// 文件预览分类(按扩展名判定)
enum FilePreviewKind { text, markdown, image, other }

/// 通用文件预览对话框 — 本地与远端(SFTP)文件面板共用。
/// 文本/Markdown/图片内联渲染;其它类型(或超大/二进制)交系统默认打开。
///
/// [readBytes] 惰性提供内容:本地直读文件,远端下载到临时文件再读。
/// [openExternally] 用系统默认程序打开(本地=直接 open,远端=下临时再 open)。
class FilePreviewDialog extends StatefulWidget {
  const FilePreviewDialog({
    super.key,
    required this.name,
    required this.size,
    required this.readBytes,
    required this.openExternally,
  });

  final String name;
  final int size;
  final Future<Uint8List> Function() readBytes;
  final Future<void> Function() openExternally;

  /// 内联预览的大小上限(超过则只给「用系统默认打开」)
  static const int maxInlineBytes = 8 * 1024 * 1024;

  static const _textExts = {
    'txt', 'log', 'json', 'yaml', 'yml', 'toml', 'ini', 'conf', 'cfg',
    'env', 'sh', 'bash', 'zsh', 'fish', 'py', 'js', 'ts', 'jsx', 'tsx',
    'dart', 'go', 'rs', 'c', 'h', 'cpp', 'hpp', 'cc', 'java', 'kt', 'swift',
    'rb', 'php', 'pl', 'lua', 'sql', 'html', 'htm', 'css', 'scss', 'xml',
    'csv', 'tsv', 'properties', 'gradle', 'dockerfile', 'makefile', 'gitignore',
    'lock', 'sum', 'mod', 'vue', 'svelte', 'r', 'm', 'mm', 'vim', 'diff',
    'patch', 'text', 'nfo', 'srt',
  };
  static const _imageExts = {
    'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'ico', 'tiff', 'tif',
  };

  static FilePreviewKind kindOf(String name) {
    final lower = name.toLowerCase();
    final dot = lower.lastIndexOf('.');
    final ext = dot >= 0 ? lower.substring(dot + 1) : '';
    // 无扩展名的常见配置/文档文件也按文本
    final base = dot >= 0 ? lower.substring(0, dot) : lower;
    if (ext == 'md' || ext == 'markdown') return FilePreviewKind.markdown;
    if (_imageExts.contains(ext)) return FilePreviewKind.image;
    if (_textExts.contains(ext) ||
        const {'readme', 'license', 'dockerfile', 'makefile', 'changelog'}
            .contains(base)) {
      return FilePreviewKind.text;
    }
    return FilePreviewKind.other;
  }

  @override
  State<FilePreviewDialog> createState() => _FilePreviewDialogState();
}

class _FilePreviewDialogState extends State<FilePreviewDialog> {
  Uint8List? _bytes;
  String? _text;
  bool _loading = true;
  String? _error;
  late final FilePreviewKind _kind = FilePreviewDialog.kindOf(widget.name);

  @override
  void initState() {
    super.initState();
    if (_kind == FilePreviewKind.other ||
        widget.size > FilePreviewDialog.maxInlineBytes) {
      _loading = false; // 直接给系统打开入口,不读内容
    } else {
      _loadInline();
    }
  }

  Future<void> _loadInline() async {
    try {
      final bytes = await widget.readBytes();
      if (!mounted) return;
      setState(() {
        _bytes = bytes;
        if (_kind == FilePreviewKind.text ||
            _kind == FilePreviewKind.markdown) {
          // 二进制误判为文本时(含 NUL)回落系统打开
          if (bytes.contains(0)) {
            _text = null;
          } else {
            _text = _decode(bytes);
          }
        }
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  String _decode(Uint8List bytes) {
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return latin1.decode(bytes); // 非 UTF-8 兜底,保证可读
    }
  }

  Future<void> _openExternally() async {
    Navigator.of(context).maybePop();
    await widget.openExternally();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppTheme.surfaceColor,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820, maxHeight: 640),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(),
            Flexible(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final icon = switch (_kind) {
      FilePreviewKind.image => LucideIcons.image300,
      FilePreviewKind.markdown => LucideIcons.fileText300,
      FilePreviewKind.text => LucideIcons.fileText300,
      FilePreviewKind.other => LucideIcons.file300,
    };
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
      ),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      child: Row(
        children: [
          Icon(icon, size: 15, color: AppTheme.brandColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              widget.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppTheme.headingColor,
              ),
            ),
          ),
          IconButton(
            tooltip: tr('用系统默认打开'),
            icon: Icon(
              LucideIcons.externalLink300,
              size: 15,
              color: AppTheme.subtleTextColor,
            ),
            visualDensity: VisualDensity.compact,
            onPressed: _openExternally,
          ),
          IconButton(
            tooltip: tr('关闭'),
            icon: Icon(
              LucideIcons.x300,
              size: 15,
              color: AppTheme.subtleTextColor,
            ),
            visualDensity: VisualDensity.compact,
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(40),
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (_error != null) {
      return _fallback(tr2('无法预览:{0}', [_error!]));
    }
    // 超大 / 不支持内联 / 二进制 → 只给系统打开
    if (_kind == FilePreviewKind.other ||
        widget.size > FilePreviewDialog.maxInlineBytes) {
      return _fallback(
        widget.size > FilePreviewDialog.maxInlineBytes
            ? tr('文件较大,不做内联预览')
            : tr('该类型不支持内联预览'),
      );
    }
    switch (_kind) {
      case FilePreviewKind.image:
        final bytes = _bytes;
        if (bytes == null) return _fallback(tr('无法预览'));
        return InteractiveViewer(
          maxScale: 8,
          child: Center(
            child: Image.memory(
              bytes,
              errorBuilder: (_, _, _) => _fallback(tr('图片无法解码')),
            ),
          ),
        );
      case FilePreviewKind.markdown:
        final text = _text;
        if (text == null) return _fallback(tr('无法预览'));
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: MarkdownPreview(source: text),
        );
      case FilePreviewKind.text:
        final text = _text;
        if (text == null) return _fallback(tr('无法预览,可能是二进制文件'));
        return Scrollbar(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(14),
            child: SelectableText(
              text,
              style: const TextStyle(
                fontFamily: 'Menlo',
                fontSize: 12.5,
                height: 1.5,
              ),
            ),
          ),
        );
      case FilePreviewKind.other:
        return _fallback(tr('该类型不支持内联预览'));
    }
  }

  Widget _fallback(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              LucideIcons.fileQuestion300,
              size: 30,
              color: AppTheme.subtleTextColor.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: AppTheme.subtleTextColor),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.brandColor,
                visualDensity: VisualDensity.compact,
              ),
              onPressed: _openExternally,
              icon: const Icon(LucideIcons.externalLink300, size: 14),
              label: Text(tr('用系统默认打开')),
            ),
          ],
        ),
      ),
    );
  }
}
