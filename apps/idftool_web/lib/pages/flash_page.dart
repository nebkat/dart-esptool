import 'package:desktop_drop/desktop_drop.dart';
import 'package:esptool/esptool.dart';
import 'package:flutter/material.dart';
import 'package:idftool/idftool.dart';

import '../session/device_session.dart';
import '../session/flash_plan.dart';
import '../util/files.dart';
import '../widgets/dialogs.dart';
import '../widgets/partition_grid.dart';
import '../widgets/dropdown.dart';

/// Plan changes to the flash and write them in one go.
///
/// Rows take an erase or a file to write (dropped or picked); a replacement
/// partition table or a whole bundle can be staged; the queued operations
/// sit at the bottom until one doubly-confirmed Flash writes them — table
/// first, then erases, then writes.
///
/// Works without a device: open a partition table or bundle, pick the chip
/// for the bootloader row, and the plan is kept and re-checked when a
/// device connects.
class FlashPage extends StatefulWidget {
  const FlashPage({super.key, required this.session});
  final DeviceSession session;

  @override
  State<FlashPage> createState() => _FlashPageState();
}

class _FlashPageState extends State<FlashPage> {
  /// The row a drag is currently over, by partition name.
  String? _hoverRow;
  bool _dragging = false;
  final _rowKeys = <String, GlobalKey>{};

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

  void _stageErase(PartitionDefinition p) {
    final problem = plan.stageErase(p);
    if (problem != null) {
      session.addLog(problem, error: true);
      return;
    }
    final warning = plan.opFor(p.name)!.warning;
    session.addLog('Planned: erase ${p.name}${warning == null ? '' : ' — $warning'}');
  }

  Future<void> _pickWrite(PartitionDefinition p) async {
    final file = await pickFile();
    if (file == null || !mounted) return;
    _stageWrite(p, file);
  }

  /// A single file dropped on a row goes there; otherwise files are matched
  /// to rows by name, so a folder's worth of `<name>.bin` lands in one drop.
  Future<void> _stageDropped(List<DropItem> files, PartitionDefinition? target) async {
    if (plan.table == null || files.isEmpty) return;
    final picked = <PickedFile>[];
    for (final f in files) {
      picked.add((name: f.name, bytes: await f.readAsBytes()));
    }
    if (!mounted) return;
    if (target != null && picked.length == 1) {
      _stageWrite(target, picked.single);
      return;
    }
    for (final file in picked) {
      final stem = file.name.contains('.') ? file.name.substring(0, file.name.lastIndexOf('.')) : file.name;
      final match = plan.row(stem);
      if (match == null) {
        session.addLog('${file.name}: no partition named "$stem" — drop it onto a row to choose one', error: true);
        continue;
      }
      _stageWrite(match, file);
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
    } on FormatException catch (e) {
      session.addLog(e.message, error: true);
      return;
    }
    session.addLog('Planned from bundle ${file.name}: ${plan.length} operation${plan.length == 1 ? '' : 's'}');
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
  PartitionDefinition? _rowAt(Offset global) {
    final centres = <(PartitionDefinition, double)>[];
    for (final p in plan.rows) {
      final box = _rowKeys[p.name]?.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) continue;
      centres.add((p, box.localToGlobal(Offset.zero).dy + box.size.height / 2));
    }
    if (centres.isEmpty) return null;
    final pitch = centres.length > 1 ? (centres[1].$2 - centres[0].$2).abs() : 48.0;
    PartitionDefinition? best;
    var bestDistance = double.infinity;
    for (final (p, cy) in centres) {
      final d = (global.dy - cy).abs();
      if (d < bestDistance) {
        bestDistance = d;
        best = p;
      }
    }
    return bestDistance <= pitch / 2 ? best : null;
  }

  void _onDragUpdated(DropEventDetails d) {
    final row = _rowAt(d.globalPosition)?.name;
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

  /// Flash the plan: table first, then erases, then writes, each leaving
  /// the plan as it completes so a failure leaves exactly what is left.
  Future<void> _flash() async {
    if (plan.isEmpty || !session.connected) return;
    final table = plan.stagedTable;
    final ops = plan.orderedOps;
    final erases = ops.where((op) => !op.isWrite).toList();
    final writes = ops.where((op) => op.isWrite).toList();
    final lines = [
      if (table != null)
        '${'partition_table'.padRight(16)} ${plan.partitionTableOffset.hex.padLeft(10)}  Replace with ${plan.stagedTableSource}'
            '${plan.stagedTableProblem == null ? '' : '   ⚠ VERIFICATION FAILED: ${plan.stagedTableProblem}'}',
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

  Widget _start() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Connect a device to plan changes to its flash, or open a partition table or bundle to plan without one.'),
            const SizedBox(height: 16),
            Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              FilledButton.tonalIcon(onPressed: _stageTable, icon: const Icon(Icons.table_chart_outlined), label: const Text('Open partition table…')),
              FilledButton.tonalIcon(onPressed: _loadBundle, icon: const Icon(Icons.unarchive_outlined), label: const Text('Open bundle…')),
              _chipPicker(),
            ]),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final offline = !session.connected;
    final table = plan.table;
    final busy = session.busy;
    final scheme = Theme.of(context).colorScheme;
    if (table == null) {
      if (offline) return _start();
      return busy
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text('Could not read the partition table — see the log.', style: TextStyle(color: scheme.error)),
                const SizedBox(height: 8),
                Wrap(spacing: 8, children: [
                  FilledButton.tonalIcon(onPressed: session.readLayout, icon: const Icon(Icons.refresh), label: const Text('Try again')),
                  OutlinedButton.icon(onPressed: _stageTable, icon: const Icon(Icons.table_chart_outlined), label: const Text('Open partition table…')),
                ]),
              ]),
            );
    }
    return ListView(padding: const EdgeInsets.all(16), children: [
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        if (offline) _chipPicker(),
        FilledButton.tonalIcon(onPressed: _stageTable, icon: const Icon(Icons.table_chart_outlined), label: const Text('Replace table…')),
        FilledButton.tonalIcon(onPressed: _loadBundle, icon: const Icon(Icons.unarchive_outlined), label: const Text('Load bundle…')),
        MenuAnchor(
          builder: (context, controller, _) => OutlinedButton.icon(
            onPressed: () => controller.isOpen ? controller.close() : controller.open(),
            icon: const Icon(Icons.download),
            label: const Text('Table'),
          ),
          menuChildren: [
            MenuItemButton(onPressed: () => saveText('partitions.csv', table.toCsv(), mimeType: 'text/csv'), child: const Text('Save as CSV')),
            MenuItemButton(onPressed: () => saveBytes('partition-table.bin', table.toBinary()), child: const Text('Save as binary')),
            MenuItemButton(onPressed: () => showText(context, title: 'Partition table', text: table.format()), child: const Text('Show as text')),
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
      else
        Row(children: [
          Icon(Icons.file_download_outlined, size: 18, color: scheme.outline),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
                'Drag files onto rows, or use Write… and Erase, to queue operations. '
                'Several files dropped at once are matched to rows by name. Nothing touches the device until you flash.',
                style: TextStyle(color: scheme.outline)),
          ),
        ]),
      const SizedBox(height: 12),
      DropTarget(
        onDragUpdated: _onDragUpdated,
        onDragExited: _onDragExited,
        onDragDone: _onDragDone,
        child: PartitionGrid(
          rows: plan.rows,
          table: table,
          activeSlot: plan.stagedTable == null ? plan.otadata?.slot : null,
          highlighted: _dragging,
          rowKey: (p) => _rowKeys.putIfAbsent(p.name, GlobalKey.new),
          rowColor: (p) => _hoverRow == p.name
              ? scheme.primaryContainer
              : plan.opFor(p.name) != null
                  ? scheme.tertiaryContainer.withValues(alpha: 0.35)
                  : null,
          contents: (p) => _contents(p, scheme),
          extraColumn: 'Planned',
          extra: (p) => _plannedCell(p, scheme),
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
          onDiscardTable: () => _log(plan.unstageTable(), error: true)),
    ]);
  }

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

  Widget _plannedCell(PartitionDefinition p, ColorScheme scheme) {
    final op = plan.opFor(p.name);
    if (_hoverRow == p.name) return Text('Drop to write', style: TextStyle(color: scheme.primary, fontStyle: FontStyle.italic));
    if (op == null) return _dragging ? const SizedBox.shrink() : Text('—', style: TextStyle(color: scheme.outlineVariant));
    return InputChip(
      avatar: Icon(
        op.warning != null ? Icons.warning_amber : (op.isWrite ? Icons.upload_file : Icons.delete_outline),
        size: 18,
        color: op.warning != null ? scheme.error : null,
      ),
      label: Text(op.summary),
      tooltip: op.warning ?? '${op.summary} at ${p.offset.hex}',
      onDeleted: () => plan.unstage(p.name),
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
    required this.onDiscardTable,
  });
  final FlashPlan plan;
  final bool busy;
  final bool offline;
  final VoidCallback onFlash;
  final VoidCallback onSaveBundle;
  final VoidCallback onClear;
  final ValueChanged<String> onRemove;
  final VoidCallback onDiscardTable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ops = plan.orderedOps;
    final erases = ops.where((op) => !op.isWrite).toList();
    final writes = ops.where((op) => op.isWrite).toList();
    final count = plan.length;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Planned operations', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          if (plan.isEmpty)
            Text('Nothing planned yet.', style: TextStyle(color: scheme.outline))
          else ...[
            if (plan.stagedTable != null)
              _OpTile(
                icon: plan.stagedTableProblem == null ? Icons.table_chart : Icons.error_outline,
                name: 'partition_table',
                offset: plan.partitionTableOffset,
                summary: 'Replace with ${plan.stagedTableSource} (written first)',
                warning: plan.stagedTableProblem == null ? null : 'Verification failed: ${plan.stagedTableProblem}',
                onRemove: onDiscardTable,
              ),
            for (final op in erases)
              _OpTile(
                  icon: Icons.delete_outline,
                  name: op.partition.name,
                  offset: op.partition.offset,
                  summary: op.summary,
                  warning: op.warning,
                  onRemove: () => onRemove(op.partition.name)),
            for (final op in writes)
              _OpTile(
                  icon: Icons.upload_file,
                  name: op.partition.name,
                  offset: op.partition.offset,
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
            OutlinedButton.icon(
                onPressed: writes.isEmpty && plan.stagedTable == null ? null : onSaveBundle, icon: const Icon(Icons.archive_outlined), label: const Text('Save as bundle')),
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
  const _OpTile({required this.icon, required this.name, required this.offset, required this.summary, this.warning, required this.onRemove});
  final IconData icon;
  final String name;
  final int offset;
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
        SizedBox(width: 100, child: Text(offset.hex, style: const TextStyle(fontFamily: 'RobotoMono', fontSize: 13))),
        Expanded(child: Text(summary)),
      ]),
      subtitle: warning == null ? null : Text(warning!, style: TextStyle(color: scheme.error)),
      trailing: IconButton(tooltip: 'Remove from plan', icon: const Icon(Icons.close, size: 18), onPressed: onRemove),
    );
  }
}
