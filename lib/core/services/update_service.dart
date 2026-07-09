import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:termora/core/app_version.dart';

/// 一次可用的升级:GitHub Release 的版本与 dmg 资产。
class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.tagName,
    required this.htmlUrl,
    this.dmgUrl,
    this.dmgName,
    this.sizeBytes = 0,
  });

  /// 纯版本号(去掉 v 前缀),如 0.0.3
  final String version;
  final String tagName;

  /// Release 页面(资产缺失时回退用)
  final String htmlUrl;
  final String? dmgUrl;
  final String? dmgName;
  final int sizeBytes;

  String get sizeLabel {
    if (sizeBytes <= 0) return '';
    final mb = sizeBytes / (1024 * 1024);
    return '${mb.toStringAsFixed(1)} MB';
  }
}

/// GitHub Release 升级:检测 → 应用内下载 → 挂载 dmg 替换 .app → 重启。
/// 所有步骤失败都不致命 —— 检测失败静默跳过,安装失败回退为打开 dmg 手装。
class UpdateService {
  UpdateService._();

  static const _repo = 'pynets/termora';

  /// 查最新 Release;没有新版(或网络失败/超时)返回 null。
  static Future<UpdateInfo?> checkForUpdate({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    try {
      final resp = await http
          .get(
            Uri.parse('https://api.github.com/repos/$_repo/releases/latest'),
            headers: const {
              'Accept': 'application/vnd.github+json',
              'User-Agent': 'termora-updater',
            },
          )
          .timeout(timeout);
      if (resp.statusCode != 200) return null;
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      final tag = (json['tag_name'] as String? ?? '').trim();
      if (tag.isEmpty) return null;
      final version = tag.startsWith('v') ? tag.substring(1) : tag;
      if (compareVersions(version, kAppVersion) <= 0) return null;

      String? dmgUrl;
      String? dmgName;
      var size = 0;
      final assets = json['assets'] as List<dynamic>? ?? const [];
      for (final a in assets) {
        final asset = a as Map<String, dynamic>;
        final name = asset['name'] as String? ?? '';
        if (name.toLowerCase().endsWith('.dmg')) {
          dmgUrl = asset['browser_download_url'] as String?;
          dmgName = name;
          size = (asset['size'] as num?)?.toInt() ?? 0;
          break;
        }
      }
      return UpdateInfo(
        version: version,
        tagName: tag,
        htmlUrl:
            json['html_url'] as String? ??
            'https://github.com/$_repo/releases',
        dmgUrl: dmgUrl,
        dmgName: dmgName,
        sizeBytes: size,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('检查更新失败(忽略): $e');
      return null;
    }
  }

  /// 比较点分版本号:>0 表示 a 新于 b。非数字段按 0 处理。
  static int compareVersions(String a, String b) {
    final pa = a.split('.');
    final pb = b.split('.');
    final n = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < n; i++) {
      final va = i < pa.length
          ? int.tryParse(pa[i].replaceAll(RegExp(r'\D.*$'), '')) ?? 0
          : 0;
      final vb = i < pb.length
          ? int.tryParse(pb[i].replaceAll(RegExp(r'\D.*$'), '')) ?? 0
          : 0;
      if (va != vb) return va - vb;
    }
    return 0;
  }

  /// 流式下载 dmg 到临时目录,进度回调 0..1。
  static Future<File> downloadDmg(
    UpdateInfo info,
    void Function(double progress) onProgress,
  ) async {
    final url = info.dmgUrl;
    if (url == null) throw Exception('该版本没有 dmg 资产');
    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(url));
      request.headers['User-Agent'] = 'termora-updater';
      final resp = await client.send(request);
      if (resp.statusCode != 200) {
        throw Exception('下载失败 HTTP ${resp.statusCode}');
      }
      final total = resp.contentLength ?? info.sizeBytes;
      final file = File(
        '${Directory.systemTemp.path}/${info.dmgName ?? 'termora-update.dmg'}',
      );
      final sink = file.openWrite();
      var received = 0;
      try {
        await for (final chunk in resp.stream) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) onProgress((received / total).clamp(0.0, 1.0));
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      return file;
    } finally {
      client.close();
    }
  }

  /// 挂载 dmg → 用其中的 .app 替换当前应用 → 重启。成功时进程直接退出
  /// (不返回);失败返回 false,调用方回退为打开 dmg 手动安装。
  static Future<bool> installAndRelaunch(File dmg) async {
    if (!Platform.isMacOS) return false;
    String? mountPoint;
    try {
      // 1. 静默挂载
      final attach = await Process.run('hdiutil', [
        'attach',
        '-nobrowse',
        '-readonly',
        dmg.path,
      ]);
      if (attach.exitCode != 0) return false;
      final out = attach.stdout.toString();
      final m = RegExp(r'(/Volumes/[^\n]+)').firstMatch(out);
      mountPoint = m?.group(1)?.trim();
      if (mountPoint == null) return false;

      // 2. 找到镜像里的 .app
      final apps = Directory(mountPoint)
          .listSync()
          .whereType<Directory>()
          .where((d) => d.path.endsWith('.app'))
          .toList();
      if (apps.isEmpty) return false;
      final newApp = apps.first.path;

      // 3. 定位当前 .app 包路径(…/Termora.app/Contents/MacOS/termora)
      final exe = Platform.resolvedExecutable;
      final marker = exe.indexOf('.app/Contents/MacOS/');
      if (marker < 0) return false; // 非打包运行(flutter run),不自动替换
      final targetApp = exe.substring(0, marker + 4);
      final targetDir = File(targetApp).parent.path;
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final staging = '$targetDir/.termora-update-$stamp.app';
      final backup = '$targetDir/.termora-old-$stamp.app';

      // 4. 复制到同卷暂存 → 原子换名(旧包先挪开;运行中的进程照常存活)
      final copy = await Process.run('ditto', [newApp, staging]);
      if (copy.exitCode != 0) return false;
      final mvOld = await Process.run('mv', [targetApp, backup]);
      if (mvOld.exitCode != 0) {
        await Process.run('rm', ['-rf', staging]);
        return false;
      }
      final mvNew = await Process.run('mv', [staging, targetApp]);
      if (mvNew.exitCode != 0) {
        // 回滚
        await Process.run('mv', [backup, targetApp]);
        await Process.run('rm', ['-rf', staging]);
        return false;
      }
      unawaited(Process.run('rm', ['-rf', backup]));

      // 5. 卸载镜像并重启新版本
      await Process.run('hdiutil', ['detach', mountPoint, '-quiet']);
      mountPoint = null;
      await Process.start('open', ['-n', targetApp]);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      exit(0);
    } catch (e) {
      if (kDebugMode) debugPrint('自动安装失败: $e');
      return false;
    } finally {
      if (mountPoint != null) {
        unawaited(
          Process.run('hdiutil', ['detach', mountPoint, '-quiet']),
        );
      }
    }
  }

  /// 回退:用系统方式打开 dmg(用户手动拖入 Applications)。
  static Future<void> openDmg(File dmg) async {
    if (Platform.isMacOS) {
      await Process.run('open', [dmg.path]);
    }
  }
}
