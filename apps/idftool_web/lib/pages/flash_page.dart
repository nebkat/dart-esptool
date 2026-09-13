import 'package:desktop_drop/desktop_drop.dart';
import 'package:esptool/esptool.dart';
import 'package:flutter/material.dart';
import 'package:idftool/idftool.dart';

import '../session/device_session.dart';
import '../session/flash_plan.dart';
import '../util/files.dart';
import '../widgets/dialogs.dart';
import '../widgets/dropdown.dart';
import '../widgets/empty_state.dart';
import '../widgets/partition_grid.dart';

/// Plan changes to the flash and write them in one go, in the bundle's
/// terms: a replacement partition table, the bootloader, an app for Factory
/// or OTA, and files or erases for named partitions. Rows take a dropped
/// or picked file; the queued operations sit at the bottom until one
/// doubly-confirmed Flash writes them — table, bootloader, Factory or OTA,
/// erases, then named writes.
///
/// Works without a device: open a partition table or bundle, or plan just
/// the bootloader and roles, and the plan is kept and re-checked when a
/// device connects. Save as bundle writes the same files a hand-made
/// bundle would contain.
class FlashPage extends StatefulWidget {
  const FlashPage({super.key, required this.session});
  final DeviceSession session;

  @override
  State<FlashPage> createState() => _FlashPageState();
}

class _FlashPageState extends State<FlashPage> {
  /// The row a drag is currently over: a partition name or a role's stem.
  String? _hoverRow;
  bool _dragging = false;
  final _rowKeys = <String, GlobalKey>{};

  /// Planning without a table was chosen explicitly.
  bool _bare = false;

  DeviceSession get session => widget.session;
  FlashPlan get plan => session.plan;

  @override
  void initState() {
    super.initState();
    plan.addListener(_rebuild);
    session.addListener(_onSessionChanged);
    _onSessionChanged();
  }

  @override
  void dispose() {
    plan.removeListener(_rebuild);
    session.removeListener(_onSessionChanged);
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  void _onSessionChanged() {
    if (!mounted) return;
    Future<void>.microtask(session.ensureLayout);
    if (!session.connected && (_hoverRow != null || _dragging)) {
      setState(() {
        _hoverRow = null;
        _dragging = false;
      });
    }
  }

  void _log(Iterable<String> notes, {bool error = false}) {
    for (final n in notes) {
      session.addLog(n, error: error);
    }
  }

  // --------------------------------------------------------------------------
  // Staging
  // --------------------------------------------------------------------------

  void _stageWrite(PartitionDefinition p, PickedFile file) {
    final replaced = plan.opFor(p.name);
    final problem = plan.stageWrite(p, file);
    if (problem != null) {
      session.addLog(problem, error: true);
      return;
    }
    final op = plan.opFor(p.name)!;
    session.addLog('Planned: write ${file.name} (${file.bytes.length.bytesString}) to ${p.name}'
        '${replaced == null ? '' : ' (replacing ${replaced.summary.toLowerCase()})'}'
        '${op.warning == null ? '' : ' — ${op.warning}'}');
  }

  void _stageRole(FlashRole role, PickedFile file) {
    final problem = plan.stageRole(role, file);
    if (problem != null) {
      session.addLog(problem, error: true);
      return;
    }
    final r = plan.roleFor(role)!;
    session.addLog('Planned: ${r.summary}${r.warning == null ? '' : ' — ${r.warning}'}');
  }

  void _stageErase(PartitionDefinition p) {
    final problem = plan.stageErase(p);
    if (problem != null) {
      session.addLog(problem, error: true);
      return;
    }
    final warning = plan.opFor(p.name)!.warning;
    session.addLog('Planned: erase ${p.name}${warning == null ? '' : ' — $warning'}');
  }

  /// Stage [file] on the row called [target]: a role's stem or a partition.
  void _stageOn(String target, PickedFile file) {
    final role = FlashRole.values.where((r) => r.fileStem == target).firstOrNull;
    if (role != null) return _stageRole(role, file);
    final p = plan.row(target);
    if (p == null) {
      session.addLog('${file.name}: no partition named "$target" — drop it onto a row to choose one', error: true);
      return;
    }
    _stageWrite(p, file);
  }

  Future<void> _pickWrite(PartitionDefinition p) async {
    final file = await pickFile();
    if (file == null || !mounted) return;
    _stageWrite(p, file);
  }

  Future<void> _pickRole(FlashRole role) async {
    final file = await pickFile(extensions: ['bin']);
    if (file == null || !mounted) return;
    _stageRole(role, file);
  }

  /// A single file dropped on a row goes there; otherwise files are matched
  /// to rows by name — the bundle convention, so a bundle's worth of files
  /// lands in one drop.
  Future<void> _stageDropped(List<DropItem> files, String? target) async {
    if (files.isEmpty) return;
    final picked = <PickedFile>[];
    for (final f in files) {
      picked.add((name: f.name, bytes: await f.readAsBytes()));
    }
    if (!mounted) return;
    if (target != null && picked.length == 1) return _stageOn(target, picked.single);
    for (final file in picked) {
      final stem = file.name.contains('.') ? file.name.substring(0, file.name.lastIndexOf('.')) : file.name;
      _stageOn(stem, file);
    }
  }

  Future<void> _stageTable() async {
    final file = await pickFile(extensions: ['csv', 'bin']);
    if (file == null || !mounted) return;
    final PartitionTable table;
    try {
      table = PartitionTable.isBinary(file.bytes)
          ? PartitionTable.fromBinary(file.bytes)
          : parsePartitionTableCsv(PartitionTable.decodeCsv(file.bytes),
              source: file.name, partitionTableOffset: plan.partitionTableOffset, primaryBootloaderOffset: plan.primaryBootloaderOffset);
    } catch (e) {
      session.addLog('Could not parse ${file.name}: $e', error: true);
      return;
    }
    _log(plan.stageTable(table, source: file.name), error: true);
    session.addLog('Planned: replace partition table with ${file.name}'
        '${plan.stagedTableProblem == null ? '' : ' — VERIFICATION FAILED: ${plan.stagedTableProblem}'}');
  }

  Future<void> _loadBundle() async {
    final file = await pickFile(extensions: ['zip']);
    if (file == null || !mounted) return;
    try {
      _log(plan.loadBundle(file.bytes, source: file.name), error: true);
    } on IdfToolException catch (e) {
      session.addLog('${file.name}: ${e.message}', error: true);
      return;
    } catch (e) {
      session.addLog('${file.name}: $e', error: true);
      return;
    }
    session.addLog('Planned from bundle ${file.name}: ${plan.length} operation${plan.length == 1 ? '' : 's'}');
    setState(() => _bare = true);
  }

  Future<void> _saveBundle() async {
    final erases = plan.ops.where((op) => !op.isWrite).length;
    if (erases > 0) session.addLog('Bundle saved without $erases erase${erases == 1 ? '' : 's'}; bundles only carry files');
    await saveBytes('${session.connected ? session.deviceStem : 'plan'}.zip', plan.toBundle(), mimeType: 'application/zip');
  }

  // --------------------------------------------------------------------------
  // Drag and drop
  // --------------------------------------------------------------------------

  /// The row under [global], if any. Cells are shorter than rows, so a row
  /// claims the half-pitch either side of its centre.
  String? _rowAt(Offset global) {
    final centres = <(String, double)>[];
    for (final MapEntry(key: name, value: key) in _rowKeys.entries) {
      final box = key.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) continue;
      centres.add((name, box.localToGlobal(Offset.zero).dy + box.size.height / 2));
    }
    if (centres.isEmpty) return null;
    centres.sort((a, b) => a.$2.compareTo(b.$2));
    final pitch = centres.length > 1 ? (centres[1].$2 - centres[0].$2).abs() : 48.0;
    String? best;
    var bestDistance = double.infinity;
    for (final (name, cy) in centres) {
      final d = (global.dy - cy).abs();
      if (d < bestDistance) {
        bestDistance = d;
        best = name;
      }
    }
    return bestDistance <= pitch / 2 ? best : null;
  }

  void _onDragUpdated(DropEventDetails d) {
    final row = _rowAt(d.globalPosition);
    if (row != _hoverRow || !_dragging) {
      setState(() {
        _hoverRow = row;
        _dragging = true;
      });
    }
  }

  void _onDragExited(DropEventDetails d) {
    if (_hoverRow != null || _dragging) {
      setState(() {
        _hoverRow = null;
        _dragging = false;
      });
    }
  }

  void _onDragDone(DropDoneDetails d) {
    final target = _rowAt(d.globalPosition);
    setState(() {
      _hoverRow = null;
      _dragging = false;
    });
    _stageDropped(d.files, target);
  }

  // --------------------------------------------------------------------------
  // Flash
  // --------------------------------------------------------------------------

  /// Flash the plan in bundle order: table, bootloader, Factory or OTA,
  /// erases, named writes — each leaving the plan as it completes so a
  /// failure leaves exactly what is left.
  Future<void> _flash() async {
    if (plan.isEmpty || !session.connected) return;
    final table = plan.stagedTable;
    final bootloader = plan.bootloaderOp;
    final roles = plan.roles.toList();
    final ops = plan.orderedOps.where((op) => !op.partition.isPrimaryBootloader).toList();
    final erases = ops.where((op) => !op.isWrite).toList();
    final writes = ops.where((op) => op.isWrite).toList();
    final lines = [
      if (table != null)
        '${'partition_table'.padRight(16)} ${plan.partitionTableOffset.hex.padLeft(10)}  Replace with ${plan.stagedTableSource}'
            '${plan.stagedTableProblem == null ? '' : '   ⚠ VERIFICATION FAILED: ${plan.stagedTableProblem}'}',
      if (bootloader != null) _opLine(bootloader),
      for (final r in roles) '${r.role.fileStem.padRight(16)} ${''.padLeft(10)}  ${r.summary}${r.warning == null ? '' : '   ⚠ ${r.warning}'}',
      for (final op in erases) _opLine(op),
      for (final op in writes) _opLine(op),
    ];
    final count = plan.length;
    final noun = 'operation${count == 1 ? '' : 's'}';
    if (!await confirm(context,
        title: 'Flash $count $noun?',
        message: '${lines.join('\n')}\n\n'
            '${table == null ? '' : 'The table is written first; it only replaces the map — existing data is not moved or erased. '}'
            'Writes skip sectors already holding the same data.',
        action: 'Flash…')) {
      return;
    }
    if (!mounted) return;
    if (!await confirm(context,
        title: 'Really flash ${session.chip!.name} ${session.macString ?? ''}?',
        message: 'This changes the connected device and cannot be undone.'
            '${plan.warningCount == 0 ? '' : '\n\n${plan.warningCount} of the operations carry warnings — check them above.'}',
        action: 'Flash now',
        destructive: true)) {
      return;
    }
    await session.runDevice('Flash $count $noun', (device) async {
      if (table != null) {
        await device.writePartitionTable(table, force: true);
        session.addLog('partition_table: written');
        plan.tableFlashed();
      }
      if (bootloader != null) {
        final outcome = await device.writePartition(bootloader.partition.name, bootloader.file!.bytes, onProgress: session.reportProgress);
        session.addLog('bootloader: ${_describe(outcome)}');
        plan.unstage(bootloader.partition.name);
      }
      for (final r in roles) {
        switch (r.role) {
          case FlashRole.factory:
            final outcome = await device.factory(r.file.bytes, onProgress: session.reportProgress);
            session.addLog('factory: ${_describe(outcome)}; OTA selection cleared');
          case FlashRole.ota:
            final result = await device.ota(r.file.bytes, onProgress: session.reportProgress);
            session.addLog('ota: ${result.partition.name} ${_describe(result.outcome)}; boot switched to it');
        }
        plan.unstageRole(r.role);
      }
      for (final op in [...erases, ...writes]) {
        final name = op.partition.name;
        switch (op.kind) {
          case OpKind.erase:
            await device.erasePartition(name);
            session.addLog('$name: erased ${op.partition.size.bytesString}');
          case OpKind.write:
            final outcome = await device.writePartition(name, op.file!.bytes, onProgress: session.reportProgress);
            session.addLog('$name: ${_describe(outcome)}');
        }
        plan.unstage(name);
      }
    });
    await session.readLayout();
  }

  static String _opLine(PlannedOp op) => '${op.partition.name.padRight(16)} ${op.partition.offset.hex.padLeft(10)}  ${op.summary}${op.warning == null ? '' : '   ⚠ ${op.warning}'}';

  static String _describe(WriteOutcome o) => o.skipped
      ? 'already in flash, nothing written'
      : 'wrote ${o.written.bytesString} in ${o.runs} region${o.runs == 1 ? '' : 's'} in ${(o.elapsed.inMilliseconds / 1000).toStringAsFixed(1)} s'
          '${o.abandoned ? ' (comparison abandoned part-way)' : ''}';

  // --------------------------------------------------------------------------
  // Build
  // --------------------------------------------------------------------------

  /// The chip picker for offline planning (it fixes the bootloader offset).
  Widget _chipPicker() => AppDropdown<EspChip?>(
        value: plan.chip,
        label: 'Chip',
        hint: 'Unknown (no bootloader)',
        width: 260,
        entries: [
          const DropdownMenuEntry(value: null, label: 'Unknown (no bootloader)'),
          for (final c in EspChip.values) DropdownMenuEntry(value: c, label: c.name),
        ],
        onSelected: plan.setChip,
      );

  Color? _rowColor(String name, ColorScheme scheme, {required bool planned}) => _hoverRow == name
      ? scheme.primaryContainer
      : planned
          ? scheme.tertiaryContainer.withValues(alpha: 0.35)
          : null;

  @override
  Widget build(BuildContext context) {
    final offline = !session.connected;
    final table = plan.table;
    final busy = session.busy;
    final scheme = Theme.of(context).colorScheme;
    if (table == null) {
      if (session.connected && busy && plan.deviceTable == null) return const LoadingState('Reading the partition table…');
      if (offline && !_bare && plan.isEmpty) {
        return EmptyState.noDevice(
          message: 'Connect a device to plan changes to its flash, or open a partition table or bundle to plan without one. '
              'The bootloader, Factory and OTA can be planned with no table at all.',
          actions: [
            FilledButton.tonalIcon(onPressed: _stageTable, icon: const Icon(Icons.table_chart_outlined), label: const Text('Open partition table…')),
            FilledButton.tonalIcon(onPressed: _loadBundle, icon: const Icon(Icons.unarchive_outlined), label: const Text('Open bundle…')),
            FilledButton.tonalIcon(onPressed: () => setState(() => _bare = true), icon: const Icon(Icons.flash_on), label: const Text('Plan without a table')),
            _chipPicker(),
          ],
        );
      }
    }
    return ListView(padding: const EdgeInsets.all(16), children: [
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        if (offline) _chipPicker(),
        FilledButton.tonalIcon(onPressed: _stageTable, icon: const Icon(Icons.table_chart_outlined), label: Text(table == null ? 'Open partition table…' : 'Replace table…')),
        FilledButton.tonalIcon(onPressed: _loadBundle, icon: const Icon(Icons.unarchive_outlined), label: Text(table == null ? 'Open bundle…' : 'Load bundle…')),
        MenuAnchor(
          builder: (context, controller, _) => OutlinedButton.icon(
            onPressed: table == null ? null : () => controller.isOpen ? controller.close() : controller.open(),
            icon: const Icon(Icons.download),
            label: const Text('Table'),
          ),
          menuChildren: [
            MenuItemButton(onPressed: () => saveText('partitions.csv', table!.toCsv(), mimeType: 'text/csv'), child: const Text('Save as CSV')),
            MenuItemButton(onPressed: () => saveBytes('partition-table.bin', table!.toBinary()), child: const Text('Save as binary')),
            MenuItemButton(onPressed: () => showText(context, title: 'Partition table', text: table!.format()), child: const Text('Show as text')),
          ],
        ),
      ]),
      const SizedBox(height: 12),
      if (plan.stagedTable != null)
        MaterialBanner(
          backgroundColor: plan.stagedTableProblem == null ? scheme.tertiaryContainer : scheme.errorContainer,
          leading: Icon(plan.stagedTableProblem == null ? Icons.table_chart : Icons.error_outline),
          content: Text(plan.stagedTableProblem == null
              ? 'Planning on the staged table from ${plan.stagedTableSource}.'
                  '${offline ? '' : ' The device keeps its own table until you flash; rows marked new, moved or resized are not where the device thinks they are.'}'
              : 'Staged table from ${plan.stagedTableSource} FAILED verification: ${plan.stagedTableProblem}'),
          actions: [TextButton(onPressed: () => _log(plan.unstageTable(), error: true), child: const Text('Discard table'))],
        )
      else if (table == null && session.connected && !busy)
        MaterialBanner(
          backgroundColor: scheme.errorContainer,
          leading: const Icon(Icons.error_outline),
          content: const Text('The partition table could not be read — see the log. Only the bootloader, Factory and OTA can be planned.'),
          actions: [TextButton(onPressed: session.readLayout, child: const Text('Try again'))],
        )
      else
        Row(children: [
          Icon(Icons.file_download_outlined, size: 18, color: scheme.outline),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
                'Drag files onto rows, or use Write… and Erase, to queue operations. '
                'Several files dropped at once are matched to rows by name, the way a bundle is. Nothing touches the device until you flash.',
                style: TextStyle(color: scheme.outline)),
          ),
        ]),
      const SizedBox(height: 12),
      DropTarget(
        onDragUpdated: _onDragUpdated,
        onDragExited: _onDragExited,
        onDragDone: _onDragDone,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _targets(scheme),
          const SizedBox(height: 12),
          if (table != null)
            PartitionGrid(
              rows: plan.rows,
              table: table,
              activeSlot: plan.stagedTable == null ? plan.otadata?.slot : null,
              highlighted: _dragging,
              rowKey: (p) => _rowKeys.putIfAbsent(p.name, GlobalKey.new),
              rowColor: (p) => _rowColor(p.name, scheme, planned: plan.opFor(p.name) != null),
              contents: (p) => _contents(p, scheme),
              extraColumn: 'Planned',
              extra: (p) => _plannedCell(p.name, plan.opFor(p.name)?.summary, plan.opFor(p.name)?.warning, at: p.offset.hex, onRemove: () => plan.unstage(p.name)),
              actions: (p) => [
                if (p.isPrimaryPartitionTable)
                  TextButton.icon(onPressed: _stageTable, icon: const Icon(Icons.table_chart_outlined, size: 18), label: const Text('Replace…'))
                else ...[
                  TextButton.icon(onPressed: () => _pickWrite(p), icon: const Icon(Icons.upload_file, size: 18), label: const Text('Write…')),
                  TextButton.icon(
                      onPressed: () => _stageErase(p),
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('Erase'),
                      style: TextButton.styleFrom(foregroundColor: scheme.error)),
                ],
              ],
            ),
        ]),
      ),
      const SizedBox(height: 16),
      _PlanPanel(
          plan: plan,
          busy: busy,
          offline: offline,
          onFlash: _flash,
          onSaveBundle: _saveBundle,
          onClear: plan.clear,
          onRemove: plan.unstage,
          onRemoveRole: plan.unstageRole,
          onDiscardTable: () => _log(plan.unstageTable(), error: true)),
    ]);
  }

  /// The role rows — Factory and OTA — and, with no table, the bootloader:
  /// targets that exist regardless of any partition table.
  Widget _targets(ColorScheme scheme) {
    final table = plan.table;
    final bootloader = table == null ? plan.rows.where((p) => p.isPrimaryBootloader).firstOrNull : null;
    return Card(
      shape: _dragging ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(4), side: BorderSide(color: scheme.primary, width: 2)) : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text('Targets', style: Theme.of(context).textTheme.titleSmall?.copyWith(color: scheme.outline)),
        ),
        for (final role in FlashRole.values)
          _targetRow(
            name: role.fileStem,
            title: 'App → ${role.label}',
            description: role.description,
            planned: plan.roleFor(role)?.summary,
            warning: plan.roleFor(role)?.warning,
            onPick: () => _pickRole(role),
            onRemove: () => plan.unstageRole(role),
            scheme: scheme,
          ),
        if (bootloader != null)
          _targetRow(
            name: bootloader.name,
            title: 'Bootloader',
            description: 'Write at ${bootloader.offset.hex}, the ${plan.chip?.name ?? 'chip'}\'s bootloader offset',
            planned: plan.opFor(bootloader.name)?.summary,
            warning: plan.opFor(bootloader.name)?.warning,
            onPick: () => _pickWrite(bootloader),
            onRemove: () => plan.unstage(bootloader.name),
            scheme: scheme,
          ),
        const SizedBox(height: 4),
      ]),
    );
  }

  Widget _targetRow({
    required String name,
    required String title,
    required String description,
    required String? planned,
    required String? warning,
    required VoidCallback onPick,
    required VoidCallback onRemove,
    required ColorScheme scheme,
  }) =>
      Container(
        key: _rowKeys.putIfAbsent(name, GlobalKey.new),
        color: _rowColor(name, scheme, planned: planned != null),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(children: [
          SizedBox(width: 180, child: Text(title, style: const TextStyle(fontFamily: 'RobotoMono', fontSize: 13))),
          Expanded(child: Text(description, style: TextStyle(color: scheme.outline))),
          const SizedBox(width: 16),
          _plannedCell(name, planned, warning, at: null, onRemove: onRemove),
          const SizedBox(width: 16),
          TextButton.icon(onPressed: onPick, icon: const Icon(Icons.upload_file, size: 18), label: const Text('Write…')),
        ]),
      );

  /// What the device holds at this row, or, on a staged table, how the row
  /// differs from the device.
  Widget _contents(PartitionDefinition p, ColorScheme scheme) {
    final device = plan.deviceTable;
    if (plan.stagedTable != null && device != null && !p.isPrimaryBootloader && !p.isPrimaryPartitionTable) {
      final was = device.findByName(p.name);
      final note = was == null
          ? 'new'
          : was.offset != p.offset
              ? 'moved from ${was.offset.hex}'
              : was.size != p.size
                  ? 'resized from ${was.size.bytesString}'
                  : null;
      if (note != null) return Text(note, style: TextStyle(color: scheme.error, fontStyle: FontStyle.italic));
    }
    return Text(appContents(plan.deviceApps, p));
  }

  Widget _plannedCell(String name, String? planned, String? warning, {required String? at, required VoidCallback onRemove}) {
    final scheme = Theme.of(context).colorScheme;
    if (_hoverRow == name) return Text('Drop to write', style: TextStyle(color: scheme.primary, fontStyle: FontStyle.italic));
    if (planned == null) return _dragging ? const SizedBox.shrink() : Text('—', style: TextStyle(color: scheme.outlineVariant));
    return InputChip(
      avatar: Icon(warning != null ? Icons.warning_amber : (planned.startsWith('Erase') ? Icons.delete_outline : Icons.upload_file),
          size: 18, color: warning != null ? scheme.error : null),
      label: Text(planned),
      tooltip: warning ?? (at == null ? planned : '$planned at $at'),
      onDeleted: onRemove,
      deleteButtonTooltipMessage: 'Remove from plan',
    );
  }
}

/// The queued operations, in flash order, with the button that runs them.
class _PlanPanel extends StatelessWidget {
  const _PlanPanel({
    required this.plan,
    required this.busy,
    required this.offline,
    required this.onFlash,
    required this.onSaveBundle,
    required this.onClear,
    required this.onRemove,
    required this.onRemoveRole,
    required this.onDiscardTable,
  });
  final FlashPlan plan;
  final bool busy;
  final bool offline;
  final VoidCallback onFlash;
  final VoidCallback onSaveBundle;
  final VoidCallback onClear;
  final ValueChanged<String> onRemove;
  final ValueChanged<FlashRole> onRemoveRole;
  final VoidCallback onDiscardTable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bootloader = plan.bootloaderOp;
    final ops = plan.orderedOps.where((op) => !op.partition.isPrimaryBootloader).toList();
    final erases = ops.where((op) => !op.isWrite).toList();
    final writes = ops.where((op) => op.isWrite).toList();
    final count = plan.length;
    final bundleable = writes.isNotEmpty || bootloader != null || plan.roles.isNotEmpty || plan.stagedTable != null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Planned operations', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(plan.addressing, style: TextStyle(color: scheme.outline)),
          const SizedBox(height: 8),
          if (plan.isEmpty)
            Text('Nothing planned yet.', style: TextStyle(color: scheme.outline))
          else ...[
            if (plan.stagedTable != null)
              _OpTile(
                icon: plan.stagedTableProblem == null ? Icons.table_chart : Icons.error_outline,
                name: 'partition_table',
                detail: plan.partitionTableOffset.hex,
                summary: 'Replace with ${plan.stagedTableSource} (written first)',
                warning: plan.stagedTableProblem == null ? null : 'Verification failed: ${plan.stagedTableProblem}',
                onRemove: onDiscardTable,
              ),
            if (bootloader != null)
              _OpTile(
                  icon: Icons.upload_file,
                  name: bootloader.partition.name,
                  detail: bootloader.partition.offset.hex,
                  summary: bootloader.summary,
                  warning: bootloader.warning,
                  onRemove: () => onRemove(bootloader.partition.name)),
            for (final r in plan.roles)
              _OpTile(
                  icon: Icons.system_update_alt,
                  name: r.role.fileStem,
                  detail: r.role.label,
                  summary: 'Write ${r.file.name} (${r.file.bytes.length.bytesString}) — ${r.role.description.toLowerCase()}',
                  warning: r.warning,
                  onRemove: () => onRemoveRole(r.role)),
            for (final op in erases)
              _OpTile(
                  icon: Icons.delete_outline,
                  name: op.partition.name,
                  detail: op.partition.offset.hex,
                  summary: op.summary,
                  warning: op.warning,
                  onRemove: () => onRemove(op.partition.name)),
            for (final op in writes)
              _OpTile(
                  icon: Icons.upload_file,
                  name: op.partition.name,
                  detail: op.partition.offset.hex,
                  summary: op.summary,
                  warning: op.warning,
                  onRemove: () => onRemove(op.partition.name)),
          ],
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: Text(
                plan.isEmpty
                    ? ''
                    : '$count operation${count == 1 ? '' : 's'}, ${plan.bytesToWrite.bytesString} to write'
                        '${plan.warningCount == 0 ? '' : ', ${plan.warningCount} with warnings'}',
                style: TextStyle(color: scheme.outline),
              ),
            ),
            TextButton.icon(onPressed: plan.isEmpty || busy ? null : onClear, icon: const Icon(Icons.clear_all), label: const Text('Clear plan')),
            const SizedBox(width: 8),
            OutlinedButton.icon(onPressed: bundleable ? onSaveBundle : null, icon: const Icon(Icons.archive_outlined), label: const Text('Save as bundle')),
            const SizedBox(width: 16),
            FilledButton.icon(
              onPressed: plan.isEmpty || busy || offline ? null : onFlash,
              style: FilledButton.styleFrom(
                backgroundColor: scheme.error,
                foregroundColor: scheme.onError,
                padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
                textStyle: theme.textTheme.titleMedium,
              ),
              icon: const Icon(Icons.flash_on),
              label: Text(offline
                  ? 'Connect a device to flash'
                  : plan.isEmpty
                      ? 'Flash'
                      : 'Flash $count operation${count == 1 ? '' : 's'}'),
            ),
          ]),
        ]),
      ),
    );
  }
}

class _OpTile extends StatelessWidget {
  const _OpTile({required this.icon, required this.name, required this.detail, required this.summary, this.warning, required this.onRemove});
  final IconData icon;
  final String name;
  final String detail;
  final String summary;
  final String? warning;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(warning == null ? icon : Icons.warning_amber, color: warning == null ? null : scheme.error),
      title: Row(children: [
        SizedBox(width: 160, child: Text(name, style: const TextStyle(fontFamily: 'RobotoMono', fontSize: 13))),
        SizedBox(width: 100, child: Text(detail, style: const TextStyle(fontFamily: 'RobotoMono', fontSize: 13))),
        Expanded(child: Text(summary)),
      ]),
      subtitle: warning == null ? null : Text(warning!, style: TextStyle(color: scheme.error)),
      trailing: IconButton(tooltip: 'Remove from plan', icon: const Icon(Icons.close, size: 18), onPressed: onRemove),
    );
  }
}
