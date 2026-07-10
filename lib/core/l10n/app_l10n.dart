import 'dart:ui';

import 'package:termora/core/l10n/app_l10n_en.dart';

enum AppLocale { system, zh, en }

/// 功能页海量字符串的查表翻译:以中文原文为 key,英文缺失时回落中文。
/// 顶层短名方便调用:`tr('删除')`。
String tr(String zh) => AppL10n.tr(zh);

/// 带占位的模板翻译:`tr2('删除 {0} 项', [count])`
String tr2(String zh, List<Object?> args) => AppL10n.tr2(zh, args);

class AppL10n {
  const AppL10n._({required this.isZh});

  final bool isZh;

  /// 全局当前语言(与 AppTheme 同风格的静态入口)。
  /// 由 AppLocaleController / MainShell 在语言变化时同步;
  /// 默认中文,保证未经外壳初始化的测试环境行为稳定。
  static AppL10n current = const AppL10n._(isZh: true);

  /// 查表翻译:中文直出,英文查 [kAppL10nEn],缺失回落中文
  static String tr(String zh) => current.isZh ? zh : (kAppL10nEn[zh] ?? zh);

  /// 模板翻译:先查表再替换 {0}/{1}… 占位
  static String tr2(String zh, List<Object?> args) {
    var text = tr(zh);
    for (var i = 0; i < args.length; i++) {
      text = text.replaceAll('{$i}', '${args[i]}');
    }
    return text;
  }

  static AppL10n resolve(AppLocale locale) {
    if (locale == AppLocale.zh) {
      return const AppL10n._(isZh: true);
    } else if (locale == AppLocale.en) {
      return const AppL10n._(isZh: false);
    } else {
      final code = PlatformDispatcher.instance.locale.languageCode
          .toLowerCase();
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
  String get screenshotShortcut =>
      isZh ? '截屏 (⌥+Shift+X)' : 'Screenshot (⌥+Shift+X)';
  String get alwaysOnTop => isZh ? '窗口置顶' : 'Always on Top';
  String get quit => isZh ? '退出' : 'Quit';

  // About Section
  String get aboutTermora => isZh ? '关于 Termora' : 'About Termora';
  String get versionLabel => isZh ? '当前版本' : 'Version';
  String get openSourceRepo => isZh ? 'GitHub 开源主页' : 'GitHub Repository';
  String get aboutTagline => isZh
      ? '跨平台全能桌面级开发工具箱 (SSH / 数据库 / 笔记 / 截屏)'
      : 'Modern Cross-Platform Desktop Developer Toolbox';

  // App updates
  String get softwareUpdate => isZh ? '软件更新' : 'Software Update';
  String get checkForUpdates => isZh ? '检查更新' : 'Check for Updates';
  String get checkingForUpdates =>
      isZh ? '正在检查更新...' : 'Checking for updates...';
  String get upToDate => isZh ? '已是最新版本' : 'You are up to date';
  String updateAvailable(String version) =>
      isZh ? '发现新版本 $version' : 'Version $version is available';
  String get updateNow => isZh ? '立即更新' : 'Update Now';
  String downloadingUpdate(int percent) =>
      isZh ? '正在下载更新... $percent%' : 'Downloading update... $percent%';
  String get installingUpdate =>
      isZh ? '正在安装更新并重启...' : 'Installing update and restarting...';
  String get manualInstallOpened => isZh
      ? '安装包已打开，请拖入 Applications 完成升级'
      : 'Installer opened. Drag it into Applications to finish updating.';
  String get updateFailed =>
      isZh ? '更新失败，请重试' : 'Update failed. Please try again.';
  String get viewRelease => isZh ? '查看发布页' : 'View Release';
}
