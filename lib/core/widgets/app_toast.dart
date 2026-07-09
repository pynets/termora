import 'package:flutter/material.dart';
import 'package:toastification/toastification.dart';

class AppToast {
  static ToastificationItem show({
    BuildContext? context,
    AlignmentGeometry? alignment,
    Duration? autoCloseDuration,
    OverlayState? overlayState,
    ToastificationAnimationBuilder? animationBuilder,
    ToastificationType? type,
    ToastificationStyle? style,
    Widget? title,
    Widget? description,
    Widget? icon,
    Color? primaryColor,
    Color? backgroundColor,
    Color? foregroundColor,
    EdgeInsetsGeometry? padding,
    EdgeInsetsGeometry? margin,
    BorderRadiusGeometry? borderRadius,
    BorderSide? borderSide,
    List<BoxShadow>? boxShadow,
    TextDirection? direction,
    bool? pauseOnHover,
    bool? showProgressBar,
    bool? applyBlurEffect,
    ProgressIndicatorThemeData? progressBarTheme,
    ToastCloseButton? closeButton,
    bool? closeOnClick,
    bool? dragToClose,
    DismissDirection? dismissDirection,
    ToastificationCallbacks callbacks = const ToastificationCallbacks(),
  }) {
    final isDark = context != null ? Theme.of(context).brightness == Brightness.dark : false;

    // 暗黑模式下，强制提亮毛玻璃背景并使用白色文字
    final effectiveBg = backgroundColor ?? (isDark ? const Color(0xFF2C2C2E) : null);
    final effectiveFg = foregroundColor ?? (isDark ? Colors.white : null);
    final effectiveBorder = borderSide ?? (isDark ? BorderSide.none : null);

    // 强制使用细字体 (w400) 统一风格
    Widget? wrapWithThinFont(Widget? widget) {
      if (widget == null) return null;
      return DefaultTextStyle.merge(
        style: const TextStyle(fontWeight: FontWeight.w400),
        child: widget,
      );
    }

    return toastification.show(
      context: context,
      alignment: alignment,
      autoCloseDuration: autoCloseDuration,
      overlayState: overlayState,
      animationBuilder: animationBuilder,
      type: type,
      style: style,
      title: wrapWithThinFont(title),
      description: wrapWithThinFont(description),
      icon: icon,
      primaryColor: primaryColor,
      backgroundColor: effectiveBg,
      foregroundColor: effectiveFg,
      padding: padding,
      margin: margin,
      borderRadius: borderRadius,
      borderSide: effectiveBorder,
      boxShadow: boxShadow,
      direction: direction,
      pauseOnHover: pauseOnHover,
      showProgressBar: showProgressBar,
      applyBlurEffect: applyBlurEffect,
      progressBarTheme: progressBarTheme,
      closeButton: closeButton ?? const ToastCloseButton(),
      closeOnClick: closeOnClick,
      dragToClose: dragToClose,
      dismissDirection: dismissDirection,
      callbacks: callbacks,
    );
  }
}
