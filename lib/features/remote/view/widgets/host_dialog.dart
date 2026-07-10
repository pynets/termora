import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:termora/app/theme/app_theme.dart';
import 'package:termora/core/utils/file_picker_helper.dart';
import 'package:termora/features/remote/domain/ssh_host.dart';
import 'package:termora/core/l10n/app_l10n.dart';

/// 打开主机配置弹窗。返回保存后的配置(取消返回 null)。
/// [groups] 为已有分组名,供分组输入框自动补全。
Future<SshHost?> showSshHostDialog(
  BuildContext context, {
  SshHost? existing,
  List<String> groups = const [],
}) {
  return showDialog<SshHost>(
    context: context,
    builder: (context) => _SshHostDialog(existing: existing, groups: groups),
  );
}

class _SshHostDialog extends StatefulWidget {
  const _SshHostDialog({this.existing, this.groups = const []});

  final SshHost? existing;
  final List<String> groups;

  @override
  State<_SshHostDialog> createState() => _SshHostDialogState();
}

class _SshHostDialogState extends State<_SshHostDialog> {
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _user;
  late final TextEditingController _keyPath;
  late final TextEditingController _extraArgs;
  late final TextEditingController _group;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _host = TextEditingController(text: e?.host ?? '');
    _port = TextEditingController(text: '${e?.port ?? 22}');
    _user = TextEditingController(text: e?.user ?? '');
    _keyPath = TextEditingController(text: e?.keyPath ?? '');
    _extraArgs = TextEditingController(text: e?.extraArgs ?? '');
    _group = TextEditingController(text: e?.group ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _user.dispose();
    _keyPath.dispose();
    _extraArgs.dispose();
    _group.dispose();
    super.dispose();
  }

  SshHost _buildHost() {
    final host = _host.text.trim();
    final user = _user.text.trim();
    final fallbackName = user.isEmpty ? host : '$user@$host';
    return SshHost(
      id:
          widget.existing?.id ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      name: _name.text.trim().isEmpty ? fallbackName : _name.text.trim(),
      host: host,
      port: int.tryParse(_port.text.trim()) ?? 22,
      user: user,
      keyPath: _keyPath.text.trim(),
      extraArgs: _extraArgs.text.trim(),
      group: _group.text.trim(),
    );
  }

  Future<void> _pickKeyFile() async {
    final initialDirectory = await FilePickerHelper.getInitialDirectory();
    final result = await FilePicker.pickFiles(
      dialogTitle: tr('选择 SSH 私钥'),
      initialDirectory: initialDirectory,
    );
    final path = result?.files.firstOrNull?.path;
    if (path == null || path.isEmpty || !mounted) return;
    FilePickerHelper.updateLastDirectory(path);
    setState(() => _keyPath.text = path);
  }

  void _save() {
    if (_host.text.trim().isEmpty) return;
    Navigator.of(context).pop(_buildHost());
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    LucideIcons.server300,
                    size: 18,
                    color: AppTheme.brandColor,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    widget.existing == null ? tr('新建主机') : tr('编辑主机'),
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.headingColor,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _field(tr('名称'), _name, hint: tr('默认 user@host')),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(flex: 3, child: _field(tr('主机'), _host, hint: tr('必填'))),
                  const SizedBox(width: 10),
                  Expanded(child: _field(tr('端口'), _port)),
                ],
              ),
              const SizedBox(height: 10),
              _field(tr('用户'), _user, hint: tr('留空用本机用户名')),
              const SizedBox(height: 10),
              _field(
                tr('私钥'),
                _keyPath,
                hint: tr('留空走 ~/.ssh 默认或密码登录'),
                suffix: IconButton(
                  tooltip: tr('选择私钥文件'),
                  icon: Icon(
                    LucideIcons.folderOpen300,
                    size: 15,
                    color: AppTheme.subtleTextColor,
                  ),
                  splashRadius: 14,
                  onPressed: () {
                    // 不 await:选择器是独立流程,回来后 setState 更新
                    _pickKeyFile();
                  },
                ),
              ),
              const SizedBox(height: 10),
              _field(tr('附加参数'), _extraArgs, hint: tr('如 -J jump@bastion')),
              const SizedBox(height: 10),
              _groupField(),
              const SizedBox(height: 12),
              _passwordHint(),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(tr('取消')),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.brandColor,
                    ),
                    onPressed: _save,
                    child: Text(tr('保存')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 说明密码登录的用法(系统 OpenSSH 不接受存储密码,只能交互输入)
  Widget _passwordHint() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.subtleSurfaceColor.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.keyRound300, size: 14, color: AppTheme.subtleTextColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              tr(
                '密码登录:私钥留空,点「连接」后在终端里输入密码即可。'
                '首次连上后 SFTP / 文件面板会自动复用该连接(免再输密码)。',
              ),
              style: TextStyle(
                fontSize: 11.5,
                height: 1.5,
                color: AppTheme.subtleTextColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 分组输入:自由填写 + 从已有分组里快速选。
  Widget _groupField() {
    return _field(
      tr('分组'),
      _group,
      hint: tr('留空=未分组,如 生产 / 测试'),
      suffix: widget.groups.isEmpty
          ? null
          : PopupMenuButton<String>(
              tooltip: tr('选择已有分组'),
              icon: Icon(
                LucideIcons.chevronDown300,
                size: 15,
                color: AppTheme.subtleTextColor,
              ),
              splashRadius: 14,
              onSelected: (g) => setState(() => _group.text = g),
              itemBuilder: (context) => [
                for (final g in widget.groups)
                  PopupMenuItem(value: g, child: Text(g)),
              ],
            ),
    );
  }

  Widget _field(
    String label,
    TextEditingController controller, {
    String? hint,
    Widget? suffix,
  }) {
    return TextField(
      controller: controller,
      style: TextStyle(fontSize: 13, color: AppTheme.headingColor),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        hintStyle: TextStyle(
          fontSize: 12,
          color: AppTheme.subtleTextColor.withValues(alpha: 0.7),
        ),
        suffixIcon: suffix,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      onSubmitted: (_) => _save(),
    );
  }
}
