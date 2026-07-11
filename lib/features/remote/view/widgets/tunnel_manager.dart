import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:termora/app/theme/app_theme.dart';
import 'package:termora/features/remote/data/tunnel_service.dart';
import 'package:termora/features/remote/domain/ssh_host.dart';
import 'package:termora/core/l10n/app_l10n.dart';

/// 打开某主机的端口转发管理弹窗。
Future<void> showTunnelManager(BuildContext context, SshHost host) async {
  await TunnelStore.ensureLoaded();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    useRootNavigator: false,
    barrierColor: Colors.black.withValues(alpha: 0.3),
    builder: (context) => _TunnelManagerDialog(host: host),
  );
}

class _TunnelManagerDialog extends StatelessWidget {
  const _TunnelManagerDialog({required this.host});

  final SshHost host;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Icon(LucideIcons.waypoints300, size: 17, color: AppTheme.brandColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              tr2('{0} · 端口转发', [host.name]),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 460,
        height: 380,
        child: ValueListenableBuilder<List<SshTunnel>>(
          valueListenable: TunnelStore.tunnels,
          builder: (context, all, _) {
            final list = [for (final t in all) if (t.hostId == host.id) t];
            if (list.isEmpty) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      LucideIcons.waypoints300,
                      size: 26,
                      color: AppTheme.subtleTextColor.withValues(alpha: 0.5),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      tr('还没有端口转发,点「新建」添加'),
                      style: TextStyle(
                        fontSize: 12.5,
                        color: AppTheme.subtleTextColor,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      tr('转发复用该主机已连接的 SSH 会话,请先在左侧连接一次'),
                      style: TextStyle(
                        fontSize: 11,
                        color: AppTheme.subtleTextColor,
                      ),
                    ),
                  ],
                ),
              );
            }
            return ValueListenableBuilder<Set<String>>(
              valueListenable: TunnelService.runningIds,
              builder: (context, running, _) => ValueListenableBuilder<
                  Map<String, String>>(
                valueListenable: TunnelService.errors,
                builder: (context, errors, _) => ListView.separated(
                  itemCount: list.length,
                  separatorBuilder: (_, _) =>
                      Divider(height: 1, color: AppTheme.borderColor),
                  itemBuilder: (context, i) => _row(
                    context,
                    list[i],
                    running.contains(list[i].id),
                    errors[list[i].id],
                  ),
                ),
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => _edit(context, null),
          child: Text(tr('新建')),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppTheme.brandColor),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('完成')),
        ),
      ],
    );
  }

  Widget _row(
    BuildContext context,
    SshTunnel tunnel,
    bool running,
    String? error,
  ) {
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: AppTheme.subtleSurfaceColor.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          tunnel.typeLabel,
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
            color: AppTheme.subtleTextColor,
          ),
        ),
      ),
      title: Text(
        tunnel.summary,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12.5, color: AppTheme.headingColor),
      ),
      subtitle: error != null
          ? Text(
              error,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10.5, color: AppTheme.errorColor),
            )
          : Text(
              running ? tr('运行中') : tr('已停止'),
              style: TextStyle(
                fontSize: 10.5,
                color: running ? AppTheme.successColor : AppTheme.subtleTextColor,
              ),
            ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: running ? tr('停止') : tr('启动'),
            icon: Icon(
              running ? LucideIcons.circleStop300 : LucideIcons.play300,
              size: 16,
              color: running ? AppTheme.errorColor : AppTheme.successColor,
            ),
            onPressed: () {
              if (running) {
                TunnelService.stop(tunnel.id);
              } else {
                TunnelService.start(host, tunnel);
              }
            },
          ),
          IconButton(
            tooltip: tr('编辑'),
            icon: Icon(LucideIcons.penLine300, size: 15),
            onPressed: running ? null : () => _edit(context, tunnel),
          ),
          IconButton(
            tooltip: tr('删除'),
            icon: Icon(
              LucideIcons.trash300,
              size: 15,
              color: AppTheme.errorColor,
            ),
            onPressed: () {
              TunnelService.stop(tunnel.id);
              TunnelStore.remove(tunnel.id);
            },
          ),
        ],
      ),
    );
  }

  Future<void> _edit(BuildContext context, SshTunnel? existing) async {
    final tunnel = await showDialog<SshTunnel>(
      context: context,
      useRootNavigator: false,
      barrierColor: Colors.black.withValues(alpha: 0.3),
      builder: (context) => _TunnelEditDialog(hostId: host.id, existing: existing),
    );
    if (tunnel != null) await TunnelStore.upsert(tunnel);
  }
}

class _TunnelEditDialog extends StatefulWidget {
  const _TunnelEditDialog({required this.hostId, this.existing});

  final String hostId;
  final SshTunnel? existing;

  @override
  State<_TunnelEditDialog> createState() => _TunnelEditDialogState();
}

class _TunnelEditDialogState extends State<_TunnelEditDialog> {
  late TunnelType _type;
  late final TextEditingController _bindAddr;
  late final TextEditingController _bindPort;
  late final TextEditingController _destHost;
  late final TextEditingController _destPort;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _type = e?.type ?? TunnelType.local;
    _bindAddr = TextEditingController(text: e?.bindAddress ?? '');
    _bindPort = TextEditingController(text: e == null ? '' : '${e.bindPort}');
    _destHost = TextEditingController(text: e?.destHost ?? 'localhost');
    _destPort = TextEditingController(
      text: e == null || e.destPort == 0 ? '' : '${e.destPort}',
    );
  }

  @override
  void dispose() {
    _bindAddr.dispose();
    _bindPort.dispose();
    _destHost.dispose();
    _destPort.dispose();
    super.dispose();
  }

  void _save() {
    final bindPort = int.tryParse(_bindPort.text.trim());
    if (bindPort == null || bindPort <= 0) return;
    final destPort = int.tryParse(_destPort.text.trim()) ?? 0;
    if (_type != TunnelType.dynamic && destPort <= 0) return;
    Navigator.of(context).pop(
      (widget.existing ??
              SshTunnel(
                id: DateTime.now().microsecondsSinceEpoch.toString(),
                hostId: widget.hostId,
                type: _type,
                bindPort: bindPort,
              ))
          .copyWith(
            type: _type,
            bindAddress: _bindAddr.text.trim(),
            bindPort: bindPort,
            destHost: _destHost.text.trim().isEmpty
                ? 'localhost'
                : _destHost.text.trim(),
            destPort: destPort,
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDynamic = _type == TunnelType.dynamic;
    return AlertDialog(
      title: Text(widget.existing == null ? tr('新建端口转发') : tr('编辑端口转发')),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<TunnelType>(
              segments: const [
                ButtonSegment(value: TunnelType.local, label: Text('本地 -L')),
                ButtonSegment(value: TunnelType.remote, label: Text('远程 -R')),
                ButtonSegment(value: TunnelType.dynamic, label: Text('SOCKS -D')),
              ],
              selected: {_type},
              onSelectionChanged: (s) => setState(() => _type = s.first),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: _field(_bindAddr, tr('绑定地址(可空)'), 'localhost'),
                ),
                const SizedBox(width: 8),
                Expanded(child: _field(_bindPort, tr('本地端口'), tr('如 8080'))),
              ],
            ),
            if (!isDynamic) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(flex: 2, child: _field(_destHost, tr('目标主机'), 'localhost')),
                  const SizedBox(width: 8),
                  Expanded(child: _field(_destPort, tr('目标端口'), tr('如 5432'))),
                ],
              ),
            ],
            const SizedBox(height: 8),
            Text(
              _hint(),
              style: TextStyle(
                fontSize: 11,
                height: 1.4,
                color: AppTheme.subtleTextColor,
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
          style: FilledButton.styleFrom(backgroundColor: AppTheme.brandColor),
          onPressed: _save,
          child: Text(tr('保存')),
        ),
      ],
    );
  }

  String _hint() {
    switch (_type) {
      case TunnelType.local:
        return tr(
          '本地转发:访问本机「绑定端口」→ 经服务器 → 到「目标主机:端口」。'
          '如把远端数据库映射到本地 5432。',
        );
      case TunnelType.remote:
        return tr('远程转发:服务器上的「绑定端口」→ 经本机 → 到「目标主机:端口」。');
      case TunnelType.dynamic:
        return tr('SOCKS 代理:本机「绑定端口」作为 SOCKS5 代理,流量经服务器出网。');
    }
  }

  Widget _field(TextEditingController c, String label, String hint) {
    return TextField(
      controller: c,
      style: TextStyle(fontSize: 12.5, color: AppTheme.headingColor),
      decoration: InputDecoration(
        isDense: true,
        labelText: label,
        hintText: hint,
        hintStyle: TextStyle(
          fontSize: 11,
          color: AppTheme.subtleTextColor.withValues(alpha: 0.6),
        ),
        border: const OutlineInputBorder(),
      ),
    );
  }
}
