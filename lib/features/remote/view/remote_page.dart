import 'dart:async';
import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:toastification/toastification.dart';

import 'package:termora/app/theme/app_theme.dart';
import 'package:termora/core/widgets/app_toast.dart';
import 'package:termora/features/remote/controller/remote_providers.dart';
import 'package:termora/features/remote/data/host_store.dart';
import 'package:termora/features/remote/data/sftp_service.dart';
import 'package:termora/features/remote/domain/ssh_host.dart';
import 'package:termora/features/remote/view/widgets/host_dialog.dart';
import 'package:termora/features/remote/view/widgets/sftp_browser.dart';
import 'package:termora/features/remote/view/widgets/transfer_log_dialog.dart';
import 'package:termora/features/remote/view/widgets/tunnel_manager.dart';
import 'package:termora/features/terminal/view/terminal_page.dart';
import 'package:termora/core/l10n/app_l10n.dart';

/// 远程主机页 — WindTerm 式布局:
/// 左侧保存的主机列表,右侧独立的 SSH 终端工作区(与「终端」页完全分离,
/// 各自的会话、持久化与分屏布局互不可见;终端引擎在底层复用)。
class RemotePage extends ConsumerStatefulWidget {
  const RemotePage({super.key});

  @override
  ConsumerState<RemotePage> createState() => _RemotePageState();
}

class _RemotePageState extends ConsumerState<RemotePage> {
  final TerminalWorkspaceController _workspace = TerminalWorkspaceController();

  /// 正在浏览文件的主机(null = 右侧显示 SSH 终端工作区)
  SshHost? _sftpHost;

  /// 打开 SFTP 时 SSH 会话所在的远端目录(拿不到为 null,浏览器回落家目录)
  String? _sftpInitialPath;

  /// 右侧主机列表侧栏是否展开(默认收起以节约空间)
  bool _sidebarOpen = false;

  /// 主机搜索关键字(按名称/主机/用户/分组过滤)
  final TextEditingController _hostSearch = TextEditingController();
  String _hostQuery = '';

  /// 已折叠的分组名(会话管理器文件夹的收起状态,仅内存)
  final Set<String> _collapsedGroups = {};

  /// 未分组的展示名(内部用空串作 key)
  static const _ungrouped = '未分组';

  @override
  void dispose() {
    _hostSearch.dispose();
    super.dispose();
  }

  Future<void> _connect(SshHost host) async {
    // socket 目录先备好,ControlMaster 才能生效;私钥非 0600 会被 ssh
    // 整个忽略,连接前顺手收紧(都是 best-effort,失败不拦连接)
    await SshHostStore.ensureControlDirectory();
    await SshHostStore.tightenKeyPermissions(host.keyPath);
    if (!mounted) return;
    // 会话要能被看到:收起文件面板，并自动收缩主机列表腾出终端空间
    setState(() {
      _sftpHost = null;
      _sidebarOpen = false;
    });
    _workspace.openRemoteSession(
      title: host.name,
      command: host.sshCommand(),
      remoteKey: host.id,
    );
  }

  /// 会话工具栏「文件(SFTP)」入口:按主机 id 找回主机再走常规打开流程
  void _openSftpByHostId(String hostId) {
    for (final host in ref.read(sshHostsProvider)) {
      if (host.id == hostId) {
        unawaited(_openSftp(host));
        return;
      }
    }
  }

  SshHost? _hostById(String hostId) {
    for (final host in ref.read(sshHostsProvider)) {
      if (host.id == hostId) return host;
    }
    return null;
  }

  // ── 详情面板文件区的提权(按主机;密码只在内存)──
  // su=true 用 root 密码,false 用当前用户 sudo 密码
  final Map<String, ({String password, bool su})> _elevation = {};

  bool _isHostElevated(String hostId) => _elevation.containsKey(hostId);

  /// 弹提权框 → 校验 → 记住;成功返回 true(详情面板文件区调用)
  Future<bool> _elevateHost(String hostId) async {
    final host = _hostById(hostId);
    if (host == null) return false;
    final choice = await _promptElevation();
    if (choice == null || choice.password.isEmpty || !mounted) return false;
    try {
      if (choice.su) {
        await SuFileService.verify(host, choice.password);
      } else {
        await SudoFileService.verify(host, choice.password);
      }
      if (!mounted) return false;
      setState(
        () => _elevation[hostId] = (password: choice.password, su: choice.su),
      );
      _toast(tr('已提权(root),现在以 root 浏览/下载'), ToastificationType.success);
      return true;
    } on SftpException catch (e) {
      _toast(tr2('提权失败:{0}', [e.message]), ToastificationType.error);
      return false;
    }
  }

  void _dropHostElevation(String hostId) {
    setState(() => _elevation.remove(hostId));
  }

  void _toast(String message, ToastificationType type) {
    if (!mounted) return;
    AppToast.show(
      context: context,
      style: ToastificationStyle.flat,
      applyBlurEffect: true,
      type: type,
      autoCloseDuration: const Duration(seconds: 3),
      title: Text(
        message,
        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w400),
      ),
    );
  }

  Future<({bool su, String password})?> _promptElevation() {
    var su = false;
    final controller = TextEditingController();
    return showDialog<({bool su, String password})>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          title: Text(
            tr('提权访问'),
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppTheme.headingColor,
            ),
          ),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildElevationTabs(su, (val) => setLocal(() => su = val)),
                const SizedBox(height: 14),
                TextField(
                  controller: controller,
                  autofocus: true,
                  obscureText: true,
                  style: TextStyle(fontSize: 13, color: AppTheme.headingColor),
                  decoration: InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                    hintText: su ? tr('root 用户密码') : tr('当前用户的 sudo 密码'),
                    hintStyle: TextStyle(
                      fontSize: 12,
                      color: AppTheme.subtleTextColor.withValues(alpha: 0.7),
                    ),
                  ),
                  onSubmitted: (v) =>
                      Navigator.of(context).pop((su: su, password: v)),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 36,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      su
                          ? tr('su : 登录用户不是 sudoer 时使用 root 密码切换(当前支持浏览与下载)')
                          : tr('sudo : 使用当前登录用户密码提权'),
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 1.4,
                        color: AppTheme.subtleTextColor,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(tr('取消')),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.brandColor,
              ),
              onPressed: () => Navigator.of(context)
                  .pop((su: su, password: controller.text)),
              child: Text(tr('提权')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildElevationTabs(bool currentSu, ValueChanged<bool> onChanged) {
    return Container(
      height: 34,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppTheme.mutedSurfaceColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Row(
        children: [
          Expanded(
            child: _buildElevationTabItem(
              title: tr('sudo (推荐)'),
              selected: !currentSu,
              icon: LucideIcons.shieldCheck300,
              onTap: () => onChanged(false),
            ),
          ),
          Expanded(
            child: _buildElevationTabItem(
              title: 'su (root)',
              selected: currentSu,
              icon: LucideIcons.shieldAlert300,
              onTap: () => onChanged(true),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildElevationTabItem({
    required String title,
    required bool selected,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? AppTheme.surfaceColor : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 4,
                    offset: const Offset(0, 1),
                  ),
                ]
              : null,
          border: selected
              ? Border.all(
                  color: AppTheme.brandColor.withValues(alpha: 0.35),
                  width: 1,
                )
              : Border.all(color: Colors.transparent),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 13,
              color: selected ? AppTheme.brandColor : AppTheme.subtleTextColor,
            ),
            const SizedBox(width: 6),
            Text(
              title,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color:
                    selected ? AppTheme.headingColor : AppTheme.subtleTextColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// ~ / 空路径解析到远端家目录
  Future<String> _resolveRemoteDir(SshHost host, String path) async {
    if (path.isEmpty || path == '~') return SftpService.homeDirectory(host);
    if (path.startsWith('~/')) {
      final home = await SftpService.homeDirectory(host);
      return home == '/' ? '/${path.substring(2)}' : '$home/${path.substring(2)}';
    }
    return path;
  }

  String _joinRemote(String dir, String name) =>
      dir == '/' ? '/$name' : '$dir/$name';

  /// 详情面板「文件」标签的远端目录列举器:复用该主机已认证的 SFTP 连接。
  /// path 为空(或 ~)时解析到远端家目录。
  Future<List<TerminalDirEntry>> _listRemoteDir(
    String hostId,
    String path,
  ) async {
    final host = _hostById(hostId);
    if (host == null) return const [];
    final dir = await _resolveRemoteDir(host, path);
    final elev = _elevation[hostId];
    final entries = elev == null
        ? await SftpService.list(host, dir)
        : elev.su
        ? await SuFileService.list(host, elev.password, dir)
        : await SudoFileService.list(host, elev.password, dir);
    return [
      for (final e in entries)
        TerminalDirEntry(
          path: _joinRemote(dir, e.name),
          name: e.name,
          isDir: e.isDir,
          size: e.size,
          modified: e.modified,
        ),
    ];
  }

  /// 远端文件增改删(详情面板「文件」标签用),按提权分派
  late final TerminalRemoteFileActions _remoteFileActions =
      TerminalRemoteFileActions(
        rename: (hostId, path, newName) async {
          final host = _hostById(hostId);
          if (host == null) return;
          final slash = path.lastIndexOf('/');
          final dir = slash <= 0 ? '/' : path.substring(0, slash);
          final to = _joinRemote(dir, newName);
          final elev = _elevation[hostId];
          if (elev == null) {
            await SftpService.rename(host, path, to);
          } else if (elev.su) {
            await SuFileService.rename(host, elev.password, path, to);
          } else {
            await SudoFileService.rename(host, elev.password, path, to);
          }
        },
        delete: (hostId, path, isDir) async {
          final host = _hostById(hostId);
          if (host == null) return;
          final elev = _elevation[hostId];
          if (elev != null) {
            if (elev.su) {
              await SuFileService.remove(host, elev.password, path, isDir);
            } else if (isDir) {
              await SudoFileService.removeDir(host, elev.password, path);
            } else {
              await SudoFileService.remove(host, elev.password, path);
            }
          } else if (isDir) {
            await SftpService.removeDir(host, path);
          } else {
            await SftpService.remove(host, path);
          }
        },
        makeDir: (hostId, parentDir, name) async {
          final host = _hostById(hostId);
          if (host == null) return;
          final dir = await _resolveRemoteDir(host, parentDir);
          final full = _joinRemote(dir, name);
          final elev = _elevation[hostId];
          if (elev == null) {
            await SftpService.makeDir(host, full);
          } else if (elev.su) {
            await SuFileService.makeDir(host, elev.password, full);
          } else {
            await SudoFileService.makeDir(host, elev.password, full);
          }
        },
      );

  /// 上传本地文件到远端目录,返回 0..1 进度流(轮询远端文件大小)
  Stream<double> _uploadToRemote(
    String hostId,
    String localPath,
    String remoteDir,
  ) {
    SftpTransferHandle? handle;
    final controller = StreamController<double>(
      onCancel: () => handle?.cancel(),
    );
    Future<void> run() async {
      final host = _hostById(hostId);
      if (host == null) {
        controller.addError(tr('主机不存在'));
        return;
      }
      final dir = await _resolveRemoteDir(host, remoteDir);
      final name = localPath.split('/').last;
      final remoteFile = _joinRemote(dir, name);
      int? total;
      try {
        total = await File(localPath).length();
      } catch (_) {}
      final elev = _elevation[hostId];
      if (elev != null && elev.su) {
        controller.addError(tr('su 提权暂不支持上传,请以 root 登录或用 sudo'));
        return;
      }
      handle = elev != null
          ? await SudoFileService.startUploadFile(
              host,
              elev.password,
              localPath,
              remoteFile,
            )
          : await SftpService.startUpload(host, localPath, dir);
      Timer? poll;
      if (total != null && total > 0) {
        poll = Timer.periodic(const Duration(milliseconds: 800), (_) async {
          final size = await SftpService.fileSize(host, remoteFile);
          if (size != null && !controller.isClosed) {
            controller.add((size / total!).clamp(0.0, 1.0));
          }
        });
      }
      try {
        await handle!.done;
      } finally {
        poll?.cancel();
      }
    }

    run()
        .then((_) {
          if (!controller.isClosed) controller.add(1);
        })
        .catchError((Object e) {
          if (!controller.isClosed) controller.addError(e);
        })
        .whenComplete(() {
          if (!controller.isClosed) controller.close();
        });
    return controller.stream;
  }

  /// 下载远端文件/目录到本地,返回 0..1 进度流(文件轮询本地大小;目录不定进度)
  Stream<double> _downloadFromRemote(
    String hostId,
    String remotePath,
    String localPath,
    bool isDir,
  ) {
    SftpTransferHandle? handle;
    final controller = StreamController<double>(
      onCancel: () => handle?.cancel(),
    );
    Future<void> run() async {
      final host = _hostById(hostId);
      if (host == null) {
        controller.addError(tr('主机不存在'));
        return;
      }
      final elev = _elevation[hostId];
      if (elev == null) {
        handle = await SftpService.startDownload(
          host,
          remotePath,
          localPath,
          recursive: isDir,
        );
      } else if (elev.su) {
        handle = isDir
            ? await SuFileService.startDownloadDir(
                host,
                elev.password,
                remotePath,
                localPath,
              )
            : await SuFileService.startDownloadFile(
                host,
                elev.password,
                remotePath,
                localPath,
              );
      } else {
        handle = isDir
            ? await SudoFileService.startDownloadDir(
                host,
                elev.password,
                remotePath,
                localPath,
              )
            : await SudoFileService.startDownloadFile(
                host,
                elev.password,
                remotePath,
                localPath,
              );
      }
      Timer? poll;
      if (!isDir && elev == null) {
        final total = await SftpService.fileSize(host, remotePath);
        if (total != null && total > 0) {
          poll = Timer.periodic(const Duration(milliseconds: 400), (_) async {
            try {
              final size = await File(localPath).length();
              if (!controller.isClosed) {
                controller.add((size / total).clamp(0.0, 1.0));
              }
            } catch (_) {}
          });
        }
      }
      try {
        await handle!.done;
      } finally {
        poll?.cancel();
      }
    }

    run()
        .then((_) {
          if (!controller.isClosed) controller.add(1);
        })
        .catchError((Object e) {
          if (!controller.isClosed) controller.addError(e);
        })
        .whenComplete(() {
          if (!controller.isClosed) controller.close();
        });
    return controller.stream;
  }

  /// 上传整个本地目录(递归)到远端目录;进度不定,完成时置 1
  Stream<double> _uploadDirToRemote(
    String hostId,
    String localDir,
    String remoteDir,
  ) {
    SftpTransferHandle? handle;
    final controller = StreamController<double>(
      onCancel: () => handle?.cancel(),
    );
    Future<void> run() async {
      final host = _hostById(hostId);
      if (host == null) {
        controller.addError(tr('主机不存在'));
        return;
      }
      final dir = await _resolveRemoteDir(host, remoteDir);
      final elev = _elevation[hostId];
      if (elev != null && elev.su) {
        controller.addError(tr('su 提权暂不支持上传,请以 root 登录或用 sudo'));
        return;
      }
      handle = elev != null
          ? await SudoFileService.startUploadDir(host, elev.password, localDir, dir)
          : await SftpService.startUploadDir(host, localDir, dir);
      await handle!.done;
    }

    run()
        .then((_) {
          if (!controller.isClosed) controller.add(1);
        })
        .catchError((Object e) {
          if (!controller.isClosed) controller.addError(e);
        })
        .whenComplete(() {
          if (!controller.isClosed) controller.close();
        });
    return controller.stream;
  }

  /// 在远端目录跑 git(经 ssh 复用 ControlMaster,免再认证)
  Future<ProcessResult?> _runRemoteGit(
    String hostId,
    String remoteDir,
    List<String> args,
  ) async {
    final host = _hostById(hostId);
    if (host == null) return null;
    final dir = await _resolveRemoteDir(host, remoteDir);
    final quotedDir = dir.replaceAll("'", "'\\''");
    final command = "git -C '$quotedDir' ${args.join(' ')}";
    try {
      return await Process.run('/usr/bin/ssh', [
        '-o', 'ControlMaster=auto',
        '-o', 'ControlPath=~/.termora/cm-%C',
        '-o', 'ControlPersist=10m',
        '-o', 'BatchMode=yes',
        if (host.port != 22) ...['-p', '${host.port}'],
        if (host.keyPath.isNotEmpty) ...['-i', host.keyPath],
        host.target,
        command,
      ]);
    } catch (_) {
      return null;
    }
  }

  Future<void> _openSftp(SshHost host) async {
    await SshHostStore.ensureControlDirectory();
    await SshHostStore.tightenKeyPermissions(host.keyPath);
    if (!mounted) return;
    setState(() {
      // SSH 会话在哪个目录,SFTP 就开在哪个目录
      _sftpInitialPath = _workspace.remoteCwdFor(host.id);
      _sftpHost = host;
      _sidebarOpen = false;
    });
  }

  /// 当前所有非空分组名(去重、按拼音/字典序),供分组选择器用
  List<String> _allGroups() {
    final set = <String>{};
    for (final h in ref.read(sshHostsProvider)) {
      if (h.group.trim().isNotEmpty) set.add(h.group.trim());
    }
    final list = set.toList()..sort();
    return list;
  }

  Future<void> _addHost() async {
    final host = await showSshHostDialog(context, groups: _allGroups());
    if (host == null || !mounted) return;
    await ref.read(sshHostsProvider.notifier).upsert(host);
  }

  /// 传输记录查看页(跨全部主机的 SFTP 历史)
  void _showTransferLog() {
    final names = {
      for (final h in ref.read(sshHostsProvider)) h.id: h.name,
    };
    unawaited(
      showDialog<void>(
        context: context,
        builder: (context) => TransferLogDialog(hostNames: names),
      ),
    );
  }

  Future<void> _editHost(SshHost host) async {
    final updated = await showSshHostDialog(
      context,
      existing: host,
      groups: _allGroups(),
    );
    if (updated == null || !mounted) return;
    await ref.read(sshHostsProvider.notifier).upsert(updated);
  }

  /// 单行文本输入弹窗(新建分组名等)。
  Future<String?> _promptText(String title, {String hint = ''}) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(fontSize: 13, color: AppTheme.headingColor),
          decoration: InputDecoration(
            hintText: hint,
            isDense: true,
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.of(context).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(tr('取消')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.brandColor),
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: Text(tr('确定')),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  /// 快速把主机移动到某分组(空串=移出分组)。
  Future<void> _setHostGroup(SshHost host, String group) async {
    if (host.group == group) return;
    await ref.read(sshHostsProvider.notifier).upsert(host.copyWith(group: group));
  }

  /// 右键菜单里选「移动到分组」:列出已有分组 + 新建 + 移出。
  Future<void> _pickGroupForHost(SshHost host, Offset globalPos) async {
    final groups = _allGroups();
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    const newTag = ' new';
    const clearTag = ' clear';
    final chosen = await showMenu<String>(
      context: context,
      color: AppTheme.surfaceColor,
      position: RelativeRect.fromRect(
        globalPos & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: [
        for (final g in groups)
          PopupMenuItem(
            value: g,
            child: Row(
              children: [
                Icon(
                  host.group == g
                      ? LucideIcons.check300
                      : LucideIcons.folder300,
                  size: 14,
                  color: host.group == g
                      ? AppTheme.brandColor
                      : AppTheme.subtleTextColor,
                ),
                const SizedBox(width: 8),
                Text(g, style: const TextStyle(fontSize: 12.5)),
              ],
            ),
          ),
        if (groups.isNotEmpty) const PopupMenuDivider(),
        const PopupMenuItem(
          value: newTag,
          child: Text('新建分组…', style: TextStyle(fontSize: 12.5)),
        ),
        if (host.group.isNotEmpty)
          const PopupMenuItem(
            value: clearTag,
            child: Text('移出分组', style: TextStyle(fontSize: 12.5)),
          ),
      ],
    );
    if (chosen == null || !mounted) return;
    if (chosen == clearTag) {
      await _setHostGroup(host, '');
    } else if (chosen == newTag) {
      final name = await _promptText(tr('新建分组'), hint: tr('分组名'));
      if (name != null && name.trim().isNotEmpty) {
        await _setHostGroup(host, name.trim());
      }
    } else {
      await _setHostGroup(host, chosen);
    }
  }

  Future<void> _removeHost(SshHost host) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('删除主机')),
        content: Text(tr2('确定删除「{0}」吗?', [host.name])),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(tr('取消')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.errorColor),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(tr('删除')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref.read(sshHostsProvider.notifier).remove(host.id);
  }

  @override
  Widget build(BuildContext context) {
    final hosts = ref.watch(sshHostsProvider);
    return Scaffold(
      backgroundColor: AppTheme.backgroundColor,
      body: Stack(
        children: [
          // 底层:终端工作区 + 永远可见的收起竖条(终端只让出竖条宽度)
          Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Offstage(
                      offstage: _sftpHost != null,
                      child: TerminalPage.remoteWorkspace(
                        controller: _workspace,
                        onOpenRemoteFiles: _openSftpByHostId,
                        listRemoteDir: _listRemoteDir,
                        uploadToRemote: _uploadToRemote,
                        uploadDirToRemote: _uploadDirToRemote,
                        downloadFromRemote: _downloadFromRemote,
                        remoteFileActions: _remoteFileActions,
                        runRemoteGit: _runRemoteGit,
                        isRemoteElevated: _isHostElevated,
                        elevateRemote: _elevateHost,
                        dropRemoteElevation: _dropHostElevation,
                      ),
                    ),
                    if (_sftpHost != null)
                      SftpBrowser(
                        key: ValueKey('sftp_${_sftpHost!.id}'),
                        host: _sftpHost!,
                        initialPath: _sftpInitialPath,
                        onClose: () => setState(() => _sftpHost = null),
                      ),
                  ],
                ),
              ),
              VerticalDivider(width: 0.5, color: AppTheme.borderColor),
              SizedBox(
                width: _railWidth,
                child: _buildCollapsedSidebar(hosts),
              ),
            ],
          ),
          // 上层:点击竖条外区域关闭的遮罩 + 从右侧浮出的主机面板
          _buildFloatingSidebar(hosts),
        ],
      ),
    );
  }

  static const double _sidebarWidth = 288;
  static const double _railWidth = 56;

  /// 浮层侧栏:展开时从右侧滑入盖在终端之上(不挤压终端),
  /// 带阴影;点击左侧空白遮罩关闭。收起时滑出屏外并禁交互。
  Widget _buildFloatingSidebar(List<SshHost> hosts) {
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: !_sidebarOpen,
        child: Stack(
          children: [
            // 轻遮罩:点击关闭,弱化背景,聚焦到面板
            GestureDetector(
              onTap: () => setState(() => _sidebarOpen = false),
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 200),
                opacity: _sidebarOpen ? 1 : 0,
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.18),
                ),
              ),
            ),
            // 面板:从右侧滑入
            Align(
              alignment: Alignment.centerRight,
              child: AnimatedSlide(
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                offset: Offset(_sidebarOpen ? 0 : 1, 0),
                child: Container(
                  width: _sidebarWidth,
                  height: double.infinity,
                  margin: const EdgeInsets.only(right: _railWidth),
                  decoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(
                        color: AppTheme.borderColor.withValues(alpha: 0.6),
                      ),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.18),
                        blurRadius: 22,
                        offset: const Offset(-6, 0),
                      ),
                    ],
                  ),
                  // 毛玻璃:半透明面板 + 背景模糊,终端隐约透出,更轻盈
                  child: ClipRect(
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                      child: ColoredBox(
                        color: AppTheme.surfaceColor.withValues(alpha: 0.78),
                        child: _buildSidebar(hosts),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCollapsedSidebar(List<SshHost> hosts) {
    return SizedBox(
      width: _railWidth,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 8),
          // 唯一的展开/收起切换按钮(带主机数徽标)
          _buildRailToggle(hosts),
          const SizedBox(height: 4),
          Divider(
            height: 9,
            thickness: 0.5,
            indent: 12,
            endIndent: 12,
            color: AppTheme.borderColor,
          ),
          const SizedBox(height: 2),
          // 常驻主机小图标列表(点击直连,悬停显示名称/目标)
          Expanded(
            child: hosts.isEmpty
                ? const SizedBox.shrink()
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    itemCount: hosts.length,
                    itemBuilder: (context, index) => _railHostAvatar(hosts[index]),
                  ),
          ),
          Divider(
            height: 9,
            thickness: 0.5,
            indent: 12,
            endIndent: 12,
            color: AppTheme.borderColor,
          ),
          const SizedBox(height: 2),
          // 新建主机
          _railButton(
            tooltip: tr('新建远程主机'),
            onTap: _addHost,
            child: Icon(
              LucideIcons.plus300,
              size: 16,
              color: AppTheme.subtleTextColor,
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  /// 收起竖条里的一台主机:首字母圆形头像(每台按名称取稳定色),
  /// 点击直接连接,悬停显示「名称 · user@host」;右键移动到分组。
  Widget _railHostAvatar(SshHost host) {
    final label = host.name.trim().isEmpty ? '?' : host.name.trim();
    final initial = String.fromCharCode(label.runes.first).toUpperCase();
    final tint = _avatarColor(host);
    return Tooltip(
      message: '$label · ${host.target}${host.port != 22 ? ':${host.port}' : ''}',
      waitDuration: const Duration(milliseconds: 300),
      preferBelow: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => unawaited(_connect(host)),
            onSecondaryTapUp: (d) =>
                unawaited(_pickGroupForHost(host, d.globalPosition)),
            child: Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: tint.withValues(alpha: 0.16),
              ),
              child: Text(
                initial,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: tint,
                  height: 1.0,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 按主机名散列出一个稳定的柔和色,让相邻头像有区分度。
  Color _avatarColor(SshHost host) {
    const palette = <Color>[
      Color(0xFF5B8DEF), // 蓝
      Color(0xFF2FB57C), // 绿
      Color(0xFFE0803A), // 橙
      Color(0xFFB06AD6), // 紫
      Color(0xFFD1567F), // 粉
      Color(0xFF3F9DB0), // 青
    ];
    final seed = host.id.isNotEmpty ? host.id : host.name;
    var h = 0;
    for (final c in seed.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return palette[h % palette.length];
  }

  /// 唯一的侧栏切换按钮:展开态高亮 + 左侧选中条 + 图标平滑切换 + 主机数徽标。
  Widget _buildRailToggle(List<SshHost> hosts) {
    final open = _sidebarOpen;
    return SizedBox(
      width: _railWidth,
      height: 40,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 左侧选中条:展开态从中间向上下伸出的品牌色竖条
          Positioned(
            left: 0,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              width: 3.5,
              height: open ? 24 : 0,
              decoration: BoxDecoration(
                color: AppTheme.brandColor,
                borderRadius: const BorderRadius.horizontal(
                  right: Radius.circular(3),
                ),
              ),
            ),
          ),
          _buildRailToggleButton(hosts, open),
        ],
      ),
    );
  }

  Widget _buildRailToggleButton(List<SshHost> hosts, bool open) {
    return Tooltip(
      message: open
          ? tr('收起主机列表')
          : tr2('展开主机列表${hosts.isNotEmpty ? "(共 {0} 台)" : ""}', [hosts.length]),
      waitDuration: const Duration(milliseconds: 300),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(11),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => setState(() => _sidebarOpen = !_sidebarOpen),
            hoverColor: AppTheme.subtleSurfaceColor.withValues(alpha: 0.8),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 40,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: open
                    ? AppTheme.brandColor.withValues(alpha: 0.14)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    transitionBuilder: (child, anim) => ScaleTransition(
                      scale: Tween<double>(begin: 0.7, end: 1).animate(anim),
                      child: FadeTransition(opacity: anim, child: child),
                    ),
                    child: Icon(
                      open
                          ? LucideIcons.panelRightClose300
                          : LucideIcons.panelRightOpen300,
                      key: ValueKey(open),
                      size: 18,
                      color: AppTheme.brandColor,
                    ),
                  ),
                  if (!open && hosts.isNotEmpty)
                    Positioned(
                      right: -3,
                      top: -4,
                      child: Container(
                        constraints: const BoxConstraints(minWidth: 14),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 3.5,
                          vertical: 1,
                        ),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: AppTheme.brandColor,
                          borderRadius: BorderRadius.circular(7),
                          border: Border.all(
                            color: AppTheme.surfaceColor,
                            width: 1.5,
                          ),
                        ),
                        child: Text(
                          '${hosts.length}',
                          style: const TextStyle(
                            fontSize: 8.5,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                            height: 1.1,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 收起竖条里的一个方形图标按钮(统一悬停高亮 / 圆角)。
  Widget _railButton({
    required String tooltip,
    required VoidCallback onTap,
    required Widget child,
  }) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 300),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(9),
          child: InkWell(
            borderRadius: BorderRadius.circular(9),
            hoverColor: AppTheme.subtleSurfaceColor.withValues(alpha: 0.8),
            onTap: onTap,
            child: SizedBox(
              width: 32,
              height: 32,
              child: Center(child: child),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSidebar(List<SshHost> hosts) {
    return DecoratedBox(
      decoration: const BoxDecoration(color: Colors.transparent),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
            ),
            padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
            child: Row(
              children: [
                Icon(
                  LucideIcons.server300,
                  size: 15,
                  color: AppTheme.brandColor,
                ),
                const SizedBox(width: 7),
                Text(
                  tr('远程主机'),
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.headingColor,
                  ),
                ),
                if (hosts.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.subtleSurfaceColor.withValues(alpha: 0.8),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${hosts.length}',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.subtleTextColor,
                      ),
                    ),
                  ),
                ],
                const Spacer(),
                IconButton(
                  tooltip: tr('传输记录'),
                  icon: Icon(
                    LucideIcons.arrowRightLeft300,
                    size: 15,
                    color: AppTheme.subtleTextColor,
                  ),
                  visualDensity: VisualDensity.compact,
                  splashRadius: 14,
                  onPressed: _showTransferLog,
                ),
                IconButton(
                  tooltip: tr('新建主机'),
                  icon: Icon(
                    LucideIcons.plus300,
                    size: 15,
                    color: AppTheme.subtleTextColor,
                  ),
                  visualDensity: VisualDensity.compact,
                  splashRadius: 14,
                  onPressed: _addHost,
                ),
              ],
            ),
          ),
          if (hosts.isNotEmpty) _buildSearchBar(),
          Expanded(
            child: hosts.isEmpty
                ? _buildEmptySidebar()
                : _buildHostList(hosts),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: TextField(
        controller: _hostSearch,
        style: TextStyle(fontSize: 12.5, color: AppTheme.headingColor),
        decoration: InputDecoration(
          isDense: true,
          hintText: tr('搜索主机 / 用户 / 分组'),
          hintStyle: TextStyle(
            fontSize: 12,
            color: AppTheme.subtleTextColor.withValues(alpha: 0.7),
          ),
          prefixIcon: Icon(
            LucideIcons.search300,
            size: 14,
            color: AppTheme.subtleTextColor,
          ),
          prefixIconConstraints: const BoxConstraints(minWidth: 32),
          suffixIcon: _hostQuery.isEmpty
              ? null
              : IconButton(
                  icon: Icon(
                    LucideIcons.x300,
                    size: 13,
                    color: AppTheme.subtleTextColor,
                  ),
                  splashRadius: 12,
                  onPressed: () {
                    _hostSearch.clear();
                    setState(() => _hostQuery = '');
                  },
                ),
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: AppTheme.borderColor),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: AppTheme.borderColor),
          ),
        ),
        onChanged: (v) => setState(() => _hostQuery = v.trim()),
      ),
    );
  }

  /// 搜索过滤 + 按分组归拢,渲染可折叠的会话管理器列表。
  Widget _buildHostList(List<SshHost> hosts) {
    final q = _hostQuery.toLowerCase();
    final filtered = q.isEmpty
        ? hosts
        : [
            for (final h in hosts)
              if (_matchesQuery(h, q)) h,
          ];
    if (filtered.isEmpty) {
      return Center(
        child: Text(
          tr2('没有匹配「{0}」的主机', [_hostQuery]),
          style: TextStyle(fontSize: 12, color: AppTheme.subtleTextColor),
        ),
      );
    }

    // 分组归拢:保持主机原有相对顺序;未分组的排最后。
    final groups = <String>[];
    final byGroup = <String, List<SshHost>>{};
    for (final h in filtered) {
      final key = h.group.trim().isEmpty ? '' : h.group.trim();
      (byGroup[key] ??= []).add(h);
      if (!groups.contains(key)) groups.add(key);
    }
    groups.sort((a, b) {
      if (a == b) return 0;
      if (a.isEmpty) return 1; // 未分组殿后
      if (b.isEmpty) return -1;
      return a.compareTo(b);
    });

    // 只有「未分组」一个桶且无人分组时,退化成扁平列表(不显示分组头)。
    final flat = groups.length == 1 && groups.first.isEmpty;

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 6),
      children: [
        for (final g in groups) ...[
          if (!flat) _buildGroupHeader(g, byGroup[g]!.length),
          // 搜索时忽略折叠状态,命中项一律展开;否则遵循折叠。
          if (flat || q.isNotEmpty || !_collapsedGroups.contains(_groupKey(g)))
            for (final h in byGroup[g]!) _hostTileFor(h),
        ],
      ],
    );
  }

  String _groupKey(String group) => group.isEmpty ? _ungrouped : group;

  bool _matchesQuery(SshHost h, String q) {
    return h.name.toLowerCase().contains(q) ||
        h.host.toLowerCase().contains(q) ||
        h.user.toLowerCase().contains(q) ||
        h.group.toLowerCase().contains(q);
  }

  Widget _buildGroupHeader(String group, int count) {
    final key = _groupKey(group);
    final collapsed = _collapsedGroups.contains(key);
    final label = group.isEmpty ? _ungrouped : group;
    return InkWell(
      onTap: () => setState(() {
        if (collapsed) {
          _collapsedGroups.remove(key);
        } else {
          _collapsedGroups.add(key);
        }
      }),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 4),
        child: Row(
          children: [
            Icon(
              collapsed
                  ? LucideIcons.chevronRight300
                  : LucideIcons.chevronDown300,
              size: 13,
              color: AppTheme.subtleTextColor,
            ),
            const SizedBox(width: 4),
            Icon(
              LucideIcons.folder300,
              size: 12,
              color: AppTheme.subtleTextColor,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.subtleTextColor,
                ),
              ),
            ),
            Text(
              '$count',
              style: TextStyle(
                fontSize: 11,
                color: AppTheme.subtleTextColor.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _hostTileFor(SshHost host) => _HostTile(
    host: host,
    onConnect: () => _connect(host),
    onBrowseFiles: () => _openSftp(host),
    onTunnels: () => unawaited(showTunnelManager(context, host)),
    onEdit: () => _editHost(host),
    onRemove: () => _removeHost(host),
    onMoveToGroup: (pos) => unawaited(_pickGroupForHost(host, pos)),
  );

  Widget _buildEmptySidebar() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            LucideIcons.server300,
            size: 28,
            color: AppTheme.subtleTextColor.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 10),
          Text(
            tr('还没有保存的主机'),
            style: TextStyle(fontSize: 12, color: AppTheme.subtleTextColor),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
            ),
            onPressed: _addHost,
            icon: const Icon(LucideIcons.plus300, size: 13),
            label: Text(tr('新建主机'), style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

/// 侧栏里的一台主机:双击或点 ▶ 连接;悬停出现编辑/删除。
class _HostTile extends StatefulWidget {
  const _HostTile({
    required this.host,
    required this.onConnect,
    required this.onBrowseFiles,
    required this.onEdit,
    required this.onRemove,
    required this.onTunnels,
    required this.onMoveToGroup,
  });

  final SshHost host;
  final VoidCallback onConnect;
  final VoidCallback onBrowseFiles;
  final VoidCallback onEdit;
  final VoidCallback onRemove;
  final VoidCallback onTunnels;

  /// 右键 / 悬停「移动到分组」;回调携带菜单锚点(全局坐标)
  final ValueChanged<Offset> onMoveToGroup;

  @override
  State<_HostTile> createState() => _HostTileState();
}

class _HostTileState extends State<_HostTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final host = widget.host;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: GestureDetector(
          onSecondaryTapUp: (d) => widget.onMoveToGroup(d.globalPosition),
          child: Material(
          color: _hovered
              ? AppTheme.subtleSurfaceColor.withValues(alpha: 0.7)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onDoubleTap: widget.onConnect,
            onTap: () {},
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
              child: Row(
                children: [
                  Icon(
                    LucideIcons.server300,
                    size: 14,
                    color: AppTheme.brandColor,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          host.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.headingColor,
                          ),
                        ),
                        Text(
                          [
                            host.target,
                            if (host.port != 22) ':${host.port}',
                          ].join(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: AppTheme.subtleTextColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_hovered) ...[
                    Builder(
                      builder: (btnContext) => _tileAction(
                        tr('移动到分组'),
                        LucideIcons.folderInput300,
                        () {
                          final box =
                              btnContext.findRenderObject() as RenderBox?;
                          final pos = box == null
                              ? Offset.zero
                              : box.localToGlobal(
                                  box.size.bottomLeft(Offset.zero),
                                );
                          widget.onMoveToGroup(pos);
                        },
                      ),
                    ),
                    _tileAction(tr('编辑'), LucideIcons.penLine300, widget.onEdit),
                    _tileAction(tr('删除'), LucideIcons.trash300, widget.onRemove),
                    _tileAction(
                      tr('端口转发'),
                      LucideIcons.waypoints300,
                      widget.onTunnels,
                    ),
                  ],
                  _tileAction(
                    tr('文件(SFTP)'),
                    LucideIcons.folder300,
                    widget.onBrowseFiles,
                  ),
                  _tileAction(
                    tr('连接'),
                    LucideIcons.play300,
                    widget.onConnect,
                    color: AppTheme.brandColor,
                  ),
                ],
              ),
            ),
          ),
        ),
        ),
      ),
    );
  }

  Widget _tileAction(
    String tooltip,
    IconData icon,
    VoidCallback onPressed, {
    Color? color,
  }) {
    return SizedBox(
      width: 24,
      height: 24,
      child: IconButton(
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        icon: Icon(icon, size: 13, color: color ?? AppTheme.subtleTextColor),
        splashRadius: 12,
        onPressed: onPressed,
      ),
    );
  }
}
