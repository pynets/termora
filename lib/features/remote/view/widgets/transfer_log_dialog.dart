import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:termora/app/theme/app_theme.dart';
import 'package:termora/core/data/transfer_log_store.dart';
import 'package:termora/core/l10n/app_l10n.dart';

/// 传输记录查看页 — 跨全部主机的 SFTP 上传/下载历史(SQLite 持久化):
/// 按主机筛选、按方向/状态筛选、清空。只读展示,不可重试。
class TransferLogDialog extends StatefulWidget {
  const TransferLogDialog({super.key, required this.hostNames});

  /// host.id → 显示名(主机可能已删除,回落显示 id)
  final Map<String, String> hostNames;

  @override
  State<TransferLogDialog> createState() => _TransferLogDialogState();
}

enum _Filter { all, upload, download, failed }

class _TransferLogDialogState extends State<TransferLogDialog> {
  List<TransferRecord> _records = const [];
  bool _loading = true;
  _Filter _filter = _Filter.all;

  /// 主机过滤:null = 全部
  String? _hostFilter;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final records = await TransferLogStore.all();
      if (!mounted) return;
      setState(() {
        _records = records;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<TransferRecord> get _visible => [
    for (final r in _records)
      if ((_hostFilter == null || r.host == _hostFilter) &&
          switch (_filter) {
            _Filter.all => true,
            _Filter.upload => r.isUpload,
            _Filter.download => !r.isUpload,
            _Filter.failed => r.state == 'failed',
          })
        r,
  ];

  /// 记录里出现过的主机(id)集合,喂给筛选下拉
  List<String> get _hostsInLog {
    final seen = <String>{};
    return [
      for (final r in _records)
        if (seen.add(r.host)) r.host,
    ];
  }

  String _hostLabel(String id) => widget.hostNames[id] ?? id;

  Future<void> _clear() async {
    final scopeHost = _hostFilter;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('清空传输记录')),
        content: Text(
          scopeHost == null
              ? tr('确定清空全部主机的传输记录吗?')
              : tr2('确定清空「{0}」的传输记录吗?', [_hostLabel(scopeHost)]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(tr('取消')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.errorColor),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(tr('清空')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await TransferLogStore.clear(host: scopeHost);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppTheme.surfaceColor,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(),
            _buildFilterBar(),
            if (_loading)
              LinearProgressIndicator(
                minHeight: 2,
                backgroundColor: Colors.transparent,
                color: AppTheme.brandColor,
              ),
            Flexible(child: _buildList()),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
      ),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      child: Row(
        children: [
          Icon(
            LucideIcons.arrowRightLeft300,
            size: 15,
            color: AppTheme.brandColor,
          ),
          const SizedBox(width: 8),
          Text(
            tr('传输记录'),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppTheme.headingColor,
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: _hostFilter == null ? tr('清空全部') : tr('清空该主机'),
            icon: Icon(
              LucideIcons.trash300,
              size: 15,
              color: AppTheme.subtleTextColor,
            ),
            visualDensity: VisualDensity.compact,
            onPressed: _records.isEmpty ? null : _clear,
          ),
          IconButton(
            tooltip: tr('关闭'),
            icon: Icon(
              LucideIcons.x300,
              size: 15,
              color: AppTheme.subtleTextColor,
            ),
            visualDensity: VisualDensity.compact,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar() {
    final hosts = _hostsInLog;
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          _filterChip(tr('全部'), _Filter.all),
          _filterChip(tr('上传'), _Filter.upload),
          _filterChip(tr('下载'), _Filter.download),
          _filterChip(tr('失败'), _Filter.failed),
          const Spacer(),
          if (hosts.length > 1)
            DropdownButton<String?>(
              value: _hostFilter,
              isDense: true,
              underline: const SizedBox.shrink(),
              icon: Icon(
                LucideIcons.server300,
                size: 13,
                color: AppTheme.subtleTextColor,
              ),
              style: TextStyle(fontSize: 12, color: AppTheme.headingColor),
              dropdownColor: AppTheme.surfaceColor,
              items: [
                DropdownMenuItem(value: null, child: Text(tr('全部主机'))),
                for (final h in hosts)
                  DropdownMenuItem(value: h, child: Text(_hostLabel(h))),
              ],
              onChanged: (v) => setState(() => _hostFilter = v),
            ),
        ],
      ),
    );
  }

  Widget _filterChip(String label, _Filter value) {
    final active = _filter == value;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => setState(() => _filter = value),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: active
                ? AppTheme.brandColor.withValues(alpha: 0.14)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: active ? FontWeight.w600 : FontWeight.w500,
              color: active ? AppTheme.brandColor : AppTheme.subtleTextColor,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildList() {
    final visible = _visible;
    if (!_loading && visible.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Text(
            _records.isEmpty ? tr('还没有传输记录') : tr('没有匹配的记录'),
            style: TextStyle(fontSize: 12.5, color: AppTheme.subtleTextColor),
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: visible.length,
      itemBuilder: (context, index) => _buildRow(visible[index]),
    );
  }

  Widget _buildRow(TransferRecord r) {
    final (icon, color) = switch (r.state) {
      'done' => (LucideIcons.circleCheck300, AppTheme.successColor),
      'failed' => (LucideIcons.circleAlert300, AppTheme.errorColor),
      _ => (LucideIcons.circleX300, AppTheme.subtleTextColor),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      child: Row(
        children: [
          Icon(
            r.isUpload ? LucideIcons.upload300 : LucideIcons.download300,
            size: 13,
            color: AppTheme.subtleTextColor,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  r.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: AppTheme.headingColor,
                  ),
                ),
                Text(
                  [
                    _hostLabel(r.host),
                    if (r.error != null && r.error!.isNotEmpty) r.error!,
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    color: r.error != null
                        ? AppTheme.errorColor.withValues(alpha: 0.85)
                        : AppTheme.subtleTextColor,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(
            _formatTime(r.finishedAt),
            style: TextStyle(fontSize: 10.5, color: AppTheme.subtleTextColor),
          ),
          const SizedBox(width: 8),
          Icon(icon, size: 14, color: color),
        ],
      ),
    );
  }

  String _formatTime(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}';
  }
}
