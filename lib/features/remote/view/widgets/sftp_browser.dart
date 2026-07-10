import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:toastification/toastification.dart';

import 'package:termora/app/theme/app_theme.dart';
import 'package:termora/core/widgets/app_toast.dart';
import 'package:termora/core/data/transfer_log_store.dart';
import 'package:termora/core/widgets/slide_select.dart';
import 'package:termora/core/utils/file_picker_helper.dart';
import 'package:termora/features/remote/data/local_file_service.dart';
import 'package:termora/features/remote/data/sftp_service.dart';
import 'package:termora/features/remote/domain/sftp_entry.dart';
import 'package:termora/features/remote/domain/ssh_host.dart';
import 'package:termora/core/l10n/app_l10n.dart';

/// SFTP 文件浏览器 — 挂在远程页右侧,复用该主机已认证的 SSH 连接。
/// v3:双栏(左本地、右远程)+ 跨栏拖拽传输,拖到对面栏空白处传到
/// 当前目录、拖到目录行上传进那个目录;v2 的传输队列(进度/取消)、
/// 递归目录传输、右键菜单原样保留,文件选择器降级为「…到指定位置」兜底。
class SftpBrowser extends StatefulWidget {
  const SftpBrowser({
    super.key,
    required this.host,
    required this.onClose,
    this.initialPath,
  });

  final SshHost host;
  final VoidCallback onClose;

  /// 远端栏起始目录(通常是 SSH 会话的当前目录,支持 ~ 前缀);
  /// null 或打不开时回落家目录
  final String? initialPath;

  @override
  State<SftpBrowser> createState() => _SftpBrowserState();
}

enum _TransferState { running, done, failed, cancelled }

/// 传输队列里的一项。total 为 null 表示不定进度(目录传输)。
class _Transfer {
  _Transfer({
    required this.label,
    required this.isUpload,
    required this.remoteDir,
    this.localDir,
    this.total,
  });

  final String label;
  final bool isUpload;

  /// 目标(上传)/来源(下载)所在的远端目录,用于完成后按需刷新列表
  final String remoteDir;

  /// 下载落地的本地目录,用于完成后按需刷新本地栏
  final String? localDir;

  int? total;
  int transferred = 0;
  _TransferState state = _TransferState.running;
  String? error;
  SftpTransferHandle? handle;
  Timer? poll;

  /// 重跑用:失败后按当前身份(可能已提权)重试
  Future<SftpTransferHandle> Function()? starter;
  Timer Function(_Transfer)? pollFactory;

  double? get progress {
    final t = total;
    if (t == null || t <= 0) return null;
    return (transferred / t).clamp(0.0, 1.0);
  }

  String get progressLabel {
    switch (state) {
      case _TransferState.done:
        return tr('完成');
      case _TransferState.failed:
        return tr('失败');
      case _TransferState.cancelled:
        return tr('已取消');
      case _TransferState.running:
        final p = progress;
        return p == null ? tr('传输中') : '${(p * 100).round()}%';
    }
  }
}

/// 跨栏拖拽的载荷:从哪个栏、哪个条目、条目所在目录
class _DragPayload {
  const _DragPayload({
    required this.fromRemote,
    required this.entry,
    required this.dir,
  });

  final bool fromRemote;
  final SftpEntry entry;
  final String dir;
}

/// 一个"编辑中"的远端文件:下到本地临时文件、用系统默认编辑器打开,
/// 轮询本地 mtime,保存即回传远端。
class _EditSession {
  _EditSession({
    required this.name,
    required this.localPath,
    required this.remoteDir,
    required this.lastModified,
  });

  final String name;
  final String localPath;
  final String remoteDir;
  DateTime lastModified;
  bool uploading = false;
  Timer? timer;
}

class _SftpBrowserState extends State<SftpBrowser> {
  // ── 远端栏 ──
  String? _remoteHome;
  String _remotePath = '/';
  List<SftpEntry> _remoteEntries = const [];
  bool _remoteLoading = true;
  bool _remoteShowHidden = false;
  String? _remoteError;

  // ── 本地栏 ──
  final String _localHome = LocalFileService.homeDirectory();
  String _localPath = '/';
  List<SftpEntry> _localEntries = const [];
  bool _localLoading = true;
  bool _localShowHidden = false;
  String? _localError;

  String _status = '';
  bool _statusIsError = false;
  final List<_Transfer> _transfers = [];
  final List<_EditSession> _edits = [];

  /// 滑动多选(按住垂直滑动圈选;两栏各自独立,key = 条目名)
  final _remoteSelect = SlideSelectController<String>();
  final _localSelect = SlideSelectController<String>();

  /// Finder 拖拽正悬停在远端栏上(系统级拖放,区别于应用内跨栏拖拽)
  bool _osDropActive = false;

  /// 提权:非 null = 已提权;_elevSu 区分 sudo(当前用户密码)/ su(root 密码)。
  /// 密码只在内存、随面板关闭销毁,不落盘
  String? _elevPassword;
  bool _elevSu = false;
  bool get _elevated => _elevPassword != null;

  /// 当前目录因权限被拒、正等待提权
  bool _remoteNeedsElevation = false;
  String? _deniedPath;

  // ── 远端操作按提权方式分派(none / sudo / su) ──

  Future<SftpTransferHandle> _startDownload(
    String remote,
    String local, {
    bool recursive = false,
  }) {
    final pw = _elevPassword;
    if (pw != null) {
      if (_elevSu) {
        // su:目录经 tar+base64,文件经 base64
        return recursive
            ? SuFileService.startDownloadDir(widget.host, pw, remote, local)
            : SuFileService.startDownloadFile(widget.host, pw, remote, local);
      }
      return recursive
          ? SudoFileService.startDownloadDir(widget.host, pw, remote, local)
          : SudoFileService.startDownloadFile(widget.host, pw, remote, local);
    }
    return SftpService.startDownload(
      widget.host,
      remote,
      local,
      recursive: recursive,
    );
  }

  Future<SftpTransferHandle> _startUpload(String localPath, String remoteDir) {
    final pw = _elevPassword;
    if (pw != null) {
      if (_elevSu) {
        return Future.error(
          SftpException(tr('su 提权暂不支持上传,请以 root 登录或用 sudo')),
        );
      }
      final name = localPath.split('/').where((s) => s.isNotEmpty).last;
      return SudoFileService.startUploadFile(
        widget.host,
        pw,
        localPath,
        _join(remoteDir, name),
      );
    }
    return SftpService.startUpload(widget.host, localPath, remoteDir);
  }

  Future<SftpTransferHandle> _startUploadDir(
    String localDir,
    String remoteDir,
  ) {
    final pw = _elevPassword;
    if (pw != null) {
      if (_elevSu) {
        return Future.error(
          SftpException(tr('su 提权暂不支持上传,请以 root 登录或用 sudo')),
        );
      }
      return SudoFileService.startUploadDir(widget.host, pw, localDir, remoteDir);
    }
    return SftpService.startUploadDir(widget.host, localDir, remoteDir);
  }

  Future<int?> _remoteFileSize(String remotePath) {
    final pw = _elevPassword;
    if (pw == null) return SftpService.fileSize(widget.host, remotePath);
    return _elevSu
        ? SuFileService.fileSize(widget.host, pw, remotePath)
        : SudoFileService.fileSize(widget.host, pw, remotePath);
  }

  Future<void> _remoteRename(String from, String to) {
    final pw = _elevPassword;
    if (pw == null) return SftpService.rename(widget.host, from, to);
    return _elevSu
        ? SuFileService.rename(widget.host, pw, from, to)
        : SudoFileService.rename(widget.host, pw, from, to);
  }

  Future<void> _remoteRemove(String path, bool isDir) {
    final pw = _elevPassword;
    if (pw == null) {
      return isDir
          ? SftpService.removeDir(widget.host, path)
          : SftpService.remove(widget.host, path);
    }
    if (_elevSu) return SuFileService.remove(widget.host, pw, path, isDir);
    return isDir
        ? SudoFileService.removeDir(widget.host, pw, path)
        : SudoFileService.remove(widget.host, pw, path);
  }

  Future<void> _remoteMakeDir(String path) {
    final pw = _elevPassword;
    if (pw == null) return SftpService.makeDir(widget.host, path);
    return _elevSu
        ? SuFileService.makeDir(widget.host, pw, path)
        : SudoFileService.makeDir(widget.host, pw, path);
  }

  Future<List<SftpEntry>> _remoteList(String path) {
    final pw = _elevPassword;
    if (pw == null) return SftpService.list(widget.host, path);
    return _elevSu
        ? SuFileService.list(widget.host, pw, path)
        : SudoFileService.list(widget.host, pw, path);
  }

  /// 权限拒绝时提权:选方式(sudo / su root)→ 输密码 → 校验 → 重列被拒目录
  Future<void> _elevate() async {
    final choice = await _promptElevation();
    if (choice == null || choice.password.isEmpty || !mounted) return;
    final su = choice.su;
    setState(() {
      _remoteLoading = true;
      _status = su ? tr('正在验证 su(root)…') : tr('正在验证 sudo …');
      _statusIsError = false;
    });
    try {
      if (su) {
        await SuFileService.verify(widget.host, choice.password);
      } else {
        await SudoFileService.verify(widget.host, choice.password);
      }
      if (!mounted) return;
      _elevPassword = choice.password;
      _elevSu = su;
      setState(() => _remoteNeedsElevation = false);
      _toast(tr('已提权(root),现在以 root 浏览/下载'), ToastificationType.success);
      await _navigateRemote(_deniedPath ?? _remotePath);
    } on SftpException catch (error) {
      _failRemote(error.message);
      _toast(tr2('提权失败:{0}', [error.message]), ToastificationType.error);
    }
  }

  /// 提权方式 + 密码的弹窗
  Future<({bool su, String password})?> _promptElevation() {
    var su = _elevSu;
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
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
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
            const SizedBox(width: 5),
            Text(
              title,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color:
                    selected ? AppTheme.headingColor : AppTheme.subtleTextColor,
              ),
            ),
          ],
        ),
      ),
    );
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

  /// 退出提权:清掉内存里的密码,回到登录用户身份
  void _dropElevation() {
    setState(() {
      _elevPassword = null;
      _elevSu = false;
      _remoteNeedsElevation = false;
    });
    unawaited(_navigateRemote(_remoteHome ?? '/'));
  }

  @override
  void initState() {
    super.initState();
    // 选择集变化(滑选扩展/toggle)只影响高亮与批量条,整树 setState 即可
    _remoteSelect.addListener(_onSelectionChanged);
    _localSelect.addListener(_onSelectionChanged);
    unawaited(_openRemote());
    unawaited(_openLocal());
    unawaited(_restoreTransferLog());
  }

  /// 恢复该主机最近的传输记录(SQLite):面板重开/应用重启后历史仍在。
  /// 恢复出的记录不可取消/重试(进程已不在),仅作展示。
  Future<void> _restoreTransferLog() async {
    try {
      final records = await TransferLogStore.recent(widget.host.id);
      if (!mounted || records.isEmpty) return;
      setState(() {
        for (final r in records) {
          final t = _Transfer(
            label: r.label,
            isUpload: r.isUpload,
            remoteDir: '',
            total: r.total,
          )..state = switch (r.state) {
              'done' => _TransferState.done,
              'cancelled' => _TransferState.cancelled,
              _ => _TransferState.failed,
            }
            ..error = r.error;
          if (t.state == _TransferState.done && r.total != null) {
            t.transferred = r.total!;
          }
          _transfers.add(t);
        }
      });
    } catch (_) {
      // 历史恢复失败不影响新传输
    }
  }

  /// 传输到达终态后落盘(每主机保留最近 200 条)
  void _logTransfer(_Transfer t) {
    final state = switch (t.state) {
      _TransferState.done => 'done',
      _TransferState.cancelled => 'cancelled',
      _TransferState.failed => 'failed',
      _TransferState.running => 'running',
    };
    if (state == 'running') return;
    unawaited(
      TransferLogStore.add(
        TransferRecord(
          host: widget.host.id,
          label: t.label,
          isUpload: t.isUpload,
          state: state,
          error: t.error,
          total: t.total,
          finishedAt: DateTime.now(),
        ),
      ).catchError((_) {}),
    );
  }

  void _onSelectionChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _remoteSelect.dispose();
    _localSelect.dispose();
    for (final t in _transfers) {
      t.poll?.cancel();
      // 传输进程不随面板关闭而中断,让它跑完
    }
    for (final s in _edits) {
      s.timer?.cancel();
    }
    super.dispose();
  }

  // ── 浏览:远端 ──

  Future<void> _openRemote() async {
    setState(() {
      _remoteLoading = true;
      _status = tr2('正在连接 {0} …', [widget.host.target]);
      _statusIsError = false;
    });
    try {
      final home = await SftpService.homeDirectory(widget.host);
      if (!mounted) return;
      _remoteHome = home;
      final start = _expandRemotePath(widget.initialPath, home) ?? home;
      if (!await _navigateRemote(start) && start != home && mounted) {
        // SSH 会话所在目录可能已被删或无权限,回落家目录
        await _navigateRemote(home);
      }
    } on SftpException catch (error) {
      _failRemote(error.message);
    }
  }

  @override
  void didUpdateWidget(covariant SftpBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 面板开着时又点了一次「文件」:SSH 会话目录变了就跟过去
    if (widget.initialPath != oldWidget.initialPath) {
      final home = _remoteHome;
      final target = home == null
          ? null
          : _expandRemotePath(widget.initialPath, home);
      if (target != null && target != _remotePath) {
        unawaited(_navigateRemote(target));
      }
    }
  }

  // ── 地址栏 ──

  /// 地址栏回车:~ 展开、相对路径按当前目录解析、去掉结尾多余的 /
  void _submitRemotePath(String raw) {
    final home = _remoteHome;
    final String path;
    if (raw == '~' || raw.startsWith('~/')) {
      if (home == null) return;
      path = raw == '~' ? home : _join(home, raw.substring(2));
    } else if (raw.startsWith('/')) {
      path = raw;
    } else {
      path = _join(_remotePath, raw);
    }
    unawaited(_navigateRemote(_normalizePath(path)));
  }

  void _submitLocalPath(String raw) {
    final String path;
    if (raw == '~' || raw.startsWith('~/')) {
      path = raw == '~' ? _localHome : _join(_localHome, raw.substring(2));
    } else if (raw.startsWith('/')) {
      path = raw;
    } else {
      path = _join(_localPath, raw);
    }
    unawaited(_navigateLocal(_normalizePath(path)));
  }

  /// 去掉结尾多余的 /(根目录除外)
  String _normalizePath(String path) {
    var p = path;
    while (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  /// ~ / ~/xxx 展开成绝对路径;空串或相对路径返回 null
  String? _expandRemotePath(String? path, String home) {
    if (path == null || path.isEmpty) return null;
    if (path == '~') return home;
    if (path.startsWith('~/')) return _join(home, path.substring(2));
    return path.startsWith('/') ? path : null;
  }

  Future<bool> _navigateRemote(String path) async {
    setState(() {
      _remoteLoading = true;
      _statusIsError = false;
    });
    try {
      final entries = await _remoteList(path);
      if (!mounted) return false;
      // 换目录清空选择;同目录刷新只保留仍存在的条目
      if (path != _remotePath) {
        _remoteSelect.clear();
      } else {
        final names = {for (final e in entries) e.name};
        _remoteSelect.retainWhere(names.contains);
      }
      setState(() {
        _remotePath = path;
        _remoteEntries = entries;
        _remoteLoading = false;
        _remoteError = null;
        _remoteNeedsElevation = false;
        _status = _elevated
            ? tr2('远端(root) {0} 项', [entries.length])
            : tr2('远端 {0} 项', [entries.length]);
        _statusIsError = false;
      });
      return true;
    } on SftpException catch (error) {
      if (!mounted) return false;
      // 未提权且是权限问题 → 就地给「提权访问」入口,而不是死在报错
      if (!_elevated && error.message.contains('Permission denied')) {
        setState(() {
          _remoteLoading = false;
          _remoteNeedsElevation = true;
          _deniedPath = path;
          _remoteError = error.message;
          _status = tr2('权限不足,可提权访问:{0}', [path]);
          _statusIsError = true;
        });
        return false;
      }
      _failRemote(error.message);
      return false;
    }
  }

  Future<void> _refreshRemote() => _navigateRemote(_remotePath);

  void _failRemote(String message) {
    if (!mounted) return;
    setState(() {
      _remoteLoading = false;
      _remoteError = message;
      _status = message;
      _statusIsError = true;
    });
  }

  // ── 浏览:本地 ──

  Future<void> _openLocal() async {
    final initial = await FilePickerHelper.getInitialDirectory();
    if (!mounted) return;
    await _navigateLocal(initial ?? _localHome);
  }

  Future<void> _navigateLocal(String path) async {
    setState(() => _localLoading = true);
    try {
      final entries = await LocalFileService.list(path);
      if (!mounted) return;
      FilePickerHelper.updateLastDirectoryFromPath(path);
      if (path != _localPath) {
        _localSelect.clear();
      } else {
        final names = {for (final e in entries) e.name};
        _localSelect.retainWhere(names.contains);
      }
      setState(() {
        _localPath = path;
        _localEntries = entries;
        _localLoading = false;
        _localError = null;
      });
    } on LocalFileException catch (error) {
      _failLocal(error.message);
    }
  }

  Future<void> _refreshLocal() => _navigateLocal(_localPath);

  void _failLocal(String message) {
    if (!mounted) return;
    setState(() {
      _localLoading = false;
      _localError = message;
      _status = message;
      _statusIsError = true;
    });
  }

  String _join(String dir, String name) =>
      dir == '/' ? '/$name' : '$dir/$name';

  String _parentOf(String path) {
    final index = path.lastIndexOf('/');
    if (index <= 0) return '/';
    return path.substring(0, index);
  }

  List<SftpEntry> get _visibleRemote => _remoteShowHidden
      ? _remoteEntries
      : [
          for (final e in _remoteEntries)
            if (!e.name.startsWith('.')) e,
        ];

  List<SftpEntry> get _visibleLocal => _localShowHidden
      ? _localEntries
      : [
          for (final e in _localEntries)
            if (!e.name.startsWith('.')) e,
        ];

  // ── 传输队列 ──

  Future<void> _beginTransfer(
    _Transfer transfer,
    Future<SftpTransferHandle> Function() start, {
    Timer Function(_Transfer)? pollFactory,
    bool reinsert = true,
  }) async {
    transfer.starter = start;
    transfer.pollFactory = pollFactory;
    if (reinsert) {
      setState(() => _transfers.insert(0, transfer));
    } else {
      setState(() {
        transfer.state = _TransferState.running;
        transfer.error = null;
        transfer.transferred = 0;
      });
    }
    try {
      final handle = await start();
      transfer.handle = handle;
      if (pollFactory != null) transfer.poll = pollFactory(transfer);
      await handle.done;
      transfer.poll?.cancel();
      if (!mounted) return;
      setState(() {
        transfer.state = handle.cancelled
            ? _TransferState.cancelled
            : _TransferState.done;
        if (transfer.state == _TransferState.done && transfer.total != null) {
          transfer.transferred = transfer.total!;
        }
      });
      _logTransfer(transfer);
      // 完成后:上传方还停在目标远端目录、下载方还停在落地本地目录 → 刷新现身
      if (transfer.state == _TransferState.done) {
        if (transfer.isUpload && transfer.remoteDir == _remotePath) {
          unawaited(_refreshRemote());
        }
        if (!transfer.isUpload && transfer.localDir == _localPath) {
          unawaited(_refreshLocal());
        }
      }
    } on SftpException catch (error) {
      transfer.poll?.cancel();
      if (!mounted) return;
      final denied =
          !_elevated && error.message.contains('Permission denied');
      setState(() {
        transfer.state = _TransferState.failed;
        transfer.error = error.message;
        _logTransfer(transfer);
        // 失败原因直接亮在状态栏,不用悬停传输行才看到;权限问题提示可提权
        _status = denied
            ? tr2('权限不足:{0}。点右上角盾牌图标提权后重试(sudo 或 su root)。', [transfer.label])
            : tr2('传输失败:{0} — {1}', [transfer.label, error.message]);
        _statusIsError = true;
      });
    }
  }

  void _cancelTransfer(_Transfer transfer) => transfer.handle?.cancel();

  /// 重试失败的传输(用当前身份,提权后一点就走 root)
  void _retryTransfer(_Transfer transfer) {
    final start = transfer.starter;
    if (start == null) return;
    unawaited(
      _beginTransfer(
        transfer,
        start,
        pollFactory: transfer.pollFactory,
        reinsert: false,
      ),
    );
  }

  void _clearFinishedTransfers() {
    setState(
      () => _transfers.removeWhere((t) => t.state != _TransferState.running),
    );
  }

  /// 下载进度轮询:盯本地文件大小(已知远端总大小)
  Timer _localSizePoll(_Transfer t, String localPath) =>
      Timer.periodic(const Duration(milliseconds: 400), (_) {
        if (t.state != _TransferState.running) return;
        File(localPath).stat().then((stat) {
          if (!mounted || t.state != _TransferState.running) return;
          if (stat.type == FileSystemEntityType.notFound) return;
          setState(() => t.transferred = stat.size);
        });
      });

  /// 上传进度轮询:周期性查远端文件大小(经 control socket,开销小)
  Timer _remoteSizePoll(_Transfer t, String remoteFile) =>
      Timer.periodic(const Duration(milliseconds: 1500), (_) {
        if (t.state != _TransferState.running) return;
        _remoteFileSize(remoteFile).then((size) {
          if (!mounted || t.state != _TransferState.running) return;
          if (size != null) setState(() => t.transferred = size);
        });
      });

  /// 下载(拖拽/行按钮/菜单):直接落到本地栏目录,免文件选择器
  Future<void> _downloadToLocal(
    SftpEntry entry, {
    required String remoteDir,
    required String targetDir,
  }) async {
    final remote = _join(remoteDir, entry.name);
    if (entry.isDir) {
      final transfer = _Transfer(
        label: '${entry.name}/',
        isUpload: false,
        remoteDir: remoteDir,
        localDir: targetDir,
      );
      unawaited(
        _beginTransfer(
          transfer,
          () => _startDownload(remote, targetDir, recursive: true),
        ),
      );
      return;
    }
    final localPath = _join(targetDir, entry.name);
    final transfer = _Transfer(
      label: entry.name,
      isUpload: false,
      remoteDir: remoteDir,
      localDir: targetDir,
      total: entry.size > 0 ? entry.size : null,
    );
    unawaited(
      _beginTransfer(
        transfer,
        () => _startDownload(remote, localPath),
        pollFactory: (t) => _localSizePoll(t, localPath),
      ),
    );
  }

  /// 上传(拖拽/行按钮/菜单):把本地栏条目传到远端目录
  Future<void> _uploadFromLocal(
    SftpEntry entry, {
    required String localDir,
    required String targetDir,
  }) =>
      _uploadLocalPath(_join(localDir, entry.name), targetDir: targetDir);

  /// 上传任意本地路径(文件或目录)到远端目录 — 应用内拖拽与
  /// Finder 拖入共用的底座
  Future<void> _uploadLocalPath(
    String localPath, {
    required String targetDir,
  }) async {
    final name = localPath.split('/').where((s) => s.isNotEmpty).lastOrNull;
    if (name == null) return;
    if (FileSystemEntity.isDirectorySync(localPath)) {
      final transfer = _Transfer(
        label: '$name/',
        isUpload: true,
        remoteDir: targetDir,
      );
      unawaited(
        _beginTransfer(
          transfer,
          () => _startUploadDir(localPath, targetDir),
        ),
      );
      return;
    }
    int? total;
    try {
      total = await File(localPath).length();
    } catch (_) {}
    final remoteFile = _join(targetDir, name);
    final transfer = _Transfer(
      label: name,
      isUpload: true,
      remoteDir: targetDir,
      total: total,
    );
    unawaited(
      _beginTransfer(
        transfer,
        () => _startUpload(localPath, targetDir),
        pollFactory: (t) => _remoteSizePoll(t, remoteFile),
      ),
    );
  }

  /// Finder 拖进远端栏:全部上传到远端当前目录
  void _handleOsDrop(DropDoneDetails detail) {
    for (final file in detail.files) {
      if (file.path.isEmpty) continue;
      unawaited(_uploadLocalPath(file.path, targetDir: _remotePath));
    }
  }

  /// 下载到指定位置(文件选择器兜底)
  Future<void> _downloadFileWithPicker(SftpEntry entry) async {
    final localPath = await FilePicker.saveFile(
      dialogTitle: tr('下载到…'),
      fileName: entry.name,
      initialDirectory: await FilePickerHelper.getInitialDirectory(),
    );
    if (localPath == null || localPath.isEmpty || !mounted) return;
    FilePickerHelper.updateLastDirectory(localPath);
    final remote = _join(_remotePath, entry.name);
    final transfer = _Transfer(
      label: entry.name,
      isUpload: false,
      remoteDir: _remotePath,
      localDir: File(localPath).parent.path,
      total: entry.size > 0 ? entry.size : null,
    );
    unawaited(
      _beginTransfer(
        transfer,
        () => _startDownload(remote, localPath),
        pollFactory: (t) => _localSizePoll(t, localPath),
      ),
    );
  }

  /// 下载目录到指定位置(递归,不定进度)
  Future<void> _downloadDirWithPicker(SftpEntry entry) async {
    final localDir = await FilePicker.getDirectoryPath(
      dialogTitle: tr2('下载目录「{0}」到…', [entry.name]),
      initialDirectory: await FilePickerHelper.getInitialDirectory(),
    );
    if (localDir == null || localDir.isEmpty || !mounted) return;
    FilePickerHelper.updateLastDirectoryFromPath(localDir);
    final remote = _join(_remotePath, entry.name);
    final transfer = _Transfer(
      label: '${entry.name}/',
      isUpload: false,
      remoteDir: _remotePath,
      localDir: localDir,
    );
    unawaited(
      _beginTransfer(
        transfer,
        () => _startDownload(remote, localDir, recursive: true),
      ),
    );
  }

  /// 上传文件(多选,文件选择器兜底)
  Future<void> _uploadFilesWithPicker() async {
    final initialDirectory = await FilePickerHelper.getInitialDirectory();
    final result = await FilePicker.pickFiles(
      dialogTitle: tr('选择要上传的文件'),
      allowMultiple: true,
      initialDirectory: initialDirectory,
    );
    final paths = [
      for (final f in result?.files ?? const <PlatformFile>[])
        if (f.path != null && f.path!.isNotEmpty) f.path!,
    ];
    if (paths.isEmpty || !mounted) return;
    FilePickerHelper.updateLastDirectory(paths.first);
    final targetDir = _remotePath;
    for (final localPath in paths) {
      final name = localPath.split('/').last;
      int? total;
      try {
        total = await File(localPath).length();
      } catch (_) {}
      final remoteFile = _join(targetDir, name);
      final transfer = _Transfer(
        label: name,
        isUpload: true,
        remoteDir: targetDir,
        total: total,
      );
      unawaited(
        _beginTransfer(
          transfer,
          () => _startUpload(localPath, targetDir),
          pollFactory: (t) => _remoteSizePoll(t, remoteFile),
        ),
      );
    }
  }

  /// 上传目录(递归,不定进度,文件选择器兜底)
  Future<void> _uploadDirWithPicker() async {
    final localDir = await FilePicker.getDirectoryPath(
      dialogTitle: tr('选择要上传的目录'),
      initialDirectory: await FilePickerHelper.getInitialDirectory(),
    );
    if (localDir == null || localDir.isEmpty || !mounted) return;
    FilePickerHelper.updateLastDirectoryFromPath(localDir);
    final name = localDir.split('/').where((s) => s.isNotEmpty).last;
    final transfer = _Transfer(
      label: '$name/',
      isUpload: true,
      remoteDir: _remotePath,
    );
    unawaited(
      _beginTransfer(
        transfer,
        () => _startUploadDir(localDir, _remotePath),
      ),
    );
  }

  // ── 单条目操作:远端 ──

  Future<void> _renameRemote(SftpEntry entry) async {
    final name = await _promptText(
      title: tr('重命名'),
      initial: entry.name,
      confirm: tr('重命名'),
    );
    if (name == null || name.isEmpty || name == entry.name || !mounted) return;
    await _runRemoteOp(
      tr2('重命名 {0} → {1}…', [entry.name, name]),
      () => _remoteRename(
        _join(_remotePath, entry.name),
        _join(_remotePath, name),
      ),
    );
  }

  Future<void> _deleteRemote(SftpEntry entry) async {
    if (!await _confirmDelete(entry)) return;
    final remote = _join(_remotePath, entry.name);
    await _runRemoteOp(
      tr2('删除 {0}…', [entry.name]),
      () => _remoteRemove(remote, entry.isDir),
    );
  }

  Future<void> _makeRemoteDir() async {
    final name = await _promptText(title: tr('新建目录'), confirm: tr('创建'));
    if (name == null || name.isEmpty || !mounted) return;
    await _runRemoteOp(
      tr2('创建目录 {0}…', [name]),
      () => _remoteMakeDir(_join(_remotePath, name)),
    );
  }

  Future<void> _runRemoteOp(String doing, Future<void> Function() op) async {
    setState(() {
      _remoteLoading = true;
      _status = doing;
      _statusIsError = false;
    });
    try {
      await op();
      if (!mounted) return;
      await _refreshRemote();
    } on SftpException catch (error) {
      _failRemote(error.message);
    }
  }

  // ── 单条目操作:本地 ──

  Future<void> _renameLocal(SftpEntry entry) async {
    final name = await _promptText(
      title: tr('重命名'),
      initial: entry.name,
      confirm: tr('重命名'),
    );
    if (name == null || name.isEmpty || name == entry.name || !mounted) return;
    await _runLocalOp(
      tr2('重命名 {0} → {1}…', [entry.name, name]),
      () => LocalFileService.rename(
        _join(_localPath, entry.name),
        _join(_localPath, name),
      ),
    );
  }

  Future<void> _deleteLocal(SftpEntry entry) async {
    if (!await _confirmDelete(entry)) return;
    final path = _join(_localPath, entry.name);
    await _runLocalOp(
      tr2('删除 {0}…', [entry.name]),
      () => entry.isDir
          ? LocalFileService.removeDir(path)
          : LocalFileService.remove(path),
    );
  }

  Future<void> _makeLocalDir() async {
    final name = await _promptText(title: tr('新建目录'), confirm: tr('创建'));
    if (name == null || name.isEmpty || !mounted) return;
    await _runLocalOp(
      tr2('创建目录 {0}…', [name]),
      () => LocalFileService.makeDir(_join(_localPath, name)),
    );
  }

  Future<void> _runLocalOp(String doing, Future<void> Function() op) async {
    setState(() {
      _localLoading = true;
      _status = doing;
      _statusIsError = false;
    });
    try {
      await op();
      if (!mounted) return;
      await _refreshLocal();
    } on LocalFileException catch (error) {
      _failLocal(error.message);
    }
  }

  Future<void> _pickLocalDirectory() async {
    final dir = await FilePicker.getDirectoryPath(
      dialogTitle: tr('切换本地目录'),
      initialDirectory: await FilePickerHelper.getInitialDirectory(),
    );
    if (dir == null || dir.isEmpty || !mounted) return;
    await _navigateLocal(dir);
  }

  /// macOS:Finder 中显示 / 用默认应用打开(best-effort,不阻塞不报错)
  void _revealInFinder(String path) =>
      unawaited(Process.run('open', ['-R', path]));

  void _openLocally(String path) => unawaited(Process.run('open', [path]));

  Future<void> _copyPath(String path) async {
    await Clipboard.setData(ClipboardData(text: path));
    if (!mounted) return;
    setState(() {
      _status = tr2('已复制路径: {0}', [path]);
      _statusIsError = false;
    });
  }

  // ── 共用对话框 ──

  Future<bool> _confirmDelete(SftpEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(entry.isDir ? tr('删除目录') : tr('删除文件')),
        content: Text(
          entry.isDir
              ? tr2('确定删除目录「{0}」吗?(仅能删除空目录)', [entry.name])
              : tr2('确定删除「{0}」吗?', [entry.name]),
        ),
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
    return confirmed == true && mounted;
  }

  Future<String?> _promptText({
    required String title,
    required String confirm,
    String initial = '',
    bool obscure = false,
    String? hint,
  }) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          obscureText: obscure,
          style: TextStyle(fontSize: 13, color: AppTheme.headingColor),
          decoration: InputDecoration(
            isDense: true,
            border: const OutlineInputBorder(),
            hintText: hint,
            hintStyle: TextStyle(
              fontSize: 12,
              color: AppTheme.subtleTextColor.withValues(alpha: 0.7),
            ),
          ),
          // 密码框回车不 trim(密码可能含首尾空格)
          onSubmitted: (value) =>
              Navigator.of(context).pop(obscure ? value : value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(tr('取消')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.brandColor),
            onPressed: () => Navigator.of(context).pop(
              obscure ? controller.text : controller.text.trim(),
            ),
            child: Text(confirm),
          ),
        ],
      ),
    );
  }

  // ── 右键菜单 ──

  Future<T?> _showContextMenu<T>(
    Offset globalPosition,
    List<PopupMenuEntry<T>> items,
  ) {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    return showMenu<T>(
      context: context,
      color: AppTheme.surfaceColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: AppTheme.borderColor),
      ),
      position: RelativeRect.fromRect(
        globalPosition & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: items,
    );
  }

  PopupMenuItem<String> _menuItem(
    String value,
    IconData icon,
    String label, {
    Color? color,
  }) {
    final c = color ?? AppTheme.headingColor;
    return PopupMenuItem<String>(
      value: value,
      height: 36,
      child: Row(
        children: [
          Icon(icon, size: 15, color: c),
          const SizedBox(width: 10),
          Text(label, style: TextStyle(fontSize: 13, color: c)),
        ],
      ),
    );
  }

  // ── 远端文件直接编辑(下载→系统编辑器→保存自动回传)──

  Future<void> _editRemoteFile(SftpEntry entry) async {
    final remoteFile = _join(_remotePath, entry.name);
    final remoteDir = _remotePath;
    setState(() {
      _status = tr2('下载 {0} 用于编辑…', [entry.name]);
      _statusIsError = false;
    });
    try {
      final tempDir = await Directory.systemTemp.createTemp('termora_edit_');
      final localPath = '${tempDir.path}/${entry.name}';
      final dl = await _startDownload(remoteFile, localPath);
      await dl.done;
      if (!mounted) return;
      // 用系统默认应用打开(best-effort)
      unawaited(Process.run('open', [localPath]));
      final stat = await File(localPath).stat();
      final session = _EditSession(
        name: entry.name,
        localPath: localPath,
        remoteDir: remoteDir,
        lastModified: stat.modified,
      );
      session.timer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => unawaited(_checkEdit(session)),
      );
      setState(() {
        _edits.add(session);
        _status = tr2('编辑中 {0} — 在编辑器里保存即自动回传', [entry.name]);
        _statusIsError = false;
      });
    } on SftpException catch (e) {
      _failRemote(e.message);
    } catch (e) {
      _failRemote('$e');
    }
  }

  Future<void> _checkEdit(_EditSession s) async {
    if (s.uploading) return;
    final FileStat stat;
    try {
      stat = await File(s.localPath).stat();
    } catch (_) {
      return;
    }
    if (stat.type == FileSystemEntityType.notFound) return;
    if (!stat.modified.isAfter(s.lastModified)) return;
    s.lastModified = stat.modified;
    if (_elevated && _elevSu) {
      if (mounted) {
        setState(() {
          _status = tr2('su 提权模式不支持回传 {0}(以 root 登录或用 sudo 才能保存)', [s.name]);
          _statusIsError = true;
        });
      }
      return;
    }
    s.uploading = true;
    try {
      final handle = await _startUpload(s.localPath, s.remoteDir);
      await handle.done;
      if (!mounted) return;
      setState(() {
        _status = tr2('已回传 {0}', [s.name]);
        _statusIsError = false;
      });
      if (s.remoteDir == _remotePath) unawaited(_refreshRemote());
    } on SftpException catch (e) {
      if (mounted) {
        setState(() {
          _status = tr2('回传失败 {0}:{1}', [s.name, e.message]);
          _statusIsError = true;
        });
      }
    } finally {
      s.uploading = false;
    }
  }

  void _stopEdit(_EditSession s) {
    s.timer?.cancel();
    setState(() => _edits.remove(s));
  }

  /// 右键行时的选择整理(Finder 心智):右键未选中的行 → 选择切到该行;
  /// 右键已选中的行且选了多项 → 视为对整个选择集操作(返回 true)。
  bool _prepareContextSelection(SlideSelectController<String> select, String name) {
    if (select.contains(name) && select.selected.length > 1) return true;
    select.replaceWith(name);
    return false;
  }

  /// 多选批量菜单(远端/本地通用骨架)
  Future<void> _showMultiMenu(
    Offset position, {
    required bool isRemote,
  }) async {
    final entries = _selectedEntries(isRemote: isRemote);
    final count = entries.length;
    final action = await _showContextMenu<String>(position, [
      _menuItem(
        'transfer',
        isRemote ? LucideIcons.download300 : LucideIcons.upload300,
        isRemote ? tr2('下载 {0} 项到本地栏', [count]) : tr2('上传 {0} 项到远端栏', [count]),
      ),
      const PopupMenuDivider(),
      _menuItem('selectAll', LucideIcons.copyCheck300, tr('全选')),
      _menuItem('clear', LucideIcons.x300, tr('清除选择')),
      const PopupMenuDivider(),
      _menuItem(
        'delete',
        LucideIcons.trash300,
        tr2('删除 {0} 项', [count]),
        color: AppTheme.errorColor,
      ),
    ]);
    if (!mounted || action == null) return;
    switch (action) {
      case 'transfer':
        _transferSelected(isRemote: isRemote);
      case 'selectAll':
        (isRemote ? _remoteSelect : _localSelect).selectAll([
          for (final e in isRemote ? _visibleRemote : _visibleLocal) e.name,
        ]);
      case 'clear':
        (isRemote ? _remoteSelect : _localSelect).clear();
      case 'delete':
        unawaited(_deleteSelected(isRemote: isRemote));
    }
  }

  Future<void> _showRemoteEntryMenu(Offset position, SftpEntry entry) async {
    if (_prepareContextSelection(_remoteSelect, entry.name)) {
      return _showMultiMenu(position, isRemote: true);
    }
    final action = await _showContextMenu<String>(position, [
      if (entry.isDir) _menuItem('open', LucideIcons.folder300, tr('打开')),
      if (!entry.isDir)
        _menuItem('edit', LucideIcons.filePen300, tr('编辑(保存自动回传)')),
      _menuItem(
        'downloadHere',
        entry.isDir ? LucideIcons.folderDown300 : LucideIcons.download300,
        tr('下载到本地栏'),
      ),
      _menuItem('downloadTo', LucideIcons.download300, tr('下载到…')),
      _menuItem('rename', LucideIcons.penLine300, tr('重命名')),
      _menuItem('copyPath', LucideIcons.copy300, tr('复制远端路径')),
      const PopupMenuDivider(),
      _menuItem('delete', LucideIcons.trash300, tr('删除'), color: AppTheme.errorColor),
    ]);
    if (!mounted || action == null) return;
    switch (action) {
      case 'open':
        unawaited(_navigateRemote(_join(_remotePath, entry.name)));
      case 'edit':
        unawaited(_editRemoteFile(entry));
      case 'downloadHere':
        unawaited(
          _downloadToLocal(
            entry,
            remoteDir: _remotePath,
            targetDir: _localPath,
          ),
        );
      case 'downloadTo':
        unawaited(
          entry.isDir
              ? _downloadDirWithPicker(entry)
              : _downloadFileWithPicker(entry),
        );
      case 'rename':
        unawaited(_renameRemote(entry));
      case 'copyPath':
        unawaited(_copyPath(_join(_remotePath, entry.name)));
      case 'delete':
        unawaited(_deleteRemote(entry));
    }
  }

  Future<void> _showRemoteBackgroundMenu(Offset position) async {
    final action = await _showContextMenu<String>(position, [
      _menuItem('uploadFiles', LucideIcons.upload300, tr('上传文件…')),
      _menuItem('uploadDir', LucideIcons.folderUp300, tr('上传目录…')),
      _menuItem('mkdir', LucideIcons.folderPlus300, tr('新建目录')),
      const PopupMenuDivider(),
      _menuItem('refresh', LucideIcons.refreshCw300, tr('刷新')),
      _menuItem(
        'toggleHidden',
        _remoteShowHidden ? LucideIcons.eyeOff300 : LucideIcons.eye300,
        _remoteShowHidden ? tr('隐藏 . 开头文件') : tr('显示 . 开头文件'),
      ),
    ]);
    if (!mounted || action == null) return;
    switch (action) {
      case 'uploadFiles':
        unawaited(_uploadFilesWithPicker());
      case 'uploadDir':
        unawaited(_uploadDirWithPicker());
      case 'mkdir':
        unawaited(_makeRemoteDir());
      case 'refresh':
        unawaited(_refreshRemote());
      case 'toggleHidden':
        setState(() => _remoteShowHidden = !_remoteShowHidden);
    }
  }

  Future<void> _showLocalEntryMenu(Offset position, SftpEntry entry) async {
    if (_prepareContextSelection(_localSelect, entry.name)) {
      return _showMultiMenu(position, isRemote: false);
    }
    final action = await _showContextMenu<String>(position, [
      if (entry.isDir) _menuItem('open', LucideIcons.folder300, tr('打开')),
      _menuItem(
        'upload',
        entry.isDir ? LucideIcons.folderUp300 : LucideIcons.upload300,
        tr('上传到远端栏'),
      ),
      _menuItem('rename', LucideIcons.penLine300, tr('重命名')),
      _menuItem('copyPath', LucideIcons.copy300, tr('复制路径')),
      _menuItem('reveal', LucideIcons.eye300, tr('在 Finder 中显示')),
      const PopupMenuDivider(),
      _menuItem('delete', LucideIcons.trash300, tr('删除'), color: AppTheme.errorColor),
    ]);
    if (!mounted || action == null) return;
    switch (action) {
      case 'open':
        unawaited(_navigateLocal(_join(_localPath, entry.name)));
      case 'upload':
        unawaited(
          _uploadFromLocal(entry, localDir: _localPath, targetDir: _remotePath),
        );
      case 'rename':
        unawaited(_renameLocal(entry));
      case 'copyPath':
        unawaited(_copyPath(_join(_localPath, entry.name)));
      case 'reveal':
        _revealInFinder(_join(_localPath, entry.name));
      case 'delete':
        unawaited(_deleteLocal(entry));
    }
  }

  Future<void> _showLocalBackgroundMenu(Offset position) async {
    final action = await _showContextMenu<String>(position, [
      _menuItem('mkdir', LucideIcons.folderPlus300, tr('新建目录')),
      _menuItem('openFinder', LucideIcons.folder300, tr('在 Finder 中打开')),
      const PopupMenuDivider(),
      _menuItem('refresh', LucideIcons.refreshCw300, tr('刷新')),
      _menuItem(
        'toggleHidden',
        _localShowHidden ? LucideIcons.eyeOff300 : LucideIcons.eye300,
        _localShowHidden ? tr('隐藏 . 开头文件') : tr('显示 . 开头文件'),
      ),
    ]);
    if (!mounted || action == null) return;
    switch (action) {
      case 'mkdir':
        unawaited(_makeLocalDir());
      case 'openFinder':
        _openLocally(_localPath);
      case 'refresh':
        unawaited(_refreshLocal());
      case 'toggleHidden':
        setState(() => _localShowHidden = !_localShowHidden);
    }
  }

  // ── UI ──

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.surfaceColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _buildLocalPane()),
                VerticalDivider(width: 0.5, color: AppTheme.borderColor),
                Expanded(child: _buildRemotePane()),
              ],
            ),
          ),
          if (_edits.isNotEmpty) _buildEditsBar(),
          if (_transfers.isNotEmpty) _buildTransfersPanel(),
          _buildStatusBar(),
        ],
      ),
    );
  }

  Widget _buildEditsBar() {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.brandColor.withValues(alpha: 0.06),
        border: Border(top: BorderSide(color: AppTheme.borderColor)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      child: Row(
        children: [
          Icon(LucideIcons.filePen300, size: 12, color: AppTheme.brandColor),
          const SizedBox(width: 6),
          Text(
            tr('编辑中'),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AppTheme.subtleTextColor,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final s in _edits)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    label: Text(s.name, style: const TextStyle(fontSize: 11)),
                    labelStyle: TextStyle(color: AppTheme.headingColor),
                    backgroundColor: AppTheme.surfaceColor,
                    side: BorderSide(color: AppTheme.borderColor),
                    deleteIcon: Icon(
                      LucideIcons.x300,
                      size: 12,
                      color: AppTheme.subtleTextColor,
                    ),
                    onDeleted: () => _stopEdit(s),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLocalPane() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildLocalHeader(),
        if (_localLoading)
          LinearProgressIndicator(
            minHeight: 2,
            backgroundColor: Colors.transparent,
            color: AppTheme.brandColor,
          ),
        Expanded(child: _buildPaneBody(isRemote: false)),
      ],
    );
  }

  Widget _buildRemotePane() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildRemoteHeader(),
        if (_remoteLoading)
          LinearProgressIndicator(
            minHeight: 2,
            backgroundColor: Colors.transparent,
            color: AppTheme.brandColor,
          ),
        Expanded(child: _buildPaneBody(isRemote: true)),
      ],
    );
  }

  // ── 滑动多选:批量操作 ──

  /// 当前选中的条目(按列表顺序)
  List<SftpEntry> _selectedEntries({required bool isRemote}) {
    final select = isRemote ? _remoteSelect : _localSelect;
    final visible = isRemote ? _visibleRemote : _visibleLocal;
    return [
      for (final e in visible)
        if (select.contains(e.name)) e,
    ];
  }

  /// 批量传输:所选条目逐个入传输队列(与单项拖拽同一底座,可取消/重试)
  void _transferSelected({required bool isRemote}) {
    final entries = _selectedEntries(isRemote: isRemote);
    if (entries.isEmpty) return;
    for (final entry in entries) {
      if (isRemote) {
        unawaited(
          _downloadToLocal(entry, remoteDir: _remotePath, targetDir: _localPath),
        );
      } else {
        unawaited(
          _uploadFromLocal(entry, localDir: _localPath, targetDir: _remotePath),
        );
      }
    }
    (isRemote ? _remoteSelect : _localSelect).clear();
  }

  /// 批量删除:一次确认,逐项执行;中途失败停下并报错
  Future<void> _deleteSelected({required bool isRemote}) async {
    final entries = _selectedEntries(isRemote: isRemote);
    if (entries.isEmpty) return;
    final dirCount = entries.where((e) => e.isDir).length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr2('删除 {0} 项', [entries.length])),
        content: Text(
          [
            tr2('确定删除所选 {0} 项吗?', [entries.length]),
            if (dirCount > 0) tr2('(含 {0} 个目录,仅能删除空目录)', [dirCount]),
            '\n${entries.take(8).map((e) => e.name).join('、')}'
                '${entries.length > 8 ? tr(' 等…') : ''}',
          ].join(''),
        ),
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

    if (isRemote) {
      await _runRemoteOp(tr2('删除 {0} 项…', [entries.length]), () async {
        for (final entry in entries) {
          await _remoteRemove(_join(_remotePath, entry.name), entry.isDir);
        }
      });
    } else {
      await _runLocalOp(tr2('删除 {0} 项…', [entries.length]), () async {
        for (final entry in entries) {
          final path = _join(_localPath, entry.name);
          await (entry.isDir
              ? LocalFileService.removeDir(path)
              : LocalFileService.remove(path));
        }
      });
    }
  }

  Widget _buildLocalHeader() {
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
      ),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                Icon(
                  LucideIcons.hardDrive300,
                  size: 15,
                  color: AppTheme.brandColor,
                ),
                const SizedBox(width: 6),
                Text(
                  tr('本地文件'),
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.headingColor,
                  ),
                ),
                const SizedBox(width: 14),
                _headerAction(
                  tr('家目录'),
                  LucideIcons.house300,
                  _localLoading ? null : () => _navigateLocal(_localHome),
                ),
                _headerAction(
                  tr('上一级'),
                  LucideIcons.cornerLeftUp300,
                  _localLoading || _localPath == '/'
                      ? null
                      : () => _navigateLocal(_parentOf(_localPath)),
                ),
                _headerAction(
                  tr('刷新'),
                  LucideIcons.refreshCw300,
                  _localLoading ? null : _refreshLocal,
                ),
                _headerAction(
                  _localShowHidden ? tr('隐藏 . 开头文件') : tr('显示 . 开头文件'),
                  _localShowHidden ? LucideIcons.eyeOff300 : LucideIcons.eye300,
                  () => setState(() => _localShowHidden = !_localShowHidden),
                ),
                const SizedBox(width: 6),
                _headerAction(
                  tr('切换目录…'),
                  LucideIcons.folderSearch300,
                  _localLoading ? null : _pickLocalDirectory,
                ),
                _headerAction(
                  tr('新建目录'),
                  LucideIcons.folderPlus300,
                  _localLoading ? null : _makeLocalDir,
                ),
              ],
            ),
          ),
          const SizedBox(height: 5),
          _PathBar(
            path: _localPath,
            enabled: !_localLoading,
            onSubmit: _submitLocalPath,
          ),
        ],
      ),
    );
  }

  Widget _buildRemoteHeader() {
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
      ),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                Icon(LucideIcons.folder300, size: 15, color: AppTheme.brandColor),
                const SizedBox(width: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 160),
                  child: Text(
                    tr2('{0} 的文件', [widget.host.name]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.headingColor,
                    ),
                  ),
                ),
                if (_elevated) ...[
                  const SizedBox(width: 6),
                  Tooltip(
                    message: tr('已 sudo 提权(root)— 点击退出提权'),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(4),
                      onTap: _dropElevation,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.warningColor.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              LucideIcons.shieldCheck300,
                              size: 11,
                              color: AppTheme.warningColor,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              'root',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.warningColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(width: 12),
                _headerAction(
                  tr('家目录'),
                  LucideIcons.house300,
                  _remoteLoading || _remoteHome == null
                      ? null
                      : () => _navigateRemote(_remoteHome!),
                ),
                _headerAction(
                  tr('上一级'),
                  LucideIcons.cornerLeftUp300,
                  _remoteLoading || _remotePath == '/'
                      ? null
                      : () => _navigateRemote(_parentOf(_remotePath)),
                ),
                _headerAction(
                  tr('刷新'),
                  LucideIcons.refreshCw300,
                  _remoteLoading ? null : _refreshRemote,
                ),
                _headerAction(
                  _remoteShowHidden ? tr('隐藏 . 开头文件') : tr('显示 . 开头文件'),
                  _remoteShowHidden ? LucideIcons.eyeOff300 : LucideIcons.eye300,
                  () => setState(() => _remoteShowHidden = !_remoteShowHidden),
                ),
                if (!_elevated)
                  _headerAction(
                    tr('提权访问(sudo 或 su root)'),
                    LucideIcons.shieldCheck300,
                    () => unawaited(_elevate()),
                  ),
                const SizedBox(width: 6),
                _headerAction(
                  tr('上传文件…'),
                  LucideIcons.upload300,
                  _remoteLoading ? null : _uploadFilesWithPicker,
                ),
                _headerAction(
                  tr('上传目录…'),
                  LucideIcons.folderUp300,
                  _remoteLoading ? null : _uploadDirWithPicker,
                ),
                _headerAction(
                  tr('新建目录'),
                  LucideIcons.folderPlus300,
                  _remoteLoading ? null : _makeRemoteDir,
                ),
                const SizedBox(width: 4),
                _headerAction(tr('关闭文件面板'), LucideIcons.x300, widget.onClose),
              ],
            ),
          ),
          const SizedBox(height: 5),
          _PathBar(
            path: _remotePath,
            enabled: !_remoteLoading,
            onSubmit: _submitRemotePath,
          ),
        ],
      ),
    );
  }

  Widget _headerAction(String tooltip, IconData icon, VoidCallback? onPressed) {
    return SizedBox(
      width: 26,
      height: 26,
      child: IconButton(
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        splashRadius: 13,
        icon: Icon(
          icon,
          size: 14,
          color: onPressed == null
              ? AppTheme.subtleTextColor.withValues(alpha: 0.4)
              : AppTheme.subtleTextColor,
        ),
        onPressed: onPressed,
      ),
    );
  }

  /// 整栏是一个 DragTarget:对面栏条目拖进来 = 传到该栏当前目录。
  /// 目录行自己也是 DragTarget(拖进那个目录),命中目录行时这里不亮。
  /// 远端栏还套一层系统级 DropTarget,接 Finder 拖进来的文件/目录。
  Widget _buildPaneBody({required bool isRemote}) {
    final body = _buildPaneDragTarget(isRemote: isRemote);
    if (!isRemote) return body;
    return DropTarget(
      onDragEntered: (_) => setState(() => _osDropActive = true),
      onDragExited: (_) => setState(() => _osDropActive = false),
      onDragDone: (detail) {
        setState(() => _osDropActive = false);
        _handleOsDrop(detail);
      },
      child: body,
    );
  }

  Widget _buildPaneDragTarget({required bool isRemote}) {
    return DragTarget<_DragPayload>(
      onWillAcceptWithDetails: (details) =>
          details.data.fromRemote != isRemote,
      onAcceptWithDetails: (details) {
        final p = details.data;
        if (isRemote) {
          unawaited(
            _uploadFromLocal(p.entry, localDir: p.dir, targetDir: _remotePath),
          );
        } else {
          unawaited(
            _downloadToLocal(p.entry, remoteDir: p.dir, targetDir: _localPath),
          );
        }
      },
      builder: (context, candidates, rejected) {
        final active =
            candidates.isNotEmpty || (isRemote && _osDropActive);
        return Container(
          decoration: active
              ? BoxDecoration(
                  color: AppTheme.brandColor.withValues(alpha: 0.05),
                  border: Border.all(
                    color: AppTheme.brandColor.withValues(alpha: 0.6),
                  ),
                )
              : null,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            // 用 TapUp(经手势竞技场裁决)而非 TapDown(按下即触发):点在行上时
            // 让最内层的行菜单胜出,不会连背景菜单一起弹两个
            onSecondaryTapUp: (details) => unawaited(
              isRemote
                  ? _showRemoteBackgroundMenu(details.globalPosition)
                  : _showLocalBackgroundMenu(details.globalPosition),
            ),
            child: _buildEntryList(isRemote: isRemote),
          ),
        );
      },
    );
  }

  /// 权限拒绝的空态:说明 + 提权按钮
  Widget _buildElevationPrompt() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              LucideIcons.lock300,
              size: 26,
              color: AppTheme.subtleTextColor.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 12),
            Text(
              tr('没有权限访问该目录'),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppTheme.headingColor,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              tr('SFTP 以登录用户身份运行。提权后可以 root 浏览/下载(sudo 或 su root 密码)。'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.5,
                color: AppTheme.subtleTextColor,
              ),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.brandColor,
                visualDensity: VisualDensity.compact,
              ),
              onPressed: () => unawaited(_elevate()),
              icon: const Icon(LucideIcons.shieldCheck300, size: 14),
              label: Text(tr('提权访问'), style: TextStyle(fontSize: 12.5)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEntryList({required bool isRemote}) {
    final entries = isRemote ? _visibleRemote : _visibleLocal;
    if (isRemote && _remoteNeedsElevation && !_remoteLoading) {
      return _buildElevationPrompt();
    }
    if (entries.isEmpty) {
      final loading = isRemote ? _remoteLoading : _localLoading;
      final error = isRemote ? _remoteError : _localError;
      final all = isRemote ? _remoteEntries : _localEntries;
      return Center(
        child: Text(
          loading
              ? tr('加载中…')
              : error != null
              ? tr('加载失败,详见底部信息')
              : all.isEmpty
              ? tr('空目录')
              : tr('仅有隐藏文件(眼睛图标可显示)'),
          style: TextStyle(fontSize: 12.5, color: AppTheme.subtleTextColor),
        ),
      );
    }
    final dir = isRemote ? _remotePath : _localPath;
    final select = isRemote ? _remoteSelect : _localSelect;
    return SlideSelectArea<String>(
      controller: select,
      items: () => [
        for (final e in (isRemote ? _visibleRemote : _visibleLocal)) e.name,
      ],
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: entries.length,
        itemBuilder: (context, index) {
          final entry = entries[index];
          return SlideSelectItem<String>(
            controller: select,
            index: index,
            child: _buildEntryRow(
              entry: entry,
              isRemote: isRemote,
              dir: dir,
              selected: select.contains(entry.name),
            ),
          );
        },
      ),
    );
  }

  Widget _buildEntryRow({
    required SftpEntry entry,
    required bool isRemote,
    required String dir,
    required bool selected,
  }) {
    return _EntryRow(
          entry: entry,
          selected: selected,
          payload: _DragPayload(fromRemote: isRemote, entry: entry, dir: dir),
          onOpen: entry.isDir
              ? () => isRemote
                    ? _navigateRemote(_join(dir, entry.name))
                    : _navigateLocal(_join(dir, entry.name))
              : isRemote
              ? null
              : () => _openLocally(_join(dir, entry.name)),
          transferTooltip: isRemote ? tr('下载到本地栏') : tr('上传到远端栏'),
          transferIcon: isRemote
              ? LucideIcons.download300
              : LucideIcons.upload300,
          onTransfer: () => isRemote
              ? _downloadToLocal(entry, remoteDir: dir, targetDir: _localPath)
              : _uploadFromLocal(entry, localDir: dir, targetDir: _remotePath),
          onRename: () => isRemote ? _renameRemote(entry) : _renameLocal(entry),
          onDelete: () => isRemote ? _deleteRemote(entry) : _deleteLocal(entry),
          onContextMenu: (position) => isRemote
              ? _showRemoteEntryMenu(position, entry)
              : _showLocalEntryMenu(position, entry),
          onAcceptDrop: entry.isDir
              ? (p) {
                  final target = _join(dir, entry.name);
                  if (isRemote) {
                    unawaited(
                      _uploadFromLocal(
                        p.entry,
                        localDir: p.dir,
                        targetDir: target,
                      ),
                    );
                  } else {
                    unawaited(
                      _downloadToLocal(
                        p.entry,
                        remoteDir: p.dir,
                        targetDir: target,
                      ),
                    );
                  }
                }
              : null,
    );
  }

  Widget _buildTransfersPanel() {
    final running =
        _transfers.where((t) => t.state == _TransferState.running).length;
    return Container(
      constraints: const BoxConstraints(maxHeight: 168),
      decoration: BoxDecoration(
        color: AppTheme.subtleSurfaceColor.withValues(alpha: 0.3),
        border: Border(top: BorderSide(color: AppTheme.borderColor)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 4, 0),
            child: Row(
              children: [
                Text(
                  running > 0 ? tr2('传输中 {0} 项', [running]) : tr('传输记录'),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.subtleTextColor,
                  ),
                ),
                const Spacer(),
                if (_transfers.any((t) => t.state != _TransferState.running))
                  TextButton(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    onPressed: _clearFinishedTransfers,
                    child: Text(
                      tr('清除已完成'),
                      style: TextStyle(
                        fontSize: 11,
                        color: AppTheme.subtleTextColor,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(10, 2, 10, 6),
              itemCount: _transfers.length,
              itemBuilder: (context, index) =>
                  _buildTransferRow(_transfers[index]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTransferRow(_Transfer transfer) {
    final Color stateColor;
    switch (transfer.state) {
      case _TransferState.done:
        stateColor = AppTheme.successColor;
      case _TransferState.failed:
        stateColor = AppTheme.errorColor;
      case _TransferState.cancelled:
        stateColor = AppTheme.subtleTextColor;
      case _TransferState.running:
        stateColor = AppTheme.brandColor;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            transfer.isUpload
                ? LucideIcons.upload300
                : LucideIcons.download300,
            size: 12,
            color: stateColor,
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 150,
            child: Tooltip(
              message: transfer.error ?? transfer.label,
              waitDuration: const Duration(milliseconds: 500),
              child: Text(
                transfer.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: AppTheme.headingColor),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                minHeight: 4,
                value: transfer.state == _TransferState.running
                    ? transfer.progress
                    : (transfer.state == _TransferState.done ? 1.0 : 0.0),
                backgroundColor: AppTheme.borderColor.withValues(alpha: 0.5),
                color: stateColor,
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 44,
            child: Text(
              transfer.progressLabel,
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 10.5, color: stateColor),
            ),
          ),
          SizedBox(
            width: 22,
            height: 22,
            child: transfer.state == _TransferState.running
                ? IconButton(
                    tooltip: tr('取消'),
                    padding: EdgeInsets.zero,
                    splashRadius: 11,
                    icon: Icon(
                      LucideIcons.circleX300,
                      size: 12,
                      color: AppTheme.subtleTextColor,
                    ),
                    onPressed: () => _cancelTransfer(transfer),
                  )
                : (transfer.state == _TransferState.failed ||
                          transfer.state == _TransferState.cancelled) &&
                      transfer.starter != null
                ? IconButton(
                    tooltip: tr('重试'),
                    padding: EdgeInsets.zero,
                    splashRadius: 11,
                    icon: Icon(
                      LucideIcons.refreshCw300,
                      size: 12,
                      color: AppTheme.subtleTextColor,
                    ),
                    onPressed: () => _retryTransfer(transfer),
                  )
                : null,
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBar() {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.subtleSurfaceColor.withValues(alpha: 0.4),
        border: Border(top: BorderSide(color: AppTheme.borderColor)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Text(
        _status,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11,
          color: _statusIsError ? AppTheme.errorColor : AppTheme.subtleTextColor,
        ),
      ),
    );
  }
}

/// 一行条目:可拖到对面栏;目录行还能接住对面栏拖来的条目。
class _EntryRow extends StatefulWidget {
  const _EntryRow({
    required this.entry,
    this.selected = false,
    required this.payload,
    required this.onOpen,
    required this.transferTooltip,
    required this.transferIcon,
    required this.onTransfer,
    required this.onRename,
    required this.onDelete,
    required this.onContextMenu,
    this.onAcceptDrop,
  });

  final SftpEntry entry;

  /// 滑动多选的选中态(高亮 + 左侧品牌色竖条)
  final bool selected;
  final _DragPayload payload;
  final VoidCallback? onOpen;
  final String transferTooltip;
  final IconData transferIcon;
  final VoidCallback onTransfer;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final ValueChanged<Offset> onContextMenu;

  /// 非 null(目录行)时接住对面栏拖来的条目,传进这个目录
  final ValueChanged<_DragPayload>? onAcceptDrop;

  @override
  State<_EntryRow> createState() => _EntryRowState();
}

class _EntryRowState extends State<_EntryRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final onAcceptDrop = widget.onAcceptDrop;
    if (onAcceptDrop == null) return _buildDraggable(dropActive: false);
    return DragTarget<_DragPayload>(
      onWillAcceptWithDetails: (details) =>
          details.data.fromRemote != widget.payload.fromRemote,
      onAcceptWithDetails: (details) => onAcceptDrop(details.data),
      builder: (context, candidates, rejected) =>
          _buildDraggable(dropActive: candidates.isNotEmpty),
    );
  }

  Widget _buildDraggable({required bool dropActive}) {
    final row = _buildRow(dropActive: dropActive);
    return Draggable<_DragPayload>(
      data: widget.payload,
      // 只认水平拖动:垂直方向留给列表的滑动多选(SlideSelectArea)
      affinity: Axis.horizontal,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: _buildDragFeedback(),
      childWhenDragging: Opacity(opacity: 0.45, child: row),
      child: row,
    );
  }

  Widget _buildRow({required bool dropActive}) {
    final entry = widget.entry;
    final icon = entry.isDir
        ? LucideIcons.folder300
        : entry.isLink
        ? LucideIcons.link300
        : LucideIcons.file300;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onSecondaryTapUp: (details) =>
            widget.onContextMenu(details.globalPosition),
        child: Material(
          color: dropActive
              ? AppTheme.brandColor.withValues(alpha: 0.12)
              : widget.selected
              ? AppTheme.brandColor.withValues(alpha: 0.10)
              : _hovered
              ? AppTheme.subtleSurfaceColor.withValues(alpha: 0.6)
              : Colors.transparent,
          child: InkWell(
            onDoubleTap: widget.onOpen,
            onTap: () {},
            child: Container(
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                    width: 2,
                    color: widget.selected
                        ? AppTheme.brandColor
                        : Colors.transparent,
                  ),
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              child: Row(
                children: [
                  Icon(
                    icon,
                    size: 14,
                    color: entry.isDir
                        ? AppTheme.brandColor
                        : AppTheme.subtleTextColor,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      entry.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: AppTheme.headingColor,
                      ),
                    ),
                  ),
                  if (_hovered) ...[
                    _rowAction(
                      widget.transferTooltip,
                      widget.transferIcon,
                      widget.onTransfer,
                      color: AppTheme.brandColor,
                    ),
                    _rowAction(tr('重命名'), LucideIcons.penLine300, widget.onRename),
                    _rowAction(
                      tr('删除'),
                      LucideIcons.trash300,
                      widget.onDelete,
                      color: AppTheme.errorColor,
                    ),
                    const SizedBox(width: 6),
                  ],
                  SizedBox(
                    width: 72,
                    child: Text(
                      entry.sizeLabel,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: 11,
                        color: AppTheme.subtleTextColor,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  SizedBox(
                    width: 96,
                    child: Text(
                      entry.modified,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: AppTheme.subtleTextColor,
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

  /// 拖拽跟随指针的小卡片
  Widget _buildDragFeedback() {
    final entry = widget.entry;
    final icon = entry.isDir
        ? LucideIcons.folder300
        : entry.isLink
        ? LucideIcons.link300
        : LucideIcons.file300;
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: AppTheme.surfaceColor.withValues(alpha: 0.95),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: AppTheme.brandColor.withValues(alpha: 0.6),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 8,
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: AppTheme.brandColor),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Text(
                entry.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  color: AppTheme.headingColor,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _rowAction(
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
        splashRadius: 12,
        icon: Icon(icon, size: 13, color: color ?? AppTheme.subtleTextColor),
        onPressed: onPressed,
      ),
    );
  }
}

/// 头部地址栏:显示当前路径、可直接编辑,回车跳转;
/// Esc/失焦恢复原值,外部导航后自动同步显示。
class _PathBar extends StatefulWidget {
  const _PathBar({
    required this.path,
    required this.enabled,
    required this.onSubmit,
  });

  final String path;
  final bool enabled;
  final ValueChanged<String> onSubmit;

  @override
  State<_PathBar> createState() => _PathBarState();
}

class _PathBarState extends State<_PathBar> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.path,
  );
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() {
      // 失焦 = 放弃编辑,恢复当前路径
      if (!_focusNode.hasFocus) _controller.text = widget.path;
      setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant _PathBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 导航成功(双击目录/上一级/家目录/回车)后同步成规范路径
    if (widget.path != oldWidget.path) _controller.text = widget.path;
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          _controller.text = widget.path;
          _focusNode.unfocus();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: SizedBox(
        height: 24,
        child: TextField(
          controller: _controller,
          focusNode: _focusNode,
          enabled: widget.enabled,
          maxLines: 1,
          cursorHeight: 12,
          style: TextStyle(
            fontSize: 11.5,
            color: _focusNode.hasFocus
                ? AppTheme.headingColor
                : AppTheme.subtleTextColor,
            fontFamily: 'Menlo',
          ),
          decoration: InputDecoration(
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 8,
              vertical: 4,
            ),
            filled: true,
            fillColor: _focusNode.hasFocus
                ? AppTheme.subtleSurfaceColor.withValues(alpha: 0.6)
                : Colors.transparent,
            hoverColor: AppTheme.subtleSurfaceColor.withValues(alpha: 0.35),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: BorderSide(
                color: AppTheme.borderColor.withValues(alpha: 0.6),
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: BorderSide(color: AppTheme.brandColor),
            ),
            disabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: BorderSide(
                color: AppTheme.borderColor.withValues(alpha: 0.3),
              ),
            ),
          ),
          onSubmitted: (value) {
            final path = value.trim();
            if (path.isEmpty || path == widget.path) {
              _controller.text = widget.path;
              return;
            }
            widget.onSubmit(path);
          },
        ),
      ),
    );
  }
}
