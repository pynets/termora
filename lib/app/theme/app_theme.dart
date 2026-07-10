import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:termora/core/l10n/app_l10n.dart';

class _FadePageTransitionsBuilder extends PageTransitionsBuilder {
  const _FadePageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return FadeTransition(opacity: animation, child: child);
  }
}


enum AppBrandColor {
  teal(
    '青色 (Teal)',
    Color(0xFF6A8A82),
    Color(0xFFE2EAE7),
    Color(0xFF6A8A82),
    Color(0xFF75978F),
    Color(0xFF2C3E38),
    Color(0xFF384F48),
  ),
  slate(
    '蓝灰 (Slate)',
    Color(0xFF788591),
    Color(0xFFE8EBED),
    Color(0xFF788591),
    Color(0xFF8B9BA7),
    Color(0xFF323B42),
    Color(0xFF424C55),
  ),
  indigo(
    '紫蓝 (Indigo)',
    Color(0xFF6A6887),
    Color(0xFFE4E3E8),
    Color(0xFF6A6887),
    Color(0xFF7E7C9E),
    Color(0xFF2C2B3C),
    Color(0xFF3C3B4E),
  ),
  emerald(
    '绿色 (Emerald)',
    Color(0xFF7B9983),
    Color(0xFFE6EBE7),
    Color(0xFF7B9983),
    Color(0xFF8BAE95),
    Color(0xFF334238),
    Color(0xFF445749),
  ),
  charcoal(
    '灰色 (Charcoal)',
    Color(0xFF636567),
    Color(0xFFE4E4E5),
    Color(0xFF636567),
    Color(0xFF7A7C7F),
    Color(0xFF2C2C2D),
    Color(0xFF3C3C3E),
  ),
  burgundy(
    '酒红 (Burgundy)',
    Color(0xFF9E716D),
    Color(0xFFEBE3E2),
    Color(0xFF9E716D),
    Color(0xFFB58480),
    Color(0xFF422F2E),
    Color(0xFF573E3C),
  ),
  night(
    '夜色 (Night)',
    Color(0xFF555960),
    Color(0xFFE3E3E5),
    Color(0xFF555960),
    Color(0xFF6B6F77),
    Color(0xFF282A2D),
    Color(0xFF373A3E),
  ),
  amber(
    '奶咖 (Amber)',
    Color(0xFFA68B74),
    Color(0xFFEBE6E3),
    Color(0xFFA68B74),
    Color(0xFFC2A38A),
    Color(0xFF4A3E34),
    Color(0xFF615144),
  ),
  rose(
    '烟粉 (Rose)',
    Color(0xFFB48A8D),
    Color(0xFFEFE6E7),
    Color(0xFFB48A8D),
    Color(0xFFCC9FA2),
    Color(0xFF4D3B3C),
    Color(0xFF664F51),
  ),
  violet(
    '灰紫 (Violet)',
    Color(0xFF867C94),
    Color(0xFFEAE8EB),
    Color(0xFF867C94),
    Color(0xFF9E92AE),
    Color(0xFF3B3742),
    Color(0xFF4F4A57),
  ),
  cyan(
    '雾蓝 (Cyan)',
    Color(0xFF748D93),
    Color(0xFFE5EBEB),
    Color(0xFF748D93),
    Color(0xFF89A5AC),
    Color(0xFF343F42),
    Color(0xFF455458),
  ),
  olive(
    '橄榄 (Olive)',
    Color(0xFF8A9376),
    Color(0xFFE9EBE5),
    Color(0xFF8A9376),
    Color(0xFFA0AA8A),
    Color(0xFF3E4236),
    Color(0xFF525847),
  );

  final String labelZh;

  /// 展示名(查表翻译;数据本体保持中文作 key)
  String get label => AppL10n.tr(labelZh);
  final Color lightBrandColor;
  final Color lightSoftBrandColor;
  final Color lightUserBubbleColor;
  final Color darkBrandColor;
  final Color darkSoftBrandColor;
  final Color darkUserBubbleColor;

  const AppBrandColor(
    this.labelZh,
    this.lightBrandColor,
    this.lightSoftBrandColor,
    this.lightUserBubbleColor,
    this.darkBrandColor,
    this.darkSoftBrandColor,
    this.darkUserBubbleColor,
  );
}

class AppTheme {
  static Brightness _brightness = Brightness.light;
  static AppBrandColor _brandColor = AppBrandColor.teal;

  // Static standard neutral surfaces
  static const Color _lightBackgroundColor = Color(0xFFF5F5F2);
  static const Color _lightSurfaceColor = Colors.white;
  static const Color _lightMutedSurfaceColor = Color(0xFFF7F7F4);
  static const Color _lightSubtleSurfaceColor = Color(0xFFF0F2EF);
  static const Color _lightBorderColor = Color(0xFFE2E5E0);
  static const Color _lightHeadingColor = Color(0xFF111827);
  static const Color _lightBodyColor = Color(0xFF4B5563);
  static const Color _lightSubtleTextColor = Color(0xFF6B7280);
  
  // Status Colors (Light)
  static const Color _lightErrorColor = Color(0xFFEF4444); // red-500
  static const Color _lightWarningColor = Color(0xFFF59E0B); // amber-500
  static const Color _lightSuccessColor = Color(0xFF10B981); // emerald-500

  static const Color _darkBackgroundColor = Color(0xFF171C1A);
  static const Color _darkSurfaceColor = Color(0xFF202724);
  static const Color _darkMutedSurfaceColor = Color(0xFF29322F);
  static const Color _darkSubtleSurfaceColor = Color(0xFF31413B);
  static const Color _darkBorderColor = Color(0xFF3F4C47);
  static const Color _darkHeadingColor = Color(0xFFEAF2EE);
  static const Color _darkBodyColor = Color(0xFFC0CBC5);
  static const Color _darkSubtleTextColor = Color(0xFF8E9B95);

  // Status Colors (Dark)
  static const Color _darkErrorColor = Color(0xFFF87171); // red-400
  static const Color _darkWarningColor = Color(0xFFFBBF24); // amber-400
  static const Color _darkSuccessColor = Color(0xFF34D399); // emerald-400

  static bool get _isDark => _brightness == Brightness.dark;

  /// 当前是否深色主题(终端调色板等需要按主题选默认色的场景用)
  static bool get isDarkMode => _isDark;

  static void useBrightness(Brightness brightness) {
    _brightness = brightness;
  }

  static void useBrandColor(AppBrandColor brandColor) {
    _brandColor = brandColor;
  }

  // Dynamic getters relying on Brand Color
  static Color get brandColor =>
      _isDark ? _brandColor.darkBrandColor : _brandColor.lightBrandColor;
  static Color get softBrandColor => _isDark
      ? _brandColor.darkSoftBrandColor
      : _brandColor.lightSoftBrandColor;
  static Color get userBubbleColor => _isDark
      ? _brandColor.darkUserBubbleColor
      : _brandColor.lightUserBubbleColor;

  // Standard static getters
  static Color get backgroundColor =>
      _isDark ? _darkBackgroundColor : _lightBackgroundColor;
  static Color get surfaceColor =>
      _isDark ? _darkSurfaceColor : _lightSurfaceColor;
  static Color get mutedSurfaceColor =>
      _isDark ? _darkMutedSurfaceColor : _lightMutedSurfaceColor;
  static Color get subtleSurfaceColor =>
      _isDark ? _darkSubtleSurfaceColor : _lightSubtleSurfaceColor;
  static Color get borderColor =>
      _isDark ? _darkBorderColor : _lightBorderColor;
  static Color get headingColor =>
      _isDark ? _darkHeadingColor : _lightHeadingColor;
  static Color get bodyColor => _isDark ? _darkBodyColor : _lightBodyColor;
  static Color get subtleTextColor =>
      _isDark ? _darkSubtleTextColor : _lightSubtleTextColor;
      
  static Color get errorColor => _isDark ? _darkErrorColor : _lightErrorColor;
  static Color get warningColor => _isDark ? _darkWarningColor : _lightWarningColor;
  static Color get successColor => _isDark ? _darkSuccessColor : _lightSuccessColor;

  static BoxDecoration panelDecoration({Color? color, bool elevated = false}) {
    return BoxDecoration(
      color: color ?? surfaceColor,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: borderColor),
      boxShadow: elevated
          ? const [
              BoxShadow(
                color: Color(0x06111827),
                blurRadius: 14,
                offset: Offset(0, 4),
              ),
            ]
          : const [],
    );
  }

  // 全局系统字体
  static String? get appFontFamily {
    switch (defaultTargetPlatform) {
      case TargetPlatform.macOS:
      case TargetPlatform.iOS:
        return 'PingFang SC';
      case TargetPlatform.windows:
        return 'Microsoft YaHei';
      case TargetPlatform.linux:
        return 'Noto Sans CJK SC';
      case TargetPlatform.android:
      case TargetPlatform.fuchsia:
        return null;
    }
  }

  static Widget wrapWithSocialFont(BuildContext context, Widget child) => child;

  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      fontFamily: appFontFamily,
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.macOS: _FadePageTransitionsBuilder(),
          TargetPlatform.windows: _FadePageTransitionsBuilder(),
          TargetPlatform.linux: _FadePageTransitionsBuilder(),
          TargetPlatform.iOS: _FadePageTransitionsBuilder(),
          TargetPlatform.android: _FadePageTransitionsBuilder(),
        },
      ),
      colorScheme: ColorScheme.light(
        primary: brandColor,
        secondary: const Color(0xFF34C759),
        surface: backgroundColor,
        surfaceContainerHighest: mutedSurfaceColor,
      ),
      scaffoldBackgroundColor: backgroundColor,
      canvasColor: backgroundColor, // 使用背景色作为画布色，确保下拉框不透明
      cardColor: subtleSurfaceColor,
      popupMenuTheme: PopupMenuThemeData(color: subtleSurfaceColor),
      menuTheme: MenuThemeData(
        style: MenuStyle(backgroundColor: WidgetStatePropertyAll(subtleSurfaceColor)),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: surfaceColor,
        foregroundColor: headingColor,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: headingColor,
        ),
      ),
      dividerTheme: DividerThemeData(
        color: borderColor,
        thickness: 0.5,
        space: 0.5,
      ),
      inputDecorationTheme: const InputDecorationTheme(
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
      textTheme: TextTheme(
        titleLarge: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: headingColor,
          letterSpacing: -0.4,
        ),
        titleMedium: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w500,
          color: headingColor,
          letterSpacing: -0.2,
        ),
        bodyLarge: TextStyle(
          fontSize: 15,
          color: headingColor,
          letterSpacing: -0.2,
        ),
        bodyMedium: TextStyle(fontSize: 13, color: bodyColor),
        bodySmall: TextStyle(fontSize: 12, color: subtleTextColor),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surfaceColor, // 使用实色
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shadowColor: Colors.black.withValues(alpha: 0.14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: borderColor.withValues(alpha: 0.85), width: 0.8),
        ),
        titleTextStyle: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          color: headingColor,
        ),
        contentTextStyle: TextStyle(
          fontSize: 13,
          color: bodyColor,
          height: 1.45,
        ),
        actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        insetPadding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        backgroundColor: const Color(0xFF404E5F), // 使用实色
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: Colors.white.withValues(alpha: 0.16),
            width: 0.8,
          ),
        ),
        contentTextStyle: const TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
        actionTextColor: const Color(0xFFD6E8FF),
      ),
    );
  }

  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      fontFamily: appFontFamily,
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.macOS: _FadePageTransitionsBuilder(),
          TargetPlatform.windows: _FadePageTransitionsBuilder(),
          TargetPlatform.linux: _FadePageTransitionsBuilder(),
          TargetPlatform.iOS: _FadePageTransitionsBuilder(),
          TargetPlatform.android: _FadePageTransitionsBuilder(),
        },
      ),
      colorScheme: ColorScheme.dark(
        primary: brandColor,
        secondary: const Color(0xFF34C759),
        surface: const Color(0xFF1C1C1E),
      ),
    );
  }
}
