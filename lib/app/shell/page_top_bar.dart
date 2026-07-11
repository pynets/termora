import 'package:flutter/material.dart';

import 'package:termora/app/theme/app_theme.dart';

/// 页面顶部栏高度 —— 与顶部拖动区/红绿灯带对齐,内容各页自定义。
const double kPageTopBarHeight = 44;

/// 页面头部栏 —— 每个功能页在此放自己的身份(图标 + 名称)与上下文(subtitle),
/// 右侧放该页相关操作。整条位于窗口顶部透明拖动区之下,空白处可拖动窗口。
class PageTopBar extends StatelessWidget {
  const PageTopBar({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final hasSubtitle = subtitle != null && subtitle!.isNotEmpty;

    return Container(
      height: kPageTopBarHeight,
      padding: const EdgeInsets.only(left: 16, right: 8),
      decoration: BoxDecoration(
        color: AppTheme.surfaceColor,
        border: Border(
          bottom: BorderSide(color: AppTheme.borderColor, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: AppTheme.brandColor),
          const SizedBox(width: 9),
          Text(
            title,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              color: AppTheme.headingColor,
            ),
          ),
          if (hasSubtitle) ...[
            const SizedBox(width: 11),
            Container(width: 1, height: 12, color: AppTheme.borderColor),
            const SizedBox(width: 11),
            Flexible(
              child: Text(
                subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: AppTheme.subtleTextColor,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
