import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:termora/app/theme/app_theme.dart';
import 'package:termora/core/l10n/app_l10n.dart';

/// 红色错误框:文本可选中复制,右侧一键拷贝按钮;超长内容内部滚动。
class CopyableErrorBox extends StatefulWidget {
  const CopyableErrorBox({super.key, required this.text, this.maxHeight = 120});

  final String text;
  final double maxHeight;

  @override
  State<CopyableErrorBox> createState() => _CopyableErrorBoxState();
}

class _CopyableErrorBoxState extends State<CopyableErrorBox> {
  bool _copied = false;
  Timer? _revert;

  @override
  void dispose() {
    _revert?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;
    setState(() => _copied = true);
    _revert?.cancel();
    _revert = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: AppTheme.errorColor.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: widget.maxHeight),
              child: SingleChildScrollView(
                child: SelectableText(
                  widget.text,
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.errorColor,
                    height: 1.45,
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: tr('复制'),
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(),
            padding: const EdgeInsets.all(5),
            icon: Icon(
              _copied ? LucideIcons.check : LucideIcons.copy,
              size: 13,
              color: _copied ? AppTheme.successColor : AppTheme.errorColor,
            ),
            onPressed: _copy,
          ),
        ],
      ),
    );
  }
}
