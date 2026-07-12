import 'dart:async';
import 'dart:ui' show ImageFilter, PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:termora/app/theme/app_theme.dart';
import 'package:termora/core/l10n/app_l10n.dart';
import 'package:termora/features/database/controller/database_providers.dart';
import 'package:termora/features/database/data/db_metrics_service.dart';
import 'package:termora/features/database/data/db_service.dart';
import 'package:termora/features/database/domain/db_live_metrics.dart';
import 'package:termora/features/database/domain/db_metrics.dart';
import 'package:termora/features/database/domain/db_models.dart';
import 'package:termora/core/widgets/charts/interactive_bar_chart.dart';
import 'package:termora/core/widgets/charts/live_line_chart.dart';
import 'package:termora/core/widgets/charts/ring_gauge.dart';
import 'package:termora/core/widgets/charts/sparkline.dart';

/// 数据库概览仪表盘 —— 高密度、可交互、带实时动态折线。
/// 静态指标走 dbMetricsProvider;实时序列由本组件自持一个采样连接,每 2s 采一次,
/// 切走/断开时随组件卸载自动停止。
class DbOverviewPanel extends ConsumerStatefulWidget {
  const DbOverviewPanel({super.key, required this.connectionId});

  final String connectionId;

  @override
  ConsumerState<DbOverviewPanel> createState() => _DbOverviewPanelState();
}

class _DbOverviewPanelState extends ConsumerState<DbOverviewPanel> {
  static const _interval = Duration(seconds: 2);

  Timer? _timer;
  DbConnection? _conn;
  DbLiveSample? _prev;
  DbLiveSeries _series = DbLiveSeries();
  bool _live = true;
  bool _sampling = false;

  // 图表专用色板(与品牌色区分,亮暗主题下都够对比)
  static const _cConn = Color(0xFF5B8DEF); // 蓝 · 连接
  static const _cRate = Color(0xFF3FB68E); // 青绿 · 速率
  static const _cCache = Color(0xFF8B7CF6); // 紫 · 缓存
  static const _cSize = Color(0xFFE0A458); // 琥珀 · 大小

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_interval, (_) => _sample());
    WidgetsBinding.instance.addPostFrameCallback((_) => _sample());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _conn?.close();
    super.dispose();
  }

  Future<void> _sample() async {
    if (_sampling || !_live || !mounted) return;
    _sampling = true;
    try {
      final config = ref
          .read(dbConnectionsProvider)
          .where((c) => c.id == widget.connectionId)
          .firstOrNull;
      if (config == null) return;
      _conn ??= await DbService.open(config);
      final sample = await DbMetricsService.sampleLive(
        _conn!,
        config,
        previous: _prev,
      );
      _prev = sample;
      if (mounted) setState(() => _series = _series.appended(sample));
    } catch (_) {
      // 连接可能已断,下个 tick 重开
      try {
        await _conn?.close();
      } catch (_) {}
      _conn = null;
    } finally {
      _sampling = false;
    }
  }

  void _toggleLive() => setState(() => _live = !_live);

  void _openTable(DbTableMetric t) {
    if (t.schema.isEmpty) {
      // sqlite:无 schema,用默认 main
      ref
          .read(dbSessionProvider.notifier)
          .openTable('main', t.table, connectionId: widget.connectionId);
    } else {
      ref.read(dbSessionProvider.notifier).openTable(
        t.schema,
        t.table,
        connectionId: widget.connectionId,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(dbMetricsProvider(widget.connectionId));
    return Container(
      color: AppTheme.backgroundColor,
      child: async.when(
        loading: () => const Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
        ),
        error: (e, _) => _errorView('$e'),
        data: (m) => _dashboard(m),
      ),
    );
  }

  Widget _errorView(String e) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.circleAlert, size: 28, color: AppTheme.errorColor),
          const SizedBox(height: 10),
          Text(
            tr2('读取指标失败: {0}', [e]),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: AppTheme.bodyColor),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () =>
                ref.invalidate(dbMetricsProvider(widget.connectionId)),
            icon: const Icon(LucideIcons.refreshCw, size: 13),
            label: Text(tr('重试')),
          ),
        ],
      ),
    ),
  );

  Widget _dashboard(DbMetrics m) {
    final latest = _series.latest;
    final byBytes = m.topTables.any((t) => t.bytes > 0);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(m),
          const SizedBox(height: 8),
          _tiles(m, latest),
          const SizedBox(height: 10),
          _liveCharts(m),
          if (m.topTables.isNotEmpty) ...[
            const SizedBox(height: 11),
            _sectionTitle(
              byBytes ? tr('体量最大的表') : tr('行数最多的表'),
              LucideIcons.table2,
            ),
            const SizedBox(height: 6),
            InteractiveBarChart(
              items: [
                for (final t in m.topTables)
                  BarItem(
                    label: t.qualified,
                    value: (byBytes ? t.bytes : t.rows).toDouble(),
                    valueLabel: byBytes
                        ? prettyBytes(t.bytes)
                        : prettyCount(t.rows),
                    tooltip:
                        '${t.qualified} · ${prettyBytes(t.bytes)} · ${prettyCount(t.rows)} ${tr('行')}',
                  ),
              ],
              onTap: (i) => _openTable(m.topTables[i]),
              barColor: _cConn,
              trackColor: AppTheme.mutedSurfaceColor,
              textColor: AppTheme.bodyColor,
              subtleTextColor: AppTheme.subtleTextColor,
              hoverColor: _cConn.withValues(alpha: 0.07),
              rowHeight: 21,
            ),
          ],
          if (m.schemas.length > 1) ...[
            const SizedBox(height: 11),
            _sectionTitle(tr('各 Schema 分布'), LucideIcons.folderTree),
            const SizedBox(height: 6),
            InteractiveBarChart(
              items: [
                for (final s in m.schemas)
                  BarItem(
                    label: s.schema,
                    value: s.bytes.toDouble(),
                    valueLabel: prettyBytes(s.bytes),
                    tooltip:
                        '${s.schema} · ${prettyBytes(s.bytes)} · ${s.tableCount} ${tr('表')}',
                  ),
              ],
              barColor: _cCache,
              trackColor: AppTheme.mutedSurfaceColor,
              textColor: AppTheme.bodyColor,
              subtleTextColor: AppTheme.subtleTextColor,
              hoverColor: _cCache.withValues(alpha: 0.06),
              rowHeight: 21,
            ),
          ],
        ],
      ),
    );
  }

  // ── 顶部条 ──

  Widget _header(DbMetrics m) {
    return Row(
      children: [
        Icon(LucideIcons.chartColumnBig, size: 16, color: AppTheme.brandColor),
        const SizedBox(width: 7),
        Text(
          tr('概览'),
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w300,
            color: AppTheme.headingColor,
          ),
        ),
        if (m.version != null) ...[
          const SizedBox(width: 9),
          Text(
            '${m.engine.label} ${m.version}',
            style: TextStyle(fontSize: 11, color: AppTheme.subtleTextColor),
          ),
        ],
        const Spacer(),
        // 实时开关
        _LiveDot(active: _live),
        const SizedBox(width: 5),
        InkWell(
          onTap: _toggleLive,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            child: Row(
              children: [
                Icon(
                  _live ? LucideIcons.pause : LucideIcons.play,
                  size: 12,
                  color: AppTheme.subtleTextColor,
                ),
                const SizedBox(width: 4),
                Text(
                  _live ? tr('实时') : tr('已暂停'),
                  style: TextStyle(
                    fontSize: 10.5,
                    color: AppTheme.subtleTextColor,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 4),
        IconButton(
          tooltip: tr('刷新'),
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          icon: Icon(
            LucideIcons.refreshCw,
            size: 14,
            color: AppTheme.subtleTextColor,
          ),
          onPressed: () =>
              ref.invalidate(dbMetricsProvider(widget.connectionId)),
        ),
      ],
    );
  }

  // ── KPI 卡片(带 sparkline / 环形)──

  Widget _tiles(DbMetrics m, DbLiveSample? latest) {
    final connsSpark = _series.field((s) => s.activeConnections?.toDouble());
    final rateSpark = _series.field((s) => s.ratePerSec);
    final sizeSpark = _series.field((s) => s.dbBytes.toDouble());
    final rateLabel = m.engine == DbEngine.clickhouse
        ? tr('查询/秒')
        : tr('事务/秒');

    final tiles = <Widget>[
      _StatTile(
        icon: LucideIcons.hardDrive,
        label: tr('数据库大小'),
        value: prettyBytes((latest?.dbBytes ?? m.databaseBytes)),
        spark: sizeSpark,
        sparkColor: _cSize,
      ),
      if (latest?.activeConnections != null || m.activeConnections != null)
        _StatTile(
          icon: LucideIcons.plug,
          label: tr('活动连接'),
          value: m.maxConnections != null
              ? '${latest?.activeConnections ?? m.activeConnections}/${m.maxConnections}'
              : '${latest?.activeConnections ?? m.activeConnections}',
          spark: connsSpark,
          sparkColor: _cConn,
        ),
      if (m.engine != DbEngine.sqlite)
        _StatTile(
          icon: LucideIcons.activity,
          label: rateLabel,
          value: latest?.ratePerSec == null
              ? '—'
              : latest!.ratePerSec!.toStringAsFixed(
                  latest.ratePerSec! >= 100 ? 0 : 1,
                ),
          spark: rateSpark,
          sparkColor: _cRate,
        ),
      _StatTile(
        icon: LucideIcons.rows3,
        label: tr('行数(估计)'),
        value: prettyCount(m.approxRows),
      ),
      _StatTile(
        icon: LucideIcons.table2,
        label: tr('表'),
        value: prettyCount(m.tableCount),
      ),
      _StatTile(
        icon: LucideIcons.scanEye,
        label: tr('视图'),
        value: prettyCount(m.viewCount),
      ),
      if (m.schemaCount > 1)
        _StatTile(
          icon: LucideIcons.folderTree,
          label: 'Schema',
          value: prettyCount(m.schemaCount),
        ),
      if (m.uptime != null)
        _StatTile(
          icon: LucideIcons.clock,
          label: tr('运行时长'),
          value: prettyDuration(m.uptime!),
        ),
    ];

    final gaugeValue = latest?.cacheHit ?? m.cacheHitRatio;
    if (gaugeValue != null) {
      tiles.add(
        _GaugeTile(
          value: gaugeValue,
          color: _cCache,
          track: AppTheme.mutedSurfaceColor,
          label: tr('缓存命中'),
        ),
      );
    }
    // 单行横向滑动(不换行);卡片按内容自适应宽度
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(
        context,
      ).copyWith(scrollbars: false, dragDevices: {...PointerDeviceKind.values}),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        // 外层是纵向滚动,高度无界:IntrinsicHeight 先定行高,
        // stretch 才能让所有卡等高(与环形卡对齐)而不炸约束
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < tiles.length; i++) ...[
                if (i > 0) const SizedBox(width: 6),
                tiles[i],
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ── 实时折线图网格 ──

  Widget _liveCharts(DbMetrics m) {
    final charts = <(int, String, LineSeries)>[];
    if (m.activeConnections != null || (_series.latest?.activeConnections != null)) {
      charts.add((
        0,
        tr('活动连接'),
        LineSeries(
          label: tr('连接'),
          color: _cConn,
          values: _series.field((s) => s.activeConnections?.toDouble()),
        ),
      ));
    }
    if (m.engine != DbEngine.sqlite) {
      charts.add((
        1,
        m.engine == DbEngine.clickhouse ? tr('查询/秒') : tr('事务/秒'),
        LineSeries(
          label: tr('速率'),
          color: _cRate,
          values: _series.field((s) => s.ratePerSec),
        ),
      ));
    }
    if (m.engine == DbEngine.postgres) {
      charts.add((
        2,
        tr('缓存命中 %'),
        LineSeries(
          label: tr('命中'),
          color: _cCache,
          values: _series.field((s) => s.cacheHit == null ? null : s.cacheHit! * 100),
        ),
      ));
    }
    charts.add((
      3,
      tr('数据库大小'),
      LineSeries(
        label: tr('大小'),
        color: _cSize,
        values: _series.field((s) => s.dbBytes.toDouble()),
      ),
    ));

    return LayoutBuilder(
      builder: (context, c) {
        final perRow = c.maxWidth >= 640 ? 2 : 1;
        final gap = 8.0;
        final w = (c.maxWidth - gap * (perRow - 1)) / perRow;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final (kind, title, series) in charts)
              SizedBox(
                width: w,
                child: _ChartCard(
                  title: title,
                  child: LiveLineChart(
                    series: [series],
                    height: 104,
                    gridColor: AppTheme.borderColor,
                    textColor: AppTheme.subtleTextColor,
                    tooltipBg: AppTheme.surfaceColor,
                    surfaceColor: AppTheme.surfaceColor.withValues(alpha: 0.4),
                    minY: kind == 2 ? 0 : null,
                    maxY: kind == 2 ? 100 : null,
                    yFormat: kind == 3
                        ? (v) => prettyBytes(v.round())
                        : (kind == 2
                              ? (v) => '${v.toStringAsFixed(0)}%'
                              : (v) => v >= 100
                                    ? v.toStringAsFixed(0)
                                    : v.toStringAsFixed(1)),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _sectionTitle(String text, IconData icon) => Row(
    children: [
      Icon(icon, size: 12, color: AppTheme.subtleTextColor),
      const SizedBox(width: 6),
      Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w300,
          color: AppTheme.headingColor,
        ),
      ),
    ],
  );
}

// ══════════════ 小组件 ══════════════

class _LiveDot extends StatefulWidget {
  const _LiveDot({required this.active});
  final bool active;

  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) {
      return Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: AppTheme.subtleTextColor.withValues(alpha: 0.5),
          shape: BoxShape.circle,
        ),
      );
    }
    // RepaintBoundary:呼吸动画每帧只重画这颗 8px 圆点,不连带整页。
    return RepaintBoundary(
      child: FadeTransition(
        opacity: Tween(begin: 0.35, end: 1.0).animate(_c),
        child: Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: AppTheme.successColor,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}

/// 毛玻璃卡片(与 glass_menu 同配方:模糊 + 半透明面色 + 细边)
class _GlassCard extends StatelessWidget {
  const _GlassCard({required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final dk = Theme.of(context).brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: AppTheme.surfaceColor.withValues(alpha: dk ? 0.55 : 0.65),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: dk
                  ? AppTheme.surfaceColor.withValues(alpha: 0.25)
                  : AppTheme.headingColor.withValues(alpha: 0.08),
              width: 0.5,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.icon,
    required this.label,
    required this.value,
    this.spark,
    this.sparkColor,
  });

  final IconData icon;
  final String label;
  final String value;
  final List<double?>? spark;
  final Color? sparkColor;

  @override
  Widget build(BuildContext context) {
    final hasSpark = spark != null &&
        spark!.whereType<double>().isNotEmpty &&
        sparkColor != null;
    // 不定宽:按内容自适应(单行横滑,数值不再截断)
    return _GlassCard(
      padding: const EdgeInsets.fromLTRB(11, 7, 11, 7),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 96),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 12, color: AppTheme.subtleTextColor),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 10,
                    color: AppTheme.subtleTextColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w300,
                    color: AppTheme.headingColor,
                    height: 1,
                  ),
                ),
                if (hasSpark) ...[
                  const SizedBox(width: 8),
                  Sparkline(
                    values: spark!,
                    color: sparkColor!,
                    width: 44,
                    height: 17,
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _GaugeTile extends StatelessWidget {
  const _GaugeTile({
    required this.value,
    required this.color,
    required this.track,
    required this.label,
  });

  final double value;
  final Color color;
  final Color track;
  final String label;

  @override
  Widget build(BuildContext context) {
    return _GlassCard(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: RingGauge(
        value: value,
        color: color,
        trackColor: track,
        size: 64,
        strokeWidth: 7,
        centerText: '${(value * 100).toStringAsFixed(1)}%',
        centerTextColor: AppTheme.headingColor,
        label: label,
        labelColor: AppTheme.subtleTextColor,
      ),
    );
  }
}

class _ChartCard extends StatelessWidget {
  const _ChartCard({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return _GlassCard(
      padding: const EdgeInsets.fromLTRB(11, 7, 11, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(fontSize: 11, color: AppTheme.bodyColor),
          ),
          const SizedBox(height: 6),
          child,
        ],
      ),
    );
  }
}
