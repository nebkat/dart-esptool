import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:esptool/esptool.dart';
import 'package:flutter/material.dart';
import 'package:idftool/idftool.dart';

import '../session/device_session.dart';
import '../session/flash_plan.dart';
import '../util/files.dart';
import '../widgets/dialogs.dart';
import '../widgets/type_chip.dart';

/// The device's flash layout — bootloader, partition table and partitions —
/// and the plan of changes to it.
///
/// Viewing: each row dumps to a file, and NVS rows open in the NVS tool.
/// Planning: rows take an erase or a file to write (dropped or picked), a
/// replacement table or a whole bundle can be staged, and the queued
/// operations sit at the bottom until one doubly-confirmed Flash writes them
/// — table first, then erases, then writes.
class PartitionsPage extends StatefulWidget {
  const PartitionsPage({super.key, required this.session, this.onOpenNvs});
  final DeviceSession session;

  /// Called with a partition name to open it in the NVS tool.
  final ValueChanged<String>? onOpenNvs;

  @override
  State<PartitionsPage> createState() => _PartitionsPageState();
}

class _PartitionsPageState extends State<PartitionsPage> {
  OtaDataParameters? _otadata;

  /// App descriptors read from the device, by partition offset.
  final _apps = <int, AppDescription>{};
  bool _loadedFor = false;
  bool _planning = false;

  /// The row a drag is currently over, by partition name.
  String? _hoverRow;
  bool _dragging = false;
  final _rowKeys = <String, GlobalKey>{};

  DeviceSession get session => widget.session;
  FlashPlan get plan => session.plan;

  @override
  void initState() {
    super.initState();
    plan.addListener(_onPlanChanged);
  }

  @override
  void dispose() {
    plan.removeListener(_onPlanChanged);
    super.dispose();
  }

  void _onPlanChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (session.connected && !_loadedFor && !session.busy) {
      _loadedFor = true;
      _refresh();
    }
    if (!session.connected) {
      _loadedFor = false;
      _otadata = null;
      _apps.clear();
      _planning = false;
      _hoverRow = null;
      _dragging = false;
    }
  }

  void _log(Iterable<String> notes, {bool error = false}) {
    for (final n in notes) {
      session.addLog(n, error: error);
    }
  }

  Future<void> _refresh() async {
    await session.runDevice('Read partition table', (device) async {
      final table = await device.partitionTable(refresh: true);
      OtaDataParameters? otadata;
      try {
        otadata = (await device.readOtadata()).otadata;
      } on IdfToolException {
        // no OTA layout on this table
      }
      // The app descriptor sits right after the image header and the first
      // segment header, so a small read per app partition names the firmware.
      final apps = <int, AppDescription>{};
      for (final p in table.where((p) => p.isApp)) {
        final head = await device.loader.readFlash(p.offset, ImageHeader.size + 8 + AppDescription.size);
        final desc = AppDescription.fromBytesOrNull(Uint8List.sublistView(head, ImageHeader.size + 8));
        if (desc != null) apps[p.offset] = desc;
      }
      if (!mounted) return;
      setState(() {
        _otadata = otadata;
        _apps
          ..clear()
          ..addAll(apps);
      });
      _log(plan.setDeviceTable(table), error: true);
    });
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
    setState(() => _planning = true);
  }

  void _stageErase(PartitionDefinition p) {
    final problem = plan.stageErase(p);
    if (problem != null) {
      session.addLog(problem, error: true);
      return;
    }
    session.addLog('Planned: erase ${p.name}${plan.opFor(p.name)!.warning == null ? '' : ' — ${plan.opFor(p.name)!.warning}'}');
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
    setState(() => _planning = true);
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
    setState(() => _planning = true);
  }

  Future<void> _saveBundle() async {
    final erases = plan.ops.where((op) => !op.isWrite).length;
    if (erases > 0) session.addLog('Bundle saved without $erases erase${erases == 1 ? '' : 's'}; bundles only carry files');
    await saveBytes('${_deviceStem()}-plan.zip', plan.toBundle(), mimeType: 'application/zip');
  }

  String _deviceStem() => '${session.chip!.name.toLowerCase()}-${session.macString?.replaceAll(':', '') ?? 'device'}';

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
  // Device operations
  // --------------------------------------------------------------------------

  Future<void> _dump(PartitionDefinition p) async {
    final data = await session.runDevice(
        'Dump ${p.name}', (device) => device.loader.readFlash(p.offset, p.size, onProgress: (done, total) => session.reportProgress('Reading ${p.name}', done, total)));
    if (data != null) await saveBytes('${p.name}.bin', data);
  }

  /// Every row on the device, virtual ones included, as a bundle.
  Future<void> _dumpBundle() async {
    final zip = await session.runDevice('Dump bundle', (device) async {
      final archive = Archive();
      for (final p in plan.deviceRows) {
        final data = await device.loader.readFlash(p.offset, p.size, onProgress: (done, total) => session.reportProgress('Reading ${p.name}', done, total));
        archive.add(ArchiveFile.bytes('${p.name}.bin', data));
      }
      archive.add(ArchiveFile.string('partition_table.csv', plan.deviceTable!.toCsv()));
      return ZipEncoder().encodeBytes(archive);
    });
    if (zip != null) await saveBytes('${_deviceStem()}.zip', zip, mimeType: 'application/zip');
  }

  /// Flash the plan: table first, then erases, then writes, each leaving
  /// the plan as it completes so a failure leaves exactly what is left.
  Future<void> _flash() async {
    if (plan.isEmpty) return;
    final table = plan.stagedTable;
    final ops = plan.orderedOps;
    final lines = [
      if (table != null)
        '${'partition_table'.padRight(16)} ${plan.partitionTableOffset.hex.padLeft(10)}  Replace with ${plan.stagedTableSource}'
            '${plan.stagedTableProblem == null ? '' : '   ⚠ VERIFICATION FAILED: ${plan.stagedTableProblem}'}',
      for (final op in ops.where((op) => !op.isWrite)) _opLine(op),
      for (final op in ops.where((op) => op.isWrite)) _opLine(op),
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
      for (final op in [...ops.where((op) => !op.isWrite), ...ops.where((op) => op.isWrite)]) {
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
    await _refresh();
  }

  static String _opLine(PlannedOp op) => '${op.partition.name.padRight(16)} ${op.partition.offset.hex.padLeft(10)}  ${op.summary}${op.warning == null ? '' : '   ⚠ ${op.warning}'}';

  static String _describe(WriteOutcome o) => o.skipped
      ? 'already in flash, nothing written'
      : 'wrote ${o.written.bytesString} in ${o.runs} region${o.runs == 1 ? '' : 's'} in ${(o.elapsed.inMilliseconds / 1000).toStringAsFixed(1)} s'
          '${o.abandoned ? ' (comparison abandoned part-way)' : ''}';

  // --------------------------------------------------------------------------
  // Build
  // --------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (!session.connected) return const Center(child: Text('Connect to a device first.'));
    final table = plan.table;
    final busy = session.busy;
    final scheme = Theme.of(context).colorScheme;
    final showPlan = _planning;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, icon: Icon(Icons.visibility_outlined), label: Text('View')),
            ButtonSegment(value: true, icon: Icon(Icons.edit_outlined), label: Text('Plan changes')),
          ],
          selected: {showPlan},
          onSelectionChanged: (s) => setState(() => _planning = s.single),
          showSelectedIcon: false,
        ),
        const SizedBox(width: 8),
        FilledButton.tonalIcon(onPressed: busy ? null : _refresh, icon: const Icon(Icons.refresh), label: const Text('Re-read')),
        OutlinedButton.icon(
          onPressed: plan.deviceTable == null || busy ? null : _dumpBundle,
          icon: const Icon(Icons.archive_outlined),
          label: const Text('Dump bundle'),
        ),
        MenuAnchor(
          builder: (context, controller, _) => OutlinedButton.icon(
            onPressed: table == null ? null : () => controller.isOpen ? controller.close() : controller.open(),
            icon: const Icon(Icons.download),
            label: const Text('Table'),
          ),
          menuChildren: [
            MenuItemButton(onPressed: () => saveText('partitions.csv', table!.toCsv(), mimeType: 'text/csv'), child: const Text('Save as CSV')),
            MenuItemButton(onPressed: () => saveBytes('partition-table.bin', table!.toBinary()), child: const Text('Save as binary')),
            MenuItemButton(
                onPressed: () => showText(context, title: 'Partition table', text: table!.format(otadata: plan.stagedTable == null ? _otadata : null)),
                child: const Text('Show as text')),
          ],
        ),
        if (showPlan) ...[
          const SizedBox(width: 8),
          FilledButton.tonalIcon(onPressed: _stageTable, icon: const Icon(Icons.table_chart_outlined), label: const Text('Replace table…')),
          FilledButton.tonalIcon(onPressed: _loadBundle, icon: const Icon(Icons.unarchive_outlined), label: const Text('Load bundle…')),
        ],
        if (_otadata != null && plan.stagedTable == null)
          Chip(
            avatar: const Icon(Icons.play_arrow, size: 18),
            label: Text(_otadata!.slot == null ? 'OTA slot not set (factory boots)' : 'Boots ota_${_otadata!.slot} (seq ${_otadata!.entry!.seq}, ${_otadata!.entry!.state.name})'),
          ),
      ]),
      const SizedBox(height: 12),
      if (!showPlan && !plan.isEmpty) ...[
        MaterialBanner(
          backgroundColor: scheme.tertiaryContainer,
          leading: const Icon(Icons.pending_actions),
          content: Text('${plan.length} operation${plan.length == 1 ? '' : 's'} planned for this device, not flashed yet.'),
          actions: [TextButton(onPressed: () => setState(() => _planning = true), child: const Text('Show plan'))],
        ),
        const SizedBox(height: 12),
      ],
      if (plan.stagedTable != null) ...[
        MaterialBanner(
          backgroundColor: plan.stagedTableProblem == null ? scheme.tertiaryContainer : scheme.errorContainer,
          leading: Icon(plan.stagedTableProblem == null ? Icons.table_chart : Icons.error_outline),
          content: Text(plan.stagedTableProblem == null
              ? 'Showing the staged table from ${plan.stagedTableSource}. The device still has its own table until you flash; '
                  'rows marked new or changed are not where the device thinks they are.'
              : 'Staged table from ${plan.stagedTableSource} FAILED verification: ${plan.stagedTableProblem}'),
          actions: [
            TextButton(onPressed: () => _log(plan.unstageTable(), error: true), child: const Text('Discard table')),
          ],
        ),
        const SizedBox(height: 12),
      ] else if (showPlan) ...[
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
      ],
      if (table == null)
        const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))
      else
        DropTarget(
          onDragUpdated: _onDragUpdated,
          onDragExited: _onDragExited,
          onDragDone: _onDragDone,
          child: Card(
            shape: _dragging ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: scheme.primary, width: 2)) : null,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columnSpacing: 20,
                dataTextStyle: const TextStyle(fontFamily: 'RobotoMono', fontSize: 13),
                headingTextStyle: const TextStyle(fontFamily: 'RobotoMono', fontWeight: FontWeight.bold, fontSize: 13),
                columns: [
                  const DataColumn(label: Text('Name')),
                  const DataColumn(label: Text('Type')),
                  const DataColumn(label: Text('Subtype')),
                  const DataColumn(label: Text('Offset')),
                  const DataColumn(label: Text('Size')),
                  const DataColumn(label: Text('Flags')),
                  const DataColumn(label: Text('Contents')),
                  if (showPlan) const DataColumn(label: Text('Planned')),
                  const DataColumn(label: Text('')),
                ],
                rows: [for (final p in plan.rows) _row(p, table, showPlan: showPlan, busy: busy, scheme: scheme)],
              ),
            ),
          ),
        ),
      if (showPlan) ...[
        const SizedBox(height: 16),
        _PlanPanel(
            plan: plan,
            busy: busy,
            onFlash: _flash,
            onSaveBundle: _saveBundle,
            onClear: plan.clear,
            onRemove: plan.unstage,
            onDiscardTable: () => _log(plan.unstageTable(), error: true)),
      ],
    ]);
  }

  DataRow _row(PartitionDefinition p, PartitionTable table, {required bool showPlan, required bool busy, required ColorScheme scheme}) {
    final op = plan.opFor(p.name);
    final hovered = _hoverRow == p.name;
    final key = _rowKeys.putIfAbsent(p.name, GlobalKey.new);
    final virtual = !table.any((t) => identical(t, p));
    final activeSlot = plan.stagedTable == null ? _otadata?.slot : null;
    return DataRow(
      color: WidgetStatePropertyAll(hovered
          ? scheme.primaryContainer
          : op != null
              ? scheme.tertiaryContainer.withValues(alpha: 0.35)
              : virtual
                  ? scheme.surfaceContainerHighest.withValues(alpha: 0.5)
                  : null),
      cells: [
        DataCell(Row(key: key, children: [
          Text(p.name, style: virtual ? const TextStyle(fontStyle: FontStyle.italic) : null),
          if (p.isOtaApp && activeSlot == p.subtype - AppSubtype.otaMin)
            const Padding(padding: EdgeInsets.only(left: 6), child: Icon(Icons.play_arrow, size: 16, color: Colors.green)),
        ])),
        DataCell(TypeChip(p.typeName, _typeColor(p.type))),
        DataCell(TypeChip(p.subtypeName, _subtypeColor(p))),
        DataCell(Text(p.offset.hex)),
        DataCell(Text('${p.size.hex} (${p.size.bytesString})')),
        DataCell(Text(p.flagNames.join(', '))),
        DataCell(_contents(p, scheme)),
        if (showPlan) DataCell(_plannedCell(p, op, hovered: hovered, scheme: scheme)),
        DataCell(Row(mainAxisSize: MainAxisSize.min, children: [
          TextButton.icon(onPressed: busy ? null : () => _dump(p), icon: const Icon(Icons.download, size: 18), label: const Text('Dump')),
          if (p.isData && p.subtype == DataSubtype.nvs.value && widget.onOpenNvs != null && plan.stagedTable == null)
            TextButton.icon(onPressed: () => widget.onOpenNvs!(p.name), icon: const Icon(Icons.storage, size: 18), label: const Text('Open')),
          if (showPlan) ...[
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
        ])),
      ],
    );
  }

  /// What the device holds: the app descriptor for app partitions, or, on a
  /// staged table, how the row differs from the device.
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
    final app = _apps[p.offset];
    return Text(app == null || !p.isApp ? '' : '${app.projectName} ${app.version}');
  }

  Widget _plannedCell(PartitionDefinition p, PlannedOp? op, {required bool hovered, required ColorScheme scheme}) {
    if (hovered) return Text('Drop to write', style: TextStyle(color: scheme.primary, fontStyle: FontStyle.italic));
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
    required this.onFlash,
    required this.onSaveBundle,
    required this.onClear,
    required this.onRemove,
    required this.onDiscardTable,
  });
  final FlashPlan plan;
  final bool busy;
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
              onPressed: plan.isEmpty || busy ? null : onFlash,
              style: FilledButton.styleFrom(
                backgroundColor: scheme.error,
                foregroundColor: scheme.onError,
                padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
                textStyle: theme.textTheme.titleMedium,
              ),
              icon: const Icon(Icons.flash_on),
              label: Text(plan.isEmpty ? 'Flash' : 'Flash $count operation${count == 1 ? '' : 's'}'),
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

/// One hue per partition type, so the table scans by kind; each subtype
/// sits at its own point in a narrow band around that hue (ordered by the
/// subtype's position among its type's known subtypes), so kinds stay
/// grouped while subtypes remain distinguishable.
double _typeHue(int type) => switch (PartitionType.fromValue(type)) {
      PartitionType.bootloader => 20, // orange
      PartitionType.partitionTable => 45, // amber
      PartitionType.app => 140, // green
      PartitionType.data => 215, // blue
      null => 0,
    };

Color _typeColor(int type) => PartitionType.fromValue(type) == null ? Colors.grey : HSLColor.fromAHSL(1, _typeHue(type), 0.6, 0.45).toColor();

Color _subtypeColor(PartitionDefinition p) {
  if (p.knownType == null) return Colors.grey;
  final known = subtypeKeywords(p.type).values.toList()..sort();
  final index = known.indexOf(p.subtype);
  if (index < 0) return _typeColor(p.type);
  // Spread the known subtypes over ±25° of hue and a little lightness, so
  // neighbours differ but never leave the type's colour family.
  final t = known.length == 1 ? 0.5 : index / (known.length - 1);
  return HSLColor.fromAHSL(1, (_typeHue(p.type) - 25 + 50 * t) % 360, 0.55, 0.38 + 0.2 * t).toColor();
}
