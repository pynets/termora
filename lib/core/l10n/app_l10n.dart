import 'dart:ui';

enum AppLocale {
  system,
  zh,
  en,
}

class AppL10n {
  const AppL10n._({required this.isZh});

  final bool isZh;

  static AppL10n resolve(AppLocale locale) {
    if (locale == AppLocale.zh) {
      return const AppL10n._(isZh: true);
    } else if (locale == AppLocale.en) {
      return const AppL10n._(isZh: false);
    } else {
      final code = PlatformDispatcher.instance.locale.languageCode.toLowerCase();
      final isZh = code == 'zh';
      return AppL10n._(isZh: isZh);
    }
  }

  // Navigation Rail
  String get terminal => isZh ? '终端' : 'Terminal';
  String get remote => isZh ? '远程' : 'Remote';
  String get database => isZh ? '数据库' : 'Database';
  String get notes => isZh ? '笔记' : 'Notes';
  String get settings => isZh ? '设置' : 'Settings';

  // Settings Dialog
  String get close => isZh ? '关闭' : 'Close';
  String get language => isZh ? '语言 / Language' : 'Language / 语言';
  String get followSystem => isZh ? '跟随系统' : 'System';
  String get chinese => '简体中文';
  String get english => 'English';

  String get theme => isZh ? '主题' : 'Theme';
  String get lightTheme => isZh ? '浅色' : 'Light';
  String get darkTheme => isZh ? '深色' : 'Dark';

  String get brandColor => isZh ? '品牌主色' : 'Brand Color';
  String get brandColorDesc => isZh
      ? '与 superdesk 同一套配色,颜色跟随明暗模式自动适配'
      : 'Consistent color palette across light and dark modes';

  // Tray Menu
  String get showWindow => isZh ? '显示窗口' : 'Show Window';
  String get screenshotShortcut => isZh ? '截屏 (⌥+Shift+X)' : 'Screenshot (⌥+Shift+X)';
  String get alwaysOnTop => isZh ? '窗口置顶' : 'Always on Top';
  String get launchAtStartup => isZh ? '开机自启动' : 'Launch at Startup';
  String get quit => isZh ? '退出' : 'Quit';
}
