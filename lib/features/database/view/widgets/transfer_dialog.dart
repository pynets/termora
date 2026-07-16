import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:termora/app/theme/app_theme.dart';
import 'package:termora/core/l10n/app_l10n.dart';
import 'package:termora/core/utils/file_picker_helper.dart';
import 'package:termora/core/widgets/glass_menu.dart';
import 'package:termora/features/database/controller/database_providers.dart';
import 'package:termora/features/database/data/db_service.dart';
import 'package:termora/features/database/data/db_transfer_service.dart';
import 'package:termora/features/database/domain/db_etl.dart';
import 'package:termora/features/database/domain/db_models.dart';
import 'package:termora/features/database/domain/db_transfer_task.dart';
import 'package:termora/features/database/view/widgets/copyable_error_box.dart';
import 'package:termora/features/database/view/widgets/etl_rule_dialog.dart';

/// 打开导出/导入/迁移向导。[presetWholeDatabase] 用于「备份整库」入口:
/// 直接以整库模式打开导出向导。
Future<void> showTransferDialog(
  BuildContext context, {
  required DbConnectionConfig source,
  required DbTransferMode mode,
  bool presetWholeDatabase = false,
}) {
  return showDialog(
    context: context,
    useRootNavigator: false,
    barrierColor: Colors.black.withValues(alpha: 0.3),
    barrierDismissible: false,
    builder: (context) => _TransferDialog(
      source: source,
      mode: mode,
      presetWholeDatabase: presetWholeDatabase,
    ),
  );
}

class _TransferDialog extends ConsumerStatefulWidget {
  const _TransferDialog({
    required this.source,
    required this.mode,
    this.presetWholeDatabase = false,
  });

  final DbConnectionConfig source;
  final DbTransferMode mode;
  final bool presetWholeDatabase;

  @override
  ConsumerState<_TransferDialog> createState() => _TransferDialogState();
}

class _TransferDialogState extends ConsumerState<_TransferDialog> {
  // ── 元数据(导出/迁移需要浏览源库)──
  bool _metaLoading = false;
  String? _metaError;
  List<String> _schemas = const [];

  /// 多选的 schema。整库 → 忽略;单选 → 显示表清单(可逐表选 + ETL);
  /// 多选 → 各 schema 取全部表(视图除外)。
  final Set<String> _selectedSchemas = {};

  /// 单 schema 选中时该 schema 的表清单与勾选(多选时不用)
  List<DbTableInfo> _tables = const [];
  final Set<String> _selected = {};

  /// 恰好选中一个 schema 时返回它,否则 null
  String? get _singleSchema =>
      _selectedSchemas.length == 1 ? _selectedSchemas.first : null;

  /// 整库模式:忽略 schema/选表,迁移/导出所有 schema 的全部表
  late bool _wholeDatabase = widget.presetWholeDatabase;

  /// 源表名 → ETL 规则(等价空规则不会存进来)
  final Map<String, DbEtlTableRule> _etlRules = {};

  // ── 选项 ──
  late DbEngine _targetEngine = widget.source.engine; // 导出方言
  DbConnectionConfig? _targetConfig; // 迁移目标
  bool _overwrite = true; // DROP TABLE IF EXISTS
  bool _includeData = true;
  String? _scriptPath; // 导入的脚本文件

  // ── 运行状态 ──
  bool _running = false;
  bool _cancelRequested = false;
  bool _finished = false;
  double? _progress;
  final List<String> _log = [];
  String? _error;
  final ScrollController _logScroll = ScrollController();

  bool get _needsMeta =>
      widget.mode != DbTransferMode.importScript &&
      widget.mode != DbTransferMode.importDump;

  /// 是否为「导入类」模式(选文件而非浏览源库)
  bool get _isImport =>
      widget.mode == DbTransferMode.importScript ||
      widget.mode == DbTransferMode.importDump;

  /// 是否为便携归档(dump/store)模式
  bool get _isDump =>
      widget.mode == DbTransferMode.exportDump ||
      widget.mode == DbTransferMode.importDump;

  @override
  void initState() {
    super.initState();
    if (_needsMeta) _loadSchemas();
  }

  @override
  void dispose() {
    _logScroll.dispose();
    super.dispose();
  }

  // ══════════════ 元数据 ══════════════

  Future<void> _loadSchemas() async {
    setState(() {
      _metaLoading = true;
      _metaError = null;
    });
    try {
      final conn = await DbService.open(widget.source);
      try {
        final schemas = await DbService.listSchemas(conn);
        // 默认选中 public / 库名 / 第一个
        final preferred = widget.source.engine == DbEngine.postgres
            ? 'public'
            : widget.source.database;
        final def = schemas.contains(preferred)
            ? preferred
            : (schemas.isNotEmpty ? schemas.first : null);
        if (!mounted) return;
        setState(() {
          _metaLoading = false;
          _schemas = schemas;
          if (!_wholeDatabase && def != null) _selectedSchemas.add(def);
        });
        if (!_wholeDatabase && def != null) await _loadTablesFor(def);
      } finally {
        await conn.close();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _metaLoading = false;
        _metaError = '$e';
      });
    }
  }

  /// 加载某 schema 的表清单(单选时逐表勾选)
  Future<void> _loadTablesFor(String schema) async {
    setState(() {
      _metaLoading = true;
      _tables = const [];
      _selected.clear();
    });
    try {
      final conn = await DbService.open(widget.source);
      try {
        final tables = await DbService.listTables(conn, schema);
        if (!mounted) return;
        setState(() {
          _metaLoading = false;
          _tables = tables;
          _selected.addAll([
            for (final t in tables)
              if (!t.isView) t.name,
          ]);
        });
      } finally {
        await conn.close();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _metaLoading = false;
        _metaError = '$e';
      });
    }
  }

  /// 勾选/取消一个 schema:切换会清空 ETL 规则;最终恰好选中一个时加载其表清单
  void _toggleSchema(String schema) {
    setState(() {
      if (_selectedSchemas.contains(schema)) {
        _selectedSchemas.remove(schema);
      } else {
        _selectedSchemas.add(schema);
      }
      _wholeDatabase = false;
      _etlRules.clear();
      _tables = const [];
      _selected.clear();
    });
    final single = _singleSchema;
    if (single != null) _loadTablesFor(single);
  }

  /// 非整库时传给 service 的目标:单 schema 用勾选的表;多 schema 各取全部表
  Map<String, List<String>> _buildSchemaTables() {
    final single = _singleSchema;
    if (single != null) {
      return {single: _selected.toList()..sort()};
    }
    return {for (final s in _selectedSchemas) s: const <String>[]};
  }

  /// 范围文案(文件名/任务名/默认名用)
  String get _scopeLabel {
    if (_wholeDatabase) return tr('整库');
    final single = _singleSchema;
    if (single != null) return single;
    return tr2('{0} 个 schema', [_selectedSchemas.length]);
  }

  String get _fileBase => _wholeDatabase
      ? widget.source.name
      : (_singleSchema ?? widget.source.name);

  void _appendLog(DbTransferProgress p) {
    if (!mounted) return;
    setState(() {
      _log.add(p.message);
      if (_log.length > 500) _log.removeRange(0, _log.length - 400);
      _progress = p.total > 0 ? p.done / p.total : null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) {
        _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _run() async {
    setState(() {
      _running = true;
      _cancelRequested = false;
      _finished = false;
      _error = null;
      _progress = null;
      _log.clear();
    });

    try {
      final DbTransferSummary summary;
      switch (widget.mode) {
        case DbTransferMode.export:
          final path = await FilePicker.saveFile(
            dialogTitle: tr('导出 SQL 脚本'),
            fileName: '$_fileBase.sql',
          );
          if (path == null) {
            setState(() => _running = false);
            return;
          }
          final finalPath = path.endsWith('.sql') ? path : '$path.sql';
          summary = await DbTransferService.exportToScript(
            source: widget.source,
            schemaTables: _wholeDatabase ? const {} : _buildSchemaTables(),
            wholeDatabase: _wholeDatabase,
            targetEngine: _targetEngine,
            filePath: finalPath,
            includeDrop: _overwrite,
            includeData: _includeData,
            etlRules: Map.of(_etlRules),
            onProgress: _appendLog,
            isCancelled: () => _cancelRequested,
          );
          _appendLog(DbTransferProgress(message: finalPath));

        case DbTransferMode.importScript:
          final script = await File(_scriptPath!).readAsString();
          summary = await DbTransferService.importScript(
            target: widget.source,
            script: script,
            onProgress: _appendLog,
            isCancelled: () => _cancelRequested,
          );

        case DbTransferMode.exportDump:
          final path = await FilePicker.saveFile(
            dialogTitle: tr('导出便携归档'),
            fileName: '$_fileBase.tdump',
          );
          if (path == null) {
            setState(() => _running = false);
            return;
          }
          final finalPath = path.endsWith('.tdump') ? path : '$path.tdump';
          summary = await DbTransferService.exportToDump(
            source: widget.source,
            schemaTables: _wholeDatabase ? const {} : _buildSchemaTables(),
            wholeDatabase: _wholeDatabase,
            filePath: finalPath,
            includeData: _includeData,
            onProgress: _appendLog,
            isCancelled: () => _cancelRequested,
          );
          _appendLog(DbTransferProgress(message: finalPath));

        case DbTransferMode.importDump:
          summary = await DbTransferService.importDump(
            target: widget.source,
            filePath: _scriptPath!,
            overwrite: _overwrite,
            onProgress: _appendLog,
            isCancelled: () => _cancelRequested,
          );

        case DbTransferMode.migrate:
          summary = await DbTransferService.migrate(
            source: widget.source,
            target: _targetConfig!,
            schemaTables: _wholeDatabase ? const {} : _buildSchemaTables(),
            wholeDatabase: _wholeDatabase,
            overwrite: _overwrite,
            copyData: _includeData,
            etlRules: Map.of(_etlRules),
            onProgress: _appendLog,
            isCancelled: () => _cancelRequested,
          );
      }
      if (!mounted) return;
      setState(() {
        _running = false;
        _finished = true;
        _progress = 1;
        _log.add(switch (widget.mode) {
          DbTransferMode.importScript => tr2('完成:已执行 {0} 条语句', [
            summary.statements,
          ]),
          _ => tr2('完成:{0} 张表 / {1} 行', [summary.tables, summary.rows]),
        });
      });
    } on DbTransferCancelledException {
      if (!mounted) return;
      setState(() {
        _running = false;
        _log.add(tr('已取消'));
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _error = '$e';
      });
    }
  }

  /// 把当前配置存成可重跑/可调度的任务
  Future<void> _saveAsTask() async {
    // 导出任务需要固定输出路径(可含 {ts} 占位符 → 每次跑替换成时间戳)
    String? exportPath;
    if (widget.mode == DbTransferMode.export ||
        widget.mode == DbTransferMode.exportDump) {
      final ext = _isDump ? 'tdump' : 'sql';
      final picked = await FilePicker.saveFile(
        dialogTitle: tr('任务导出文件保存到(文件名可用 {ts} 表示时间戳)'),
        fileName: '$_fileBase-{ts}.$ext',
      );
      if (picked == null || !mounted) return;
      exportPath = picked.endsWith('.$ext') ? picked : '$picked.$ext';
    }

    final name = await _promptText(tr('任务名称'), _defaultTaskName());
    if (name == null || name.trim().isEmpty || !mounted) return;

    final task = DbTransferTask(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name.trim(),
      mode: widget.mode,
      sourceConnId: widget.source.id,
      targetConnId: widget.mode == DbTransferMode.migrate
          ? _targetConfig?.id
          : null,
      filePath: switch (widget.mode) {
        DbTransferMode.export || DbTransferMode.exportDump => exportPath,
        DbTransferMode.importScript || DbTransferMode.importDump => _scriptPath,
        DbTransferMode.migrate => null,
      },
      exportDialectName: widget.mode == DbTransferMode.export
          ? _targetEngine.name
          : null,
      wholeDatabase: _wholeDatabase,
      schema: _wholeDatabase ? null : _singleSchema,
      tables: (!_wholeDatabase && _singleSchema != null)
          ? (_selected.toList()..sort())
          : const [],
      schemaTables: (!_wholeDatabase && _singleSchema == null)
          ? _buildSchemaTables()
          : const {},
      etlRules: Map.of(_etlRules),
      overwrite: _overwrite,
      includeData: _includeData,
    );
    await ref.read(dbTransferTasksProvider.notifier).upsert(task);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(tr2('已保存任务「{0}」', [task.name])),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  String _defaultTaskName() {
    final scope = _scopeLabel;
    return switch (widget.mode) {
      DbTransferMode.export => '${widget.source.name} $scope ${tr('导出')}',
      DbTransferMode.exportDump => '${widget.source.name} $scope ${tr('归档')}',
      DbTransferMode.importScript || DbTransferMode.importDump =>
        '${widget.source.name} ${tr('导入')} ${_scriptPath?.split('/').last ?? ''}',
      DbTransferMode.migrate =>
        '${widget.source.name} → ${_targetConfig?.name ?? '?'} $scope',
    };
  }

  Future<String?> _promptText(String title, String initial) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      useRootNavigator: false,
      barrierColor: Colors.black.withValues(alpha: 0.3),
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(fontSize: 13),
          decoration: const InputDecoration(isDense: true),
          onSubmitted: (v) => Navigator.of(context).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: Text(tr('确定')),
          ),
        ],
      ),
    );
  }

  bool get _canRun {
    if (_running) return false;
    final hasSource =
        _wholeDatabase ||
        (_singleSchema != null && _selected.isNotEmpty) ||
        _selectedSchemas.length > 1;
    return switch (widget.mode) {
      DbTransferMode.export || DbTransferMode.exportDump => hasSource,
      DbTransferMode.importScript ||
      DbTransferMode.importDump => _scriptPath != null,
      DbTransferMode.migrate => hasSource && _targetConfig != null,
    };
  }

  ({IconData icon, String title, String subtitle}) get _header =>
      switch (widget.mode) {
        DbTransferMode.export => (
          icon: LucideIcons.fileDown,
          title: tr('导出 SQL 脚本'),
          subtitle: tr2('把「{0}」的结构和数据导出为 SQL 文件', [widget.source.name]),
        ),
        DbTransferMode.importScript => (
          icon: LucideIcons.fileUp,
          title: tr('导入 SQL 脚本'),
          subtitle: tr2('在「{0}」上逐条执行脚本语句', [widget.source.name]),
        ),
        DbTransferMode.exportDump => (
          icon: LucideIcons.package,
          title: tr('导出便携归档'),
          subtitle: tr2('把「{0}」的结构和数据打包成 .tdump,可导入任意引擎', [widget.source.name]),
        ),
        DbTransferMode.importDump => (
          icon: LucideIcons.packageOpen,
          title: tr('从归档导入'),
          subtitle: tr2('把 .tdump 归档还原到「{0}」,自动映射类型', [widget.source.name]),
        ),
        DbTransferMode.migrate => (
          icon: LucideIcons.arrowRightLeft,
          title: tr('迁移到其它连接'),
          subtitle: tr2('把「{0}」的表复制到目标连接,覆盖同名表', [widget.source.name]),
        ),
      };

  @override
  Widget build(BuildContext context) {
    final header = _header;
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: AppTheme.brandColor.withValues(alpha: 0.13),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      header.icon,
                      size: 18,
                      color: AppTheme.brandColor,
                    ),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          header.title,
                          style: TextStyle(
                            fontSize: 15.5,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.headingColor,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          header.subtitle,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: AppTheme.subtleTextColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_isImport) _buildImportBody() else _buildSelectBody(),
                      if (_log.isNotEmpty || _running) ...[
                        const SizedBox(height: 12),
                        _buildProgress(),
                      ],
                      if (_error != null) ...[
                        const SizedBox(height: 10),
                        _buildError(),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  if (_running)
                    TextButton.icon(
                      onPressed: _cancelRequested
                          ? null
                          : () => setState(() => _cancelRequested = true),
                      icon: const Icon(LucideIcons.circleStop, size: 14),
                      label: Text(tr('停止')),
                    )
                  else
                    TextButton.icon(
                      onPressed: _canRun ? _saveAsTask : null,
                      icon: const Icon(LucideIcons.bookmarkPlus, size: 14),
                      label: Text(tr('保存为任务')),
                    ),
                  const Spacer(),
                  TextButton(
                    onPressed: _running
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: Text(_finished ? tr('关闭') : tr('取消')),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _canRun ? _run : null,
                    icon: _running
                        ? const SizedBox(
                            width: 13,
                            height: 13,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            _finished ? LucideIcons.rotateCcw : header.icon,
                            size: 14,
                          ),
                    label: Text(
                      _running
                          ? tr('执行中…')
                          : (_finished ? tr('再次执行') : tr('开始')),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ══════════════ 表单区 ══════════════

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w600,
        color: AppTheme.subtleTextColor,
      ),
    ),
  );

  Widget _buildImportBody() {
    final name = _scriptPath?.split('/').last;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(_isDump ? tr('便携归档文件') : tr('SQL 脚本文件')),
        OutlinedButton.icon(
          onPressed: _running ? null : _pickScript,
          icon: const Icon(LucideIcons.folderOpen, size: 14),
          label: Text(
            name ?? (_isDump ? tr('选择 .tdump 文件') : tr('选择 .sql 文件')),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (_isDump)
          _buildToggle(
            value: _overwrite,
            title: tr('覆盖目标同名表(DROP TABLE IF EXISTS)'),
            onChanged: (v) => setState(() => _overwrite = v),
          ),
        const SizedBox(height: 8),
        Text(
          _isDump
              ? tr('归档里存了每张表的完整结构和原始行值,导入时按目标引擎重新建表并写入。')
              : tr('脚本会按语句拆分后在目标连接上逐条执行;任一语句失败即中止。'),
          style: TextStyle(fontSize: 11, color: AppTheme.subtleTextColor),
        ),
      ],
    );
  }

  Future<void> _pickScript() async {
    final initialDirectory = await FilePickerHelper.getInitialDirectory();
    final result = await FilePicker.pickFiles(
      dialogTitle: _isDump ? tr('选择便携归档') : tr('选择 SQL 脚本'),
      initialDirectory: initialDirectory,
    );
    final path = result?.files.firstOrNull?.path;
    if (path == null || path.isEmpty || !mounted) return;
    FilePickerHelper.updateLastDirectory(path);
    setState(() => _scriptPath = path);
  }

  Widget _buildSelectBody() {
    if (_metaError != null) {
      return CopyableErrorBox(text: tr2('读取源库失败: {0}', [_metaError]));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 目标方言(SQL 导出)/ 目标连接(迁移);便携归档无二者
        if (widget.mode == DbTransferMode.export) ...[
          _label(tr('目标方言')),
          GlassDropdownButton<DbEngine>(
            value: _targetEngine,
            items: [
              for (final e in DbEngine.values)
                GlassDropdownMenuItem(
                  value: e,
                  child: Text(e.label, style: const TextStyle(fontSize: 12.5)),
                ),
            ],
            onChanged: (e) {
              if (!_running && e != null) {
                setState(() => _targetEngine = e);
              }
            },
          ),
          const SizedBox(height: 12),
        ] else if (widget.mode == DbTransferMode.migrate) ...[
          _label(tr('目标连接')),
          _buildTargetPicker(),
          const SizedBox(height: 12),
        ],
        _label(tr('源 Schema(可多选)')),
        const SizedBox(height: 6),
        _buildSchemaChips(),
        const SizedBox(height: 12),
        _buildScopeBody(),
        const SizedBox(height: 6),
        // 便携归档不在导出时嵌 DROP(覆盖与否是导入时的选择)
        if (widget.mode != DbTransferMode.exportDump)
          _buildToggle(
            value: _overwrite,
            title: tr('覆盖目标同名表(DROP TABLE IF EXISTS)'),
            onChanged: (v) => setState(() => _overwrite = v),
          ),
        _buildToggle(
          value: _includeData,
          title: tr('包含数据(否则仅结构)'),
          onChanged: (v) => setState(() => _includeData = v),
        ),
      ],
    );
  }

  Widget _buildSchemaChips() {
    if (_schemas.isEmpty) {
      return Text(
        _metaLoading ? tr('读取中…') : tr('无'),
        style: TextStyle(fontSize: 11.5, color: AppTheme.subtleTextColor),
      );
    }
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        _schemaChip(
          icon: LucideIcons.database,
          label: tr('整库'),
          selected: _wholeDatabase,
          onTap: () => setState(() {
            _wholeDatabase = true;
            _selectedSchemas.clear();
            _etlRules.clear();
            _tables = const [];
            _selected.clear();
          }),
        ),
        for (final s in _schemas)
          _schemaChip(
            label: s,
            selected: !_wholeDatabase && _selectedSchemas.contains(s),
            onTap: () => _toggleSchema(s),
          ),
      ],
    );
  }

  Widget _schemaChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    IconData? icon,
  }) {
    return InkWell(
      onTap: _running ? null : onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.brandColor.withValues(alpha: 0.14)
              : AppTheme.mutedSurfaceColor,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? AppTheme.brandColor : AppTheme.borderColor,
            width: selected ? 1.3 : 0.8,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              selected ? LucideIcons.check : (icon ?? LucideIcons.folder),
              size: 12,
              color: selected ? AppTheme.brandColor : AppTheme.subtleTextColor,
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected ? AppTheme.headingColor : AppTheme.bodyColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScopeBody() {
    if (_wholeDatabase) {
      return _noteBox(
        widget.source.engine == DbEngine.sqlite
            ? tr('整库:该库全部表(视图除外)')
            : tr('整库:所有 schema 的全部表(视图除外);目标为 PG/CH 时保留 schema'),
      );
    }
    if (_selectedSchemas.isEmpty) {
      return Text(
        tr('请至少选择一个 schema'),
        style: TextStyle(fontSize: 11.5, color: AppTheme.subtleTextColor),
      );
    }
    if (_singleSchema != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label(tr2('表({0}/{1})', [_selected.length, _tables.length])),
          _buildTableList(),
        ],
      );
    }
    return _noteBox(
      tr2('已选 {0} 个 schema,各取全部表(视图除外);目标为 PG/CH 时保留 schema', [
        _selectedSchemas.length,
      ]),
    );
  }

  Widget _noteBox(String text) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: AppTheme.brandColor.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: AppTheme.brandColor.withValues(alpha: 0.25)),
    ),
    child: Row(
      children: [
        Icon(LucideIcons.info, size: 14, color: AppTheme.brandColor),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 11.5, color: AppTheme.bodyColor),
          ),
        ),
      ],
    ),
  );

  Widget _buildTargetPicker() {
    final connections = ref.watch(dbConnectionsProvider);
    final candidates = [
      for (final c in connections)
        if (c.id != widget.source.id) c,
    ];
    if (candidates.isEmpty) {
      return Text(
        tr('没有可用的目标连接,请先新建'),
        style: TextStyle(fontSize: 11.5, color: AppTheme.subtleTextColor),
      );
    }
    return GlassDropdownButton<String>(
      value: _targetConfig?.id ?? '',
      items: [
        GlassDropdownMenuItem(
          value: '',
          child: Text(
            tr('选择目标连接'),
            style: TextStyle(fontSize: 12.5, color: AppTheme.subtleTextColor),
          ),
        ),
        for (final c in candidates)
          GlassDropdownMenuItem(
            value: c.id,
            child: Text(
              '${c.name} · ${c.engine.label}',
              style: const TextStyle(fontSize: 12.5),
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: (id) {
        if (_running) return;
        setState(() {
          _targetConfig = candidates.where((c) => c.id == id).firstOrNull;
        });
      },
    );
  }

  Widget _buildTableList() {
    if (_metaLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (_tables.isEmpty) {
      return Text(
        tr('该 Schema 下没有表'),
        style: TextStyle(fontSize: 11.5, color: AppTheme.subtleTextColor),
      );
    }
    final allSelected = _selected.length == _tables.length;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppTheme.borderColor),
        borderRadius: BorderRadius.circular(8),
      ),
      constraints: const BoxConstraints(maxHeight: 170),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: _running
                ? null
                : () => setState(() {
                    _selected.clear();
                    if (!allSelected) {
                      _selected.addAll(_tables.map((t) => t.name));
                    }
                  }),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              child: Row(
                children: [
                  Icon(
                    allSelected ? LucideIcons.squareCheck : LucideIcons.square,
                    size: 14,
                    color: allSelected
                        ? AppTheme.brandColor
                        : AppTheme.subtleTextColor,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    tr('全选'),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.bodyColor,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Divider(height: 1, color: AppTheme.borderColor),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _tables.length,
              itemBuilder: (context, index) {
                final table = _tables[index];
                final checked = _selected.contains(table.name);
                return InkWell(
                  onTap: _running
                      ? null
                      : () => setState(() {
                          checked
                              ? _selected.remove(table.name)
                              : _selected.add(table.name);
                        }),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          checked
                              ? LucideIcons.squareCheck
                              : LucideIcons.square,
                          size: 14,
                          color: checked
                              ? AppTheme.brandColor
                              : AppTheme.subtleTextColor,
                        ),
                        const SizedBox(width: 8),
                        Icon(
                          table.isView ? LucideIcons.eye : LucideIcons.table,
                          size: 12,
                          color: AppTheme.subtleTextColor,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            table.name,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
                              color: AppTheme.bodyColor,
                            ),
                          ),
                        ),
                        if (_etlRules.containsKey(table.name))
                          Container(
                            margin: const EdgeInsets.only(right: 2),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: AppTheme.brandColor.withValues(
                                alpha: 0.14,
                              ),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              'ETL',
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.brandColor,
                                letterSpacing: 0.3,
                              ),
                            ),
                          ),
                        IconButton(
                          tooltip: tr('ETL 规则(过滤/改名/脱敏)'),
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints(),
                          padding: const EdgeInsets.all(3),
                          icon: Icon(
                            LucideIcons.wand,
                            size: 13,
                            color: _etlRules.containsKey(table.name)
                                ? AppTheme.brandColor
                                : AppTheme.subtleTextColor,
                          ),
                          onPressed: _running || !checked
                              ? null
                              : () => _editEtlRule(table.name),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _editEtlRule(String table) async {
    final schema = _singleSchema;
    if (schema == null) return;
    final rule = await showEtlRuleDialog(
      context,
      source: widget.source,
      schema: schema,
      table: table,
      existing: _etlRules[table],
    );
    if (rule == null || !mounted) return;
    setState(() {
      if (rule.isPassthrough) {
        _etlRules.remove(table);
      } else {
        _etlRules[table] = rule;
      }
    });
  }

  Widget _buildToggle({
    required bool value,
    required String title,
    required ValueChanged<bool> onChanged,
  }) {
    return InkWell(
      onTap: _running ? null : () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(
              value ? LucideIcons.squareCheck : LucideIcons.square,
              size: 14,
              color: value ? AppTheme.brandColor : AppTheme.subtleTextColor,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style: TextStyle(fontSize: 12, color: AppTheme.bodyColor),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ══════════════ 进度 / 错误 ══════════════

  Widget _buildProgress() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LinearProgressIndicator(
          value: _progress,
          minHeight: 3,
          borderRadius: BorderRadius.circular(2),
        ),
        const SizedBox(height: 8),
        Container(
          height: 110,
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: AppTheme.mutedSurfaceColor,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppTheme.borderColor),
          ),
          child: SelectionArea(
            child: ListView.builder(
              controller: _logScroll,
              itemCount: _log.length,
              itemBuilder: (context, index) => Text(
                _log[index],
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: 'Menlo',
                  color: AppTheme.bodyColor,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildError() => CopyableErrorBox(text: _error!);
}
