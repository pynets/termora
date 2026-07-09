import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:termora/app/theme/app_theme.dart';
import 'package:termora/core/l10n/app_l10n.dart';

export 'package:termora/core/l10n/app_l10n.dart';

// ----------------------------------------------------------------------
// 设置 Providers(SharedPreferences 持久化)
// ----------------------------------------------------------------------

/// 界面语言(跟随系统/简体中文/English)
class AppLocaleController extends Notifier<AppLocale> {
  static const _key = 'app_locale_mode';

  @override
  AppLocale build() {
    _load();
    return AppLocale.system;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_key);
    if (value != null) {
      state = AppLocale.values.firstWhere(
        (mode) => mode.name == value,
        orElse: () => AppLocale.system,
      );
    }
  }

  void setLocale(AppLocale locale) async {
    state = locale;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, locale.name);
  }
}

final appLocaleControllerProvider =
    NotifierProvider<AppLocaleController, AppLocale>(AppLocaleController.new);

/// 主题模式(跟随系统/浅色/深色)
class AppThemeController extends Notifier<ThemeMode> {
  static const _key = 'app_theme_mode';

  @override
  ThemeMode build() {
    _load();
    return ThemeMode.system;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_key);
    if (value != null) {
      state = ThemeMode.values.firstWhere(
        (mode) => mode.name == value,
        orElse: () => ThemeMode.system,
      );
    }
  }

  void setThemeMode(ThemeMode mode) async {
    state = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, mode.name);
  }
}

final appThemeControllerProvider =
    NotifierProvider<AppThemeController, ThemeMode>(AppThemeController.new);

/// 品牌主色
class AppBrandColorController extends Notifier<AppBrandColor> {
  static const _key = 'app_brand_color';

  @override
  AppBrandColor build() {
    _load();
    return AppBrandColor.teal;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_key);
    if (value != null) {
      state = AppBrandColor.values.firstWhere(
        (color) => color.name == value,
        orElse: () => AppBrandColor.teal,
      );
    }
  }

  void setColor(AppBrandColor color) async {
    state = color;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, color.name);
  }
}

final appBrandColorControllerProvider =
    NotifierProvider<AppBrandColorController, AppBrandColor>(
      AppBrandColorController.new,
    );
