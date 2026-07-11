import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:termora/app/theme/app_theme.dart';
import 'package:termora/core/utils/file_picker_helper.dart';
import 'package:termora/core/widgets/glass_menu.dart';
import 'package:termora/features/database/data/db_service.dart';
import 'package:termora/features/database/domain/db_models.dart';
import 'package:termora/core/l10n/app_l10n.dart';

/// 打开连接配置弹窗。返回保存后的配置(取消返回 null)。
Future<DbConnectionConfig?> showConnectionDialog(
  BuildContext context, {
  DbConnectionConfig? existing,
}) {
  return showDialog<DbConnectionConfig>(
    context: context,
    useRootNavigator: false,
    barrierColor: Colors.black.withValues(alpha: 0.3),
    builder: (context) => _ConnectionDialog(existing: existing),
  );
}

class _ConnectionDialog extends StatefulWidget {
  const _ConnectionDialog({this.existing});

  final DbConnectionConfig? existing;

  @override
  State<_ConnectionDialog> createState() => _ConnectionDialogState();
}

class _ConnectionDialogState extends State<_ConnectionDialog> {
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _database;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _sslClientCertPath;
  late final TextEditingController _sslClientKeyPath;
  late final TextEditingController _sslRootCertPath;
  late bool _useSsl;
  late int _sslAuthMode;
  late DbEngine _engine;
  bool _obscurePassword = true;
  final ScrollController _scrollController = ScrollController();

  bool _testing = false;
  String? _testResult;
  bool _testOk = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _engine = e?.engine ?? DbEngine.postgres;
    _name = TextEditingController(text: e?.name ?? '');
    _host = TextEditingController(text: e?.host ?? 'localhost');
    _port = TextEditingController(text: '${e?.port ?? _engine.defaultPort}');
    _database = TextEditingController(
      text: e?.database ?? _engine.defaultDatabase,
    );
    _username = TextEditingController(text: e?.username ?? _engine.defaultUser);
    _password = TextEditingController(text: e?.password ?? '');
    _sslClientCertPath = TextEditingController(
      text: e?.sslClientCertPath ?? '',
    );
    _sslClientKeyPath = TextEditingController(text: e?.sslClientKeyPath ?? '');
    _sslRootCertPath = TextEditingController(text: e?.sslRootCertPath ?? '');
    _useSsl = e?.useSsl ?? false;
    if ((e?.sslClientCertPath?.isNotEmpty == true) ||
        (e?.sslClientKeyPath?.isNotEmpty == true)) {
      _sslAuthMode = 2;
    } else if (e?.sslRootCertPath?.isNotEmpty == true) {
      _sslAuthMode = 1;
    } else {
      _sslAuthMode = 0;
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _database.dispose();
    _username.dispose();
    _password.dispose();
    _sslClientCertPath.dispose();
    _sslClientKeyPath.dispose();
    _sslRootCertPath.dispose();
    super.dispose();
  }

  DbConnectionConfig _buildConfig() {
    if (_engine.isFileBased) {
      final path = _database.text.trim();
      final fileName = path.split('/').last;
      return DbConnectionConfig(
        id:
            widget.existing?.id ??
            DateTime.now().microsecondsSinceEpoch.toString(),
        name: _name.text.trim().isEmpty
            ? (fileName.isEmpty ? _engine.label : fileName)
            : _name.text.trim(),
        engine: _engine,
        host: '',
        port: 0,
        database: path,
        username: '',
        password: '',
      );
    }

    final host = _host.text.trim();
    final database = _database.text.trim();
    final fallbackName = '$database@$host';
    return DbConnectionConfig(
      id:
          widget.existing?.id ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      name: _name.text.trim().isEmpty ? fallbackName : _name.text.trim(),
      engine: _engine,
      host: host.isEmpty ? 'localhost' : host,
      port: int.tryParse(_port.text.trim()) ?? _engine.defaultPort,
      database: database.isEmpty ? _engine.defaultDatabase : database,
      username: _username.text.trim(),
      password: _password.text,
      useSsl: _useSsl,
      sslClientCertPath:
          (_engine == DbEngine.postgres &&
                  _useSsl &&
                  _sslAuthMode == 2 &&
                  _sslClientCertPath.text.trim().isNotEmpty)
              ? _sslClientCertPath.text.trim()
              : null,
      sslClientKeyPath:
          (_engine == DbEngine.postgres &&
                  _useSsl &&
                  _sslAuthMode == 2 &&
                  _sslClientKeyPath.text.trim().isNotEmpty)
              ? _sslClientKeyPath.text.trim()
              : null,
      sslRootCertPath:
          (_engine == DbEngine.postgres &&
                  _useSsl &&
                  (_sslAuthMode == 1 || _sslAuthMode == 2) &&
                  _sslRootCertPath.text.trim().isNotEmpty)
              ? _sslRootCertPath.text.trim()
              : null,
    );
  }

  /// 切换引擎:把仍是上一引擎默认值的字段更新为新引擎默认(用户改过的不动)
  void _onEngineChanged(DbEngine next) {
    if (next == _engine) return;
    final prev = _engine;
    setState(() {
      if (_port.text.trim() == '${prev.defaultPort}') {
        _port.text = '${next.defaultPort}';
      }
      if (_database.text.trim() == prev.defaultDatabase) {
        _database.text = next.defaultDatabase;
      }
      if (_username.text.trim() == prev.defaultUser) {
        _username.text = next.defaultUser;
      }
      _engine = next;
    });
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    try {
      final config = _buildConfig();
      final version = await DbService.testConnection(config);
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testOk = true;
        _testResult = tr2('连接成功 · {0} {1}', [config.engine.label, version]);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testOk = false;
        _testResult = tr2('连接失败: {0}', [e]);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isMtls = _useSsl && _sslAuthMode == 2;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 540),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    LucideIcons.database,
                    size: 18,
                    color: AppTheme.brandColor,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    widget.existing == null ? tr('新建连接') : tr('编辑连接'),
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.headingColor,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // 第一行：类型 + 连接名称
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 165,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          tr('类型'),
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.subtleTextColor,
                          ),
                        ),
                        const SizedBox(height: 4),
                        GlassDropdownButton<DbEngine>(
                          value: _engine,
                          items: [
                            for (final e in DbEngine.values)
                              GlassDropdownMenuItem(
                                value: e,
                                child: Row(
                                  children: [
                                    Icon(
                                      switch (e) {
                                        DbEngine.postgres =>
                                          LucideIcons.database,
                                        DbEngine.clickhouse =>
                                          LucideIcons.server,
                                        DbEngine.sqlite => LucideIcons.file,
                                      },
                                      size: 15,
                                      color: AppTheme.brandColor,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      e.label,
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                        color: AppTheme.headingColor,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                          onChanged: (e) {
                            if (e != null) _onEngineChanged(e);
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _field(
                      tr('连接名称'),
                      _name,
                      hint:
                          _engine.isFileBased
                              ? tr('默认: 文件名')
                              : tr('默认: 数据库@主机'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (_engine.isFileBased)
                _field(
                  tr('数据库文件'),
                  _database,
                  hint: tr('选择 .db / .sqlite 文件'),
                  suffix: IconButton(
                    tooltip: tr('选择数据库文件'),
                    icon: Icon(
                      LucideIcons.folderOpen300,
                      size: 15,
                      color: AppTheme.subtleTextColor,
                    ),
                    splashRadius: 14,
                    onPressed:
                        () => _pickFile(
                          _database,
                          tr('选择 SQLite 数据库文件'),
                        ),
                  ),
                ),
              if (!_engine.isFileBased) ...[
                // 第二行：主机 + 端口 + 数据库
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 5, child: _field(tr('主机'), _host)),
                    const SizedBox(width: 10),
                    SizedBox(width: 85, child: _field(tr('端口'), _port)),
                    const SizedBox(width: 10),
                    Expanded(flex: 4, child: _field(tr('数据库'), _database)),
                  ],
                ),
                const SizedBox(height: 10),
                // 第三行：用户名 + 密码
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _field(tr('用户名'), _username)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _field(
                        tr('密码'),
                        _password,
                        hint: isMtls ? tr('选填，使用双向证书 mTLS 时可留空') : null,
                        obscure: _obscurePassword,
                        suffix: IconButton(
                          icon: Icon(
                            _obscurePassword
                                ? LucideIcons.eye
                                : LucideIcons.eyeOff,
                            size: 14,
                            color: AppTheme.subtleTextColor,
                          ),
                          onPressed:
                              () => setState(
                                () => _obscurePassword = !_obscurePassword,
                              ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                // 第四行：SSL 卡片（把验证方式下拉选项嵌入到同一横向行中，点击开关不会导致弹窗高度剧震）
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceColor.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppTheme.borderColor),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        height: 38,
                        child: Row(
                          children: [
                            Icon(
                              LucideIcons.shieldCheck,
                              size: 15,
                              color:
                                  _useSsl
                                      ? AppTheme.brandColor
                                      : AppTheme.subtleTextColor,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _engine == DbEngine.clickhouse
                                  ? 'HTTPS (SSL)'
                                  : tr('SSL / TLS 加密'),
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w500,
                                color: AppTheme.headingColor,
                              ),
                            ),
                            if (_useSsl &&
                                _engine == DbEngine.postgres) ...[
                              const SizedBox(width: 12),
                              Expanded(
                                child: GlassDropdownButton<int>(
                                  value: _sslAuthMode,
                                  items: const [
                                    GlassDropdownMenuItem(
                                      value: 0,
                                      child: Text(
                                        '默认 / 仅加密传输 (Require)',
                                        style: TextStyle(fontSize: 12),
                                      ),
                                    ),
                                    GlassDropdownMenuItem(
                                      value: 1,
                                      child: Text(
                                        '验证 CA 根证书 (Verify CA)',
                                        style: TextStyle(fontSize: 12),
                                      ),
                                    ),
                                    GlassDropdownMenuItem(
                                      value: 2,
                                      child: Text(
                                        '双向证书认证 (Client Cert / mTLS)',
                                        style: TextStyle(fontSize: 12),
                                      ),
                                    ),
                                  ],
                                  onChanged: (v) {
                                    if (v != null) {
                                      setState(() => _sslAuthMode = v);
                                    }
                                  },
                                ),
                              ),
                              const SizedBox(width: 8),
                            ] else ...[
                              const Spacer(),
                            ],
                            SizedBox(
                              height: 24,
                              child: FittedBox(
                                fit: BoxFit.contain,
                                child: Switch(
                                  value: _useSsl,
                                  onChanged:
                                      (v) => setState(() => _useSsl = v),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (_useSsl &&
                          _engine == DbEngine.postgres &&
                          (_sslAuthMode == 1 || _sslAuthMode == 2)) ...[
                        const SizedBox(height: 10),
                        _field(
                          tr('根证书 (CA Root Cert)'),
                          _sslRootCertPath,
                          hint: tr('选填，验证自签或私有 CA 根证书'),
                          suffix: IconButton(
                            tooltip: tr('选择根证书文件'),
                            icon: Icon(
                              LucideIcons.folderOpen300,
                              size: 15,
                              color: AppTheme.subtleTextColor,
                            ),
                            splashRadius: 14,
                            onPressed:
                                () => _pickFile(
                                  _sslRootCertPath,
                                  tr('选择 CA 根证书'),
                                ),
                          ),
                        ),
                      ],
                      if (_useSsl &&
                          _engine == DbEngine.postgres &&
                          _sslAuthMode == 2) ...[
                        const SizedBox(height: 10),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: _field(
                                tr('客户端证书 (Client Cert)'),
                                _sslClientCertPath,
                                hint: tr('必填，用于客户端双向认证'),
                                suffix: IconButton(
                                  tooltip: tr('选择客户端证书文件'),
                                  icon: Icon(
                                    LucideIcons.folderOpen300,
                                    size: 15,
                                    color: AppTheme.subtleTextColor,
                                  ),
                                  splashRadius: 14,
                                  onPressed:
                                      () => _pickFile(
                                        _sslClientCertPath,
                                        tr('选择客户端证书'),
                                      ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _field(
                                tr('客户端私钥 (Client Key)'),
                                _sslClientKeyPath,
                                hint: tr('必填，配套私钥'),
                                suffix: IconButton(
                                  tooltip: tr('选择客户端私钥文件'),
                                  icon: Icon(
                                    LucideIcons.folderOpen300,
                                    size: 15,
                                    color: AppTheme.subtleTextColor,
                                  ),
                                  splashRadius: 14,
                                  onPressed:
                                      () => _pickFile(
                                        _sslClientKeyPath,
                                        tr('选择客户端私钥'),
                                      ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 14),
              if (_testResult != null) ...[
                Text(
                  _testResult!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color:
                        _testOk
                            ? AppTheme.successColor
                            : AppTheme.errorColor,
                  ),
                ),
                const SizedBox(height: 8),
              ],
              Row(
                children: [
                  TextButton.icon(
                    onPressed: _testing ? null : _test,
                    icon:
                        _testing
                            ? const SizedBox(
                              width: 13,
                              height: 13,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                              ),
                            )
                            : const Icon(LucideIcons.plugZap, size: 14),
                    label: Text(tr('测试连接')),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(tr('取消')),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(_buildConfig()),
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

  Widget _field(
    String label,
    TextEditingController controller, {
    String? hint,
    bool obscure = false,
    Widget? suffix,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: AppTheme.subtleTextColor,
          ),
        ),
        const SizedBox(height: 4),
        SizedBox(
          height: 38,
          child: TextField(
            controller: controller,
            obscureText: obscure,
            style: TextStyle(fontSize: 13, color: AppTheme.headingColor),
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 10,
              ),
              hintText: hint,
              hintStyle: TextStyle(
                fontSize: 12.5,
                color: AppTheme.subtleTextColor.withValues(alpha: 0.7),
              ),
              suffixIcon: suffix,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: AppTheme.borderColor),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: AppTheme.borderColor),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _pickFile(
    TextEditingController controller,
    String title,
  ) async {
    final initialDirectory = await FilePickerHelper.getInitialDirectory();
    final result = await FilePicker.pickFiles(
      dialogTitle: title,
      initialDirectory: initialDirectory,
    );
    final path = result?.files.firstOrNull?.path;
    if (path == null || path.isEmpty || !mounted) return;
    FilePickerHelper.updateLastDirectory(path);
    setState(() => controller.text = path);
  }
}
