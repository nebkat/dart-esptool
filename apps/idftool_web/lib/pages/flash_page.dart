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
/// terms and in four boxes that mirror its files: the partition table
/// (`partition_table.csv`, the device's or a file's, flashed or reference
/// only), the bootloader (`bootloader.bin`), the app (`@factory.bin` or
/// `@ota.bin`) and the named partitions (`<name>.bin`). Rows take a
/// dropped or picked file; the queued operations sit at the bottom until
/// one doubly-confirmed Flash writes them — table, bootloader, app,
/// erases, then named writes.
///
/// Works without a device, and the plan is kept and re-checked when one
/// connects. Save as bundle writes the same files a hand-made bundle would.
class FlashPage extends StatefulWidget {
  const FlashPage({super.key, required this.session});
  final DeviceSession session;

  @override
  State<FlashPage> createState() => _FlashPageState();
}

/// Drop-target names for the rows that aren't partitions.
const _tableKey = 'partition_table';
const _appKey = '@app';

class _FlashPageState extends State<FlashPage> {
  /// The row a drag is currently over: a partition name or a box's key.
  String? _hoverRow;
  bool _dragging = false;
  final _rowKeys = <String, GlobalKey>{};

  /// Planning without a device or table was chosen explicitly.
  bool _started = false;

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
    if (problem != null) return session.addLog(problem, error: true);
    final op = plan.opFor(p.name)!;
    session.addLog('Planned: write ${file.name} (${file.bytes.length.bytesString}) to ${p.name}'
        '${replaced == null ? '' : ' (replacing ${replaced.summary.toLowerCase()})'}'
        '${op.warning == null ? '' : ' — ${op.warning}'}');
  }

  void _stageBootloader(PickedFile file) {
    final problem = plan.stageBootloader(file);
    if (problem != null) return session.addLog(problem, error: true);
    final op = plan.bootloaderOp!;
    session.addLog('Planned: write ${file.name} as the bootloader at ${op.partition.offset.hex}${op.warning == null ? '' : ' — ${op.warning}'}');
  }

  void _stageApp(PickedFile file, {FlashRole? role}) {
    if (role != null && role != plan.appRole) _log(plan.setAppRole(role));
    final r = plan.stageApp(file);
    if (r.problem case final problem?) return session.addLog(problem, error: true);
    _log(r.dropped);
    session.addLog('Planned: ${plan.appRole.label} flash ${file.name} (${file.bytes.length.bytesString})${plan.appWarning == null ? '' : ' — ${plan.appWarning}'}');
  }

  void _stageErase(PartitionDefinition p) {
    final problem = plan.stageErase(p);
    if (problem != null) return session.addLog(problem, error: true);
    final warning = plan.opFor(p.name)!.warning;
    session.addLog('Planned: erase ${p.name}${warning == null ? '' : ' — $warning'}');
  }

  void _openTable(PickedFile file, {required bool flash}) {
    final PartitionTable table;
    try {
      table = PartitionTable.isBinary(file.bytes)
          ? PartitionTable.fromBinary(file.bytes)
          : parsePartitionTableCsv(PartitionTable.decodeCsv(file.bytes),
              source: file.name, partitionTableOffset: plan.partitionTableOffset, primaryBootloaderOffset: plan.primaryBootloaderOffset);
    } catch (e) {
      return session.addLog('Could not parse ${file.name}: $e', error: true);
    }
    _log(flash ? plan.stageTable(table, source: file.name) : plan.openTableFile(table, source: file.name), error: true);
    session.addLog('Opened partition table ${file.name} (${table.length} partitions)'
        '${plan.fileTableProblem == null ? '' : ' — VERIFICATION FAILED: ${plan.fileTableProblem}'}');
    setState(() => _started = true);
  }

  /// Stage [file] on the row called [target]: a box's key, a role's stem
  /// or a partition name — the bundle's own naming.
  void _stageOn(String target, PickedFile file) {
    if (target == _tableKey) return _openTable(file, flash: plan.tableUse == TableUse.flash);
    if (target == _appKey) return _stageApp(file);
    final role = FlashRole.values.where((r) => r.fileStem == target).firstOrNull;
    if (role != null) return _stageApp(file, role: role);
    final p = plan.row(target);
    if (p == null) return session.addLog('${file.name}: no partition named "$target" — drop it onto a row to choose one', error: true);
    p.isPrimaryBootloader ? _stageBootloader(file) : _stageWrite(p, file);
  }

  Future<void> _pick(String target, {List<String>? extensions}) async {
    final file = await pickFile(extensions: extensions);
    if (file == null || !mounted) return;
    _stageOn(target, file);
  }

  /// A single file dropped on a row goes there; otherwise files are matched
  /// to rows by name, the way a bundle is.
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

  Future<void> _loadBundle() async {
    final file = await pickFile(extensions: ['zip']);
    if (file == null || !mounted) return;
    try {
      _log(plan.loadBundle(file.bytes, source: file.name), error: true);
    } on IdfToolException catch (e) {
      return session.addLog('${file.name}: ${e.message}', error: true);
    } catch (e) {
      return session.addLog('${file.name}: $e', error: true);
    }
    session.addLog('Planned from bundle ${file.name}: ${plan.length} operation${plan.length == 1 ? '' : 's'}');
    setState(() => _started = true);
  }

  Future<void> _saveBundle() async {
    final erases = plan.ops.where((op) => !op.isWrite).length;
    if (erases > 0) session.addLog('Bundle saved without $erases erase${erases == 1 ? '' : 's'}; bundles only carry files');
    await saveBytes('${session.connected ? session.deviceStem : 'plan'}.zip', plan.toBundle(), mimeType: 'application/zip');
  }

  // --------------------------------------------------------------------------
  // Drag and drop
  // --------------------------------------------------------------------------

  /// The row under [global], if any. Rows are keyed by their name; the
  /// nearest centre within half a row pitch wins.
  String? _rowAt(Offset global) {
    final centres = <(String, double)>[];
    for (final MapEntry(key: name, value: key) in _rowKeys.entries) {
      final box = key.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) continue;
      centres.add((name, box.localToGlobal(Offset.zero).dy + box.size.height / 2));
    }
    if (centres.isEmpty) return null;
    String? best;
    var bestDistance = double.infinity;
    for (final (name, cy) in centres) {
      final d = (global.dy - cy).abs();
      if (d < bestDistance) {
        bestDistance = d;
        best = name;
      }
    }
    return bestDistance <= 28 ? best : null;
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

  /// Flash the plan in bundle order: table, bootloader, app, erases, named
  /// writes — each leaving the plan as it completes so a failure leaves
  /// exactly what is left.
  Future<void> _flash() async {
    if (plan.isEmpty || !session.connected) return;
    final table = plan.stagedTable;
    final bootloader = plan.bootloaderOp;
    final app = plan.app;
    final role = plan.appRole;
    final ops = plan.orderedOps;
    final erases = ops.where((op) => !op.isWrite).toList();
    final writes = ops.where((op) => op.isWrite).toList();
    final lines = [
      if (table != null)
        '${'partition_table'.padRight(16)} ${plan.partitionTableOffset.hex.padLeft(10)}  Write ${plan.stagedTableSource}'
            '${plan.stagedTableProblem == null ? '' : '   ⚠ VERIFICATION FAILED: ${plan.stagedTableProblem}'}',
      if (bootloader != null) _opLine(bootloader),
      if (app != null)
        '${role.fileStem.padRight(16)} ${(plan.appTarget ?? '').padLeft(10)}  Write ${app.name} (${app.bytes.length.bytesString}) to ${role.description}'
            '${plan.appWarning == null ? '' : '   ⚠ ${plan.appWarning}'}',
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
      if (app != null) {
        switch (role) {
          case FlashRole.factory:
            final outcome = await device.factory(app.bytes, onProgress: session.reportProgress);
            session.addLog('factory: ${_describe(outcome)}; OTA selection cleared');
          case FlashRole.ota:
            final result = await device.ota(app.bytes, onProgress: session.reportProgress);
            session.addLog('ota: ${result.partition.name} ${_describe(result.outcome)}; boot switched to it');
        }
        plan.unstageApp();
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

  Widget _chipPicker() => AppDropdown<EspChip?>(
        value: plan.chip,
        label: 'Chip',
        hint: 'Unknown',
        width: 200,
        entries: [
          const DropdownMenuEntry(value: null, label: 'Unknown'),
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
    final busy = session.busy;
    final scheme = Theme.of(context).colorScheme;
    if (offline && !_started && plan.isEmpty && plan.fileTable == null) {
      return EmptyState.noDevice(
        message: 'Connect a device to plan changes to its flash, or start without one: open a partition table or bundle, '
            'or plan just the bootloader and the app.',
        actions: [
          FilledButton.tonalIcon(
              onPressed: () => _pick(_tableKey, extensions: ['csv', 'bin']), icon: const Icon(Icons.table_chart_outlined), label: const Text('Open partition table…')),
          FilledButton.tonalIcon(onPressed: _loadBundle, icon: const Icon(Icons.unarchive_outlined), label: const Text('Open bundle…')),
          FilledButton.tonalIcon(onPressed: () => setState(() => _started = true), icon: const Icon(Icons.flash_on), label: const Text('Start empty')),
        ],
      );
    }
    if (session.connected && busy && plan.deviceTable == null && plan.isEmpty) return const LoadingState('Reading the partition table…');
    return ListView(padding: const EdgeInsets.all(16), children: [
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        FilledButton.tonalIcon(onPressed: _loadBundle, icon: const Icon(Icons.unarchive_outlined), label: const Text('Load bundle…')),
        Text(
            'Drag files onto rows, or use Write…, to queue operations. Several files dropped at once are matched by name, the way a bundle is. '
            'Nothing touches the device until you flash.',
            style: TextStyle(color: scheme.outline)),
      ]),
      const SizedBox(height: 12),
      DropTarget(
        onDragUpdated: _onDragUpdated,
        onDragExited: _onDragExited,
        onDragDone: _onDragDone,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _tableBox(scheme, busy),
          const SizedBox(height: 12),
          _bootloaderBox(scheme, offline),
          const SizedBox(height: 12),
          _appBox(scheme),
          const SizedBox(height: 12),
          _partitionsBox(scheme),
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
          onRemoveApp: plan.unstageApp,
          onDiscardTable: () => plan.setTableUse(TableUse.reference)),
    ]);
  }

  Widget _box(ColorScheme scheme, {required String title, Widget? trailing, required List<Widget> children}) => Card(
        shape: _dragging ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(4), side: BorderSide(color: scheme.primary, width: 2)) : null,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(children: [
              Expanded(child: Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: scheme.outline))),
              if (trailing != null) trailing,
            ]),
          ),
          ...children,
          const SizedBox(height: 4),
        ]),
      );

  /// One droppable row: a name, a description, what is planned, and the
  /// controls on the right.
  Widget _row({
    required String key,
    required Widget leading,
    required Widget description,
    required String? planned,
    required String? warning,
    required VoidCallback onRemove,
    required List<Widget> actions,
    Color? color,
    ColorScheme? scheme,
  }) {
    scheme ??= Theme.of(context).colorScheme;
    return Container(
      key: _rowKeys.putIfAbsent(key, GlobalKey.new),
      color: color ?? _rowColor(key, scheme, planned: planned != null),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(children: [
        SizedBox(width: 200, child: leading),
        const SizedBox(width: 16),
        Expanded(child: description),
        const SizedBox(width: 16),
        _plannedCell(key, planned, warning, onRemove: onRemove),
        const SizedBox(width: 16),
        ...actions,
      ]),
    );
  }

  Widget _tableBox(ColorScheme scheme, bool busy) {
    final table = plan.table;
    final flash = plan.tableUse == TableUse.flash;
    final sourceLabel = switch (plan.tableSource) {
      TableSource.device =>
        plan.deviceTable == null ? (session.connected ? 'Device (not read yet)' : 'Device (none connected)') : "Device (${plan.deviceTable!.length} partitions)",
      TableSource.file => '${plan.fileTableSource} (${plan.fileTable!.length} partitions)',
    };
    final problem = plan.tableSource == TableSource.file ? plan.fileTableProblem : null;
    return _box(scheme, title: 'Partition table', children: [
      _row(
        key: _tableKey,
        leading: Row(children: [
          SegmentedButton<TableSource>(
            segments: const [ButtonSegment(value: TableSource.device, label: Text('Device')), ButtonSegment(value: TableSource.file, label: Text('File'))],
            selected: {plan.tableSource},
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            onSelectionChanged: (s) {
              final source = s.single;
              if (source == TableSource.file && plan.fileTable == null) {
                _pick(_tableKey, extensions: ['csv', 'bin']);
                return;
              }
              _log(plan.setTableSource(source), error: true);
            },
          ),
        ]),
        description: Text.rich(TextSpan(children: [
          TextSpan(text: sourceLabel),
          if (problem != null) TextSpan(text: '  VERIFICATION FAILED: $problem', style: TextStyle(color: scheme.error)),
          if (plan.tableSource == TableSource.file && plan.deviceTable != null && plan.fileTable != plan.deviceTable)
            TextSpan(
                text: '  — differs from the device; rows below marked new, moved or resized are not where the device thinks they are', style: TextStyle(color: scheme.outline)),
        ])),
        planned: table == null ? null : (flash ? 'Write ${plan.tableSource == TableSource.file ? plan.fileTableSource : "the device's table"}' : 'Reference only'),
        warning: flash ? problem : null,
        onRemove: () => plan.setTableUse(TableUse.reference),
        actions: [
          SegmentedButton<TableUse>(
            segments: const [ButtonSegment(value: TableUse.reference, label: Text('Reference')), ButtonSegment(value: TableUse.flash, label: Text('Flash'))],
            selected: {plan.tableUse},
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            onSelectionChanged: table == null ? null : (s) => plan.setTableUse(s.single),
          ),
          IconButton(tooltip: 'What Reference and Flash mean', icon: const Icon(Icons.help_outline, size: 18), onPressed: _explainTableUse),
          TextButton.icon(onPressed: () => _pick(_tableKey, extensions: ['csv', 'bin']), icon: const Icon(Icons.folder_open, size: 18), label: const Text('Open…')),
          if (plan.fileTable != null) TextButton(onPressed: () => _log(plan.closeTableFile(), error: true), child: const Text('Close file')),
        ],
      ),
    ]);
  }

  /// What Reference and Flash mean for the table.
  Future<void> _explainTableUse() => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Reference or flash the partition table?'),
          content: const SizedBox(
            width: 560,
            child: Text(
              "The partition table is what gives partitions their names, so the plan always works against one: the device's own, "
              'or one opened from a file.\n\n'
              'Reference only uses it to name the partitions and nothing more. Nothing is written to the table sector, '
              'and a bundle saved from this plan carries no table, so it will flash onto any device whose table already has these names.\n\n'
              'Flash writes the table first, before anything else, and includes it in a saved bundle, so the bundle carries the layout '
              "its files were named against and can be applied to a device with a different table. Writing the device's own table back "
              'to it changes nothing on that device. Only the map is replaced: existing partition data is not moved, resized or erased.',
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
        ),
      );

  Widget _bootloaderBox(ColorScheme scheme, bool offline) {
    final row = plan.bootloaderRow;
    final op = plan.bootloaderOp;
    return _box(scheme, title: 'Bootloader', children: [
      _row(
        key: row?.name ?? 'bootloader',
        leading: offline ? _chipPicker() : Text(plan.chip?.name ?? '', style: const TextStyle(fontFamily: 'RobotoMono', fontSize: 13)),
        description: Text(
            row == null
                ? 'Pick a chip to know the bootloader offset'
                : 'Written at ${row.offset.hex}, the ${plan.chip?.name ?? 'chip'}\'s bootloader offset, whatever the table says',
            style: TextStyle(color: scheme.outline)),
        planned: op?.summary,
        warning: op?.warning,
        onRemove: () => plan.unstage(row!.name),
        actions: [
          TextButton.icon(onPressed: row == null ? null : () => _pick(row.name, extensions: ['bin']), icon: const Icon(Icons.upload_file, size: 18), label: const Text('Write…')),
        ],
      ),
    ]);
  }

  Widget _appBox(ColorScheme scheme) {
    final app = plan.app;
    final role = plan.appRole;
    final target = plan.appTarget;
    return _box(scheme, title: 'App', children: [
      _row(
        key: _appKey,
        leading: SegmentedButton<FlashRole>(
          segments: const [ButtonSegment(value: FlashRole.factory, label: Text('Factory')), ButtonSegment(value: FlashRole.ota, label: Text('OTA'))],
          selected: {role},
          showSelectedIcon: false,
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          onSelectionChanged: (s) => _log(plan.setAppRole(s.single)),
        ),
        description: Text('${role.description[0].toUpperCase()}${role.description.substring(1)}${target == null ? '' : ' ($target)'}', style: TextStyle(color: scheme.outline)),
        planned: app == null ? null : 'Write ${app.name} (${app.bytes.length.bytesString})',
        warning: plan.appWarning,
        onRemove: plan.unstageApp,
        actions: [
          TextButton.icon(onPressed: () => _pick(_appKey, extensions: ['bin']), icon: const Icon(Icons.upload_file, size: 18), label: const Text('Write…')),
        ],
      ),
    ]);
  }

  Widget _partitionsBox(ColorScheme scheme) {
    final table = plan.table;
    if (table == null) {
      return _box(scheme, title: 'Partitions', children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text(
              session.connected
                  ? 'The partition table has not been read — see the log, or open one above.'
                  : 'Connect a device or open a partition table above to name partitions.',
              style: TextStyle(color: scheme.outline)),
        ),
      ]);
    }
    return PartitionGrid(
      rows: plan.partitionRows,
      table: table,
      activeSlot: plan.tableSource == TableSource.device ? plan.otadata?.slot : null,
      highlighted: _dragging,
      rowKey: (p) => _rowKeys.putIfAbsent(p.name, GlobalKey.new),
      rowColor: (p) => plan.ownedByApp(p) ? scheme.surfaceContainerHighest.withValues(alpha: 0.5) : _rowColor(p.name, scheme, planned: plan.opFor(p.name) != null),
      contents: (p) => _contents(p, scheme),
      extraColumn: 'Planned',
      extra: (p) => plan.ownedByApp(p)
          ? Text('Handled by the ${plan.appRole.label} app', style: TextStyle(color: scheme.outline, fontStyle: FontStyle.italic))
          : _plannedCell(p.name, plan.opFor(p.name)?.summary, plan.opFor(p.name)?.warning, onRemove: () => plan.unstage(p.name)),
      actions: (p) => plan.ownedByApp(p)
          ? const []
          : [
              TextButton.icon(onPressed: () => _pick(p.name), icon: const Icon(Icons.upload_file, size: 18), label: const Text('Write…')),
              TextButton.icon(
                  onPressed: () => _stageErase(p),
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('Erase'),
                  style: TextButton.styleFrom(foregroundColor: scheme.error)),
            ],
    );
  }

  /// What the device holds at this row, or, on a file's table, how the row
  /// differs from the device.
  Widget _contents(PartitionDefinition p, ColorScheme scheme) {
    final device = plan.deviceTable;
    if (plan.tableSource == TableSource.file && device != null) {
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

  Widget _plannedCell(String name, String? planned, String? warning, {required VoidCallback onRemove}) {
    final scheme = Theme.of(context).colorScheme;
    if (_hoverRow == name) return Text('Drop to write', style: TextStyle(color: scheme.primary, fontStyle: FontStyle.italic));
    if (planned == null) return _dragging ? const SizedBox.shrink() : Text('—', style: TextStyle(color: scheme.outlineVariant));
    final passive = planned == 'Reference only';
    if (passive) {
      return ActionChip(
        avatar: const Icon(Icons.visibility_outlined, size: 18),
        label: Text(planned),
        tooltip: 'What Reference and Flash mean',
        onPressed: _explainTableUse,
      );
    }
    return InputChip(
      avatar: Icon(
        warning != null
            ? Icons.warning_amber
            : passive
                ? Icons.visibility_outlined
                : planned.startsWith('Erase')
                    ? Icons.delete_outline
                    : Icons.upload_file,
        size: 18,
        color: warning != null ? scheme.error : null,
      ),
      label: Text(planned),
      tooltip: warning ?? planned,
      onDeleted: passive ? null : onRemove,
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
    required this.onRemoveApp,
    required this.onDiscardTable,
  });
  final FlashPlan plan;
  final bool busy;
  final bool offline;
  final VoidCallback onFlash;
  final VoidCallback onSaveBundle;
  final VoidCallback onClear;
  final ValueChanged<String> onRemove;
  final VoidCallback onRemoveApp;
  final VoidCallback onDiscardTable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bootloader = plan.bootloaderOp;
    final ops = plan.orderedOps;
    final erases = ops.where((op) => !op.isWrite).toList();
    final writes = ops.where((op) => op.isWrite).toList();
    final count = plan.length;
    final bundleable = writes.isNotEmpty || bootloader != null || plan.app != null || plan.stagedTable != null;
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
                summary: 'Write ${plan.stagedTableSource} (first)',
                warning: plan.stagedTableProblem == null ? null : 'Verification failed: ${plan.stagedTableProblem}',
                onRemove: onDiscardTable,
              ),
            if (bootloader != null)
              _OpTile(
                  icon: Icons.upload_file,
                  name: 'bootloader',
                  detail: bootloader.partition.offset.hex,
                  summary: bootloader.summary,
                  warning: bootloader.warning,
                  onRemove: () => onRemove(bootloader.partition.name)),
            if (plan.app case final app?)
              _OpTile(
                  icon: Icons.system_update_alt,
                  name: plan.appRole.fileStem,
                  detail: plan.appTarget ?? plan.appRole.label,
                  summary: 'Write ${app.name} (${app.bytes.length.bytesString}) to ${plan.appRole.description}',
                  warning: plan.appWarning,
                  onRemove: onRemoveApp),
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
