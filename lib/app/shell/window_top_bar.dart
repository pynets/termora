import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:window_manager/window_manager.dart';

import 'package:termora/app/theme/app_theme.dart';
import 'package:termora/core/l10n/app_l10n.dart';

/// 一体化标题栏高度 —— 参考 superdesk:侧栏与内容卡片各自把背景铺到顶,
/// 真实内容整体下移这个高度,顶部这条只承担窗口拖动(透明),红绿灯浮在其左侧。
const double kWindowTitleBarHeight = 36;

/// 透明可拖动条 —— 铺满顶部宽度承担窗口拖动。
/// macOS 红绿灯为原生绘制在其之上,点击不受影响;非 macOS 右侧叠自绘窗口控件。
class WindowDragArea extends StatelessWidget {
  const WindowDragArea({super.key});

  @override
  Widget build(BuildContext context) {
    return const DragToMoveArea(
      child: SizedBox(height: kWindowTitleBarHeight, width: double.infinity),
    );
  }
}

/// Windows/Linux 隐藏原生标题栏后自绘窗口控件(最小化/最大化/关闭)。
/// macOS 用原生红绿灯,此组件不渲染任何内容。
class WindowCaptionButtons extends StatefulWidget {
  const WindowCaptionButtons({super.key});

  @override
  State<WindowCaptionButtons> createState() => _WindowCaptionButtonsState();
}

class _WindowCaptionButtonsState extends State<WindowCaptionButtons>
    with WindowListener {
  bool _isMaximized = false;

  @override
  void initState() {
    super.initState();
    if (!Platform.isMacOS) {
      windowManager.addListener(this);
      windowManager.isMaximized().then((value) {
        if (mounted) setState(() => _isMaximized = value);
      });
    }
  }

  @override
  void dispose() {
    if (!Platform.isMacOS) windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() {
    if (mounted) setState(() => _isMaximized = true);
  }

  @override
  void onWindowUnmaximize() {
    if (mounted) setState(() => _isMaximized = false);
  }

  @override
  Widget build(BuildContext context) {
    if (Platform.isMacOS) return const SizedBox.shrink();
    final l10n = AppL10n.current;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _CaptionButton(
          icon: LucideIcons.minus,
          tooltip: l10n.minimizeWindow,
          onPressed: windowManager.minimize,
        ),
        _CaptionButton(
          icon: _isMaximized ? LucideIcons.copy : LucideIcons.square,
          tooltip: _isMaximized ? l10n.restoreWindow : l10n.maximizeWindow,
          onPressed: () async {
            if (await windowManager.isMaximized()) {
              await windowManager.unmaximize();
            } else {
              await windowManager.maximize();
            }
          },
        ),
        _CaptionButton(
          icon: LucideIcons.x,
          tooltip: l10n.close,
          // setPreventClose 已开启:close() 会触发托盘的 onWindowClose 收到托盘
          onPressed: windowManager.close,
          isClose: true,
        ),
      ],
    );
  }
}

class _CaptionButton extends StatefulWidget {
  const _CaptionButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.isClose = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool isClose;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final hoverColor = widget.isClose
        ? const Color(0xFFE81123)
        : AppTheme.mutedSurfaceColor;
    final iconColor = _isHovered && widget.isClose
        ? Colors.white
        : AppTheme.subtleTextColor;

    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: Container(
            width: 46,
            height: kWindowTitleBarHeight,
            color: _isHovered ? hoverColor : Colors.transparent,
            child: Icon(widget.icon, size: 15, color: iconColor),
          ),
        ),
      ),
    );
  }
}
