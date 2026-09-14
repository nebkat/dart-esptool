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
import '../widgets/nvs_editor.dart';
import '../widgets/op_tile.dart';
import 'oneclick_page.dart';
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
const _partitionsKey = 'partitions';

class _FlashPageState extends State<FlashPage> {
  /// The row a drag is currently over: a partition name or a box's key.
  String? _hoverRow;
  bool _dragging = false;
  final _rowKeys = <String, GlobalKey>{};

  /// Planning without a device or table was chosen explicitly.
  bool _started = false;

  /// Name fields for writes by name, per entry (entries are replaced on
  /// rename, which resets the field to the new name).
  final _nameFields = <ManualWrite, TextEditingController>{};

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
    for (final c in _nameFields.values) {
      c.dispose();
    }
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

  void _stageManual(PickedFile file, {String? name}) {
    final problem = plan.stageManual(file, name: name);
    if (problem != null) return session.addLog(problem, error: true);
    session.addLog("Planned: write ${file.name} (${file.bytes.length.bytesString}) to the partition named '${name ?? file.name.split('.').first}'");
  }

  void _renameManual(int index, String name) {
    final problem = plan.renameManual(index, name);
    if (problem != null) session.addLog(problem, error: true);
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
    if (target == _partitionsKey) return _stageManual(file);
    final p = plan.row(target);
    if (p == null) {
      if (plan.table == null) return _stageManual(file, name: target);
      return session.addLog('${file.name}: no partition named "$target" — drop it onto a row to choose one', error: true);
    }
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

  /// Show the plan as the one-click flasher would present a bundle of it.
  Future<void> _preview() async {
    final FlashBundle bundle;
    try {
      bundle = FlashBundle.fromZip(
        plan.toBundle(),
        source: plan.bundleName ?? 'Untitled bundle',
        partitionTableOffset: plan.partitionTableOffset,
        primaryBootloaderOffset: plan.primaryBootloaderOffset,
      );
    } on IdfToolException catch (e) {
      return session.addLog('Cannot preview the plan as a bundle: ${e.message}', error: true);
    }
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (context) => ListenableBuilder(
          listenable: session,
          builder: (context, _) => OneClickPage(session: session, bundle: bundle, onBack: () => Navigator.pop(context)),
        ),
      ),
    );
  }

  /// Ask for the bundle's name and description, then save it. Erases go
  /// into the manifest; the chip planned for is recorded too.
  Future<void> _saveBundle() async {
    final details = await showDialog<({String name, String description})>(
      context: context,
      builder: (context) => _BundleDetailsDialog(
        name: plan.bundleName ?? '',
        description: plan.bundleDescription ?? '',
        chip: plan.chip,
        erases: [for (final op in plan.erases) op.partition.name],
        edits: plan.nvsPlans.length + plan.fsPlans.length,
      ),
    );
    if (details == null || !mounted) return;
    plan.setBundleInfo(name: details.name, description: details.description);
    final slug = details.name.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    final stem = slug.isNotEmpty ? slug : (session.connected ? session.deviceStem : 'plan');
    await saveBytes('$stem.zip', plan.toBundle(), mimeType: 'application/zip');
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
      for (final n in plan.nvsPlans) '${n.partition.padRight(16)} ${'values'.padLeft(10)}  ${n.summary}',
      for (final f in plan.fsPlans) '${f.partition.padRight(16)} ${'files'.padLeft(10)}  ${f.summary}',
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
      for (final m in plan.manual) {
        session.addLog("${m.name}: skipped — no partition of that name on this device", error: true);
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
      for (final n in plan.nvsPlans) {
        final r = await device.editNvs(n.edits, partitionName: n.partition, keys: session.nvsKeys, onProgress: session.reportProgress);
        for (final c in r.result.changes) {
          session.addLog('${n.partition}: ${describeNvsChange(c)}');
        }
        plan.unstageNvsAll(n.partition);
      }
      for (final f in plan.fsPlans) {
        final r = await device.editFs(
          partitionName: f.partition,
          put: {for (final e in f.put.entries) e.key: e.value.bytes},
          delete: f.delete,
          onProgress: session.reportProgress,
        );
        session.addLog('${f.partition}: ${r.put} file(s) put, ${r.deleted} deleted; ${_describe(r.outcome)}');
        for (final m in r.missing) {
          session.addLog('${f.partition}: $m was not there to delete');
        }
        plan.unstageFsAll(f.partition);
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

  Widget _chipPicker({bool enabled = true}) => AppDropdown<EspChip?>(
        value: plan.chip,
        label: 'Chip',
        hint: 'Unknown',
        width: 200,
        enabled: enabled,
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
          onPreview: _preview,
          onClear: plan.clear,
          onRemove: plan.unstage,
          onRemoveApp: plan.unstageApp,
          onRemoveManual: plan.unstageManual,
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
        leading,
        const SizedBox(width: 24),
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
      TableSource.device => "Device's table (${plan.deviceTable?.length ?? 0} partitions)",
      TableSource.file => '${plan.fileTableSource} (${plan.fileTable!.length} partitions)',
    };
    final problem = plan.tableSource == TableSource.file ? plan.fileTableProblem : null;
    return _box(scheme, title: 'Partition table', children: [
      _row(
        key: _tableKey,
        leading: Row(mainAxisSize: MainAxisSize.min, children: [
          SegmentedButton<TableSource>(
            segments: [
              const ButtonSegment(value: TableSource.device, label: Text('Device')),
              const ButtonSegment(value: TableSource.file, label: Text('File')),
            ],
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
          const SizedBox(width: 12),
          SegmentedButton<TableUse>(
            segments: const [ButtonSegment(value: TableUse.reference, label: Text('Reference')), ButtonSegment(value: TableUse.flash, label: Text('Flash'))],
            selected: {plan.tableUse},
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            onSelectionChanged: table == null ? null : (s) => plan.setTableUse(s.single),
          ),
          IconButton(tooltip: 'What Reference and Flash mean', icon: const Icon(Icons.help_outline, size: 18), onPressed: _explainTableUse),
        ]),
        description: Text.rich(TextSpan(children: [
          if (plan.byName)
            TextSpan(
                text: session.connected
                    ? 'Not read from the device yet: partitions are named by their file, or by hand'
                    : 'No device yet: partitions are named by their file, or by hand, and line up when one connects',
                style: TextStyle(color: scheme.outline)),
          if (problem != null) TextSpan(text: 'VERIFICATION FAILED: $problem', style: TextStyle(color: scheme.error)),
          if (plan.tableSource == TableSource.file && plan.deviceTable != null && plan.fileTable != plan.deviceTable)
            TextSpan(text: 'Differs from the device: rows below marked new, moved or resized are not where the device thinks they are', style: TextStyle(color: scheme.outline)),
        ])),
        planned: table == null ? null : (flash ? 'Write ${plan.tableSource == TableSource.file ? plan.fileTableSource : "the device's table"}' : 'Reference only'),
        warning: flash ? problem : null,
        onRemove: () => plan.setTableUse(TableUse.reference),
        actions: [
          if (table != null)
            InputChip(
              avatar: const Icon(Icons.table_chart_outlined, size: 18),
              label: Text(sourceLabel),
              tooltip: plan.tableSource == TableSource.file ? "Close the file and go back to the device's table" : 'The table read from the device',
              onDeleted: plan.tableSource == TableSource.file ? () => _log(plan.closeTableFile(), error: true) : null,
              deleteButtonTooltipMessage: 'Close file',
            ),
          TextButton.icon(onPressed: () => _pick(_tableKey, extensions: ['csv', 'bin']), icon: const Icon(Icons.folder_open, size: 18), label: const Text('Open…')),
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
        leading: offline ? _chipPicker() : Tooltip(message: 'The chip is the connected device\'s; disconnect to plan for another', child: _chipPicker(enabled: false)),
        description: Text(
            row == null
                ? 'Pick a chip to know the bootloader offset'
                : 'Written at ${row.offset.hex}, the ${plan.chip?.name ?? 'chip'}\'s bootloader offset, regardless of the partition table',
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
      final byName = plan.byName;
      return _box(
        scheme,
        title: 'Partitions',
        trailing: byName ? TextButton.icon(onPressed: () => _pick(_partitionsKey), icon: const Icon(Icons.upload_file, size: 18), label: const Text('Add file…')) : null,
        children: [
          Container(
            key: _rowKeys.putIfAbsent(_partitionsKey, GlobalKey.new),
            color: _hoverRow == _partitionsKey ? scheme.primaryContainer : null,
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
                byName
                    ? (_hoverRow == _partitionsKey
                        ? 'Drop to add, named after the file'
                        : 'Drop files here, or add them; each is written to the partition named after it, and the name can be changed.')
                    : 'Open a partition table above, or switch to Device to name partitions by file.',
                style: TextStyle(color: byName && _hoverRow == _partitionsKey ? scheme.primary : scheme.outline)),
          ),
          ..._manualRows(scheme),
        ],
      );
    }
    final unmatched = _manualRows(scheme);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      PartitionGrid(
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
            : _plannedCells(p),
        actions: (p) => plan.ownedByApp(p)
            ? const []
            : [
                if (p.isData && p.subtype == DataSubtype.nvs.value)
                  TextButton.icon(onPressed: () => _editNvs(p), icon: const Icon(Icons.edit_note, size: 18), label: const Text('Values…')),
                if (FsType.forPartition(p) != null)
                  TextButton.icon(onPressed: () => _editFs(p), icon: const Icon(Icons.folder_outlined, size: 18), label: const Text('Files…')),
                TextButton.icon(onPressed: () => _pick(p.name), icon: const Icon(Icons.upload_file, size: 18), label: const Text('Write…')),
                TextButton.icon(
                    onPressed: () => _stageErase(p),
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Erase'),
                    style: TextButton.styleFrom(foregroundColor: scheme.error)),
              ],
      ),
      if (unmatched.isNotEmpty) ...[
        const SizedBox(height: 12),
        _box(scheme, title: 'Not in this table', children: unmatched),
      ],
    ]);
  }

  /// The writes by name, each with an editable target name.
  List<Widget> _manualRows(ColorScheme scheme) {
    final manual = plan.manual;
    _nameFields.removeWhere((m, c) {
      if (manual.contains(m)) return false;
      c.dispose();
      return true;
    });
    return [
      for (final (i, m) in manual.indexed)
        Container(
          color: m.warning != null ? scheme.errorContainer.withValues(alpha: 0.25) : scheme.tertiaryContainer.withValues(alpha: 0.35),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(children: [
            SizedBox(
              width: 260,
              child: Focus(
                onFocusChange: (focused) {
                  if (!focused && _nameFields[m]!.text != m.name) _renameManual(i, _nameFields[m]!.text);
                },
                child: TextField(
                  controller: _nameFields.putIfAbsent(m, () => TextEditingController(text: m.name)),
                  decoration: const InputDecoration(labelText: 'Partition'),
                  style: const TextStyle(fontFamily: 'RobotoMono', fontSize: 13),
                  onSubmitted: (v) => _renameManual(i, v),
                ),
              ),
            ),
            const SizedBox(width: 24),
            Expanded(child: Text(m.warning ?? 'Written to the partition of that name', style: TextStyle(color: m.warning != null ? scheme.error : scheme.outline))),
            const SizedBox(width: 16),
            InputChip(
              avatar: Icon(m.warning != null ? Icons.warning_amber : Icons.upload_file, size: 18, color: m.warning != null ? scheme.error : null),
              label: Text(m.summary),
              onDeleted: () => plan.unstageManual(i),
              deleteButtonTooltipMessage: 'Remove from plan',
            ),
          ]),
        ),
    ];
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

  /// The write or erase planned for [p], plus chips for its value and file
  /// edits, which run after it.
  Widget _plannedCells(PartitionDefinition p) {
    final op = plan.opFor(p.name);
    final nvs = plan.nvsPlanFor(p.name);
    final fs = plan.fsPlanFor(p.name);
    if (nvs == null && fs == null) return _plannedCell(p.name, op?.summary, op?.warning, onRemove: () => plan.unstage(p.name));
    return Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
      if (op != null || _hoverRow == p.name || _dragging) _plannedCell(p.name, op?.summary, op?.warning, onRemove: () => plan.unstage(p.name)),
      if (nvs != null)
        InputChip(
          avatar: const Icon(Icons.edit_note, size: 18),
          label: Text('${nvs.length} value${nvs.length == 1 ? '' : 's'}'),
          tooltip: nvs.summary,
          onPressed: () => _editNvs(p),
          onDeleted: () => plan.unstageNvsAll(p.name),
          deleteButtonTooltipMessage: 'Remove from plan',
        ),
      if (fs != null)
        InputChip(
          avatar: const Icon(Icons.folder_outlined, size: 18),
          label: Text('${fs.length} file${fs.length == 1 ? '' : 's'}'),
          tooltip: fs.summary,
          onPressed: () => _editFs(p),
          onDeleted: () => plan.unstageFsAll(p.name),
          deleteButtonTooltipMessage: 'Remove from plan',
        ),
    ]);
  }

  Future<void> _editNvs(PartitionDefinition p) => showDialog<void>(context: context, builder: (context) => _NvsPlanDialog(plan: plan, partition: p.name));

  Future<void> _editFs(PartitionDefinition p) =>
      showDialog<void>(context: context, builder: (context) => _FsPlanDialog(plan: plan, partition: p.name, type: FsType.forPartition(p)));

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
    required this.onPreview,
    required this.onClear,
    required this.onRemove,
    required this.onRemoveApp,
    required this.onRemoveManual,
    required this.onDiscardTable,
  });
  final FlashPlan plan;
  final bool busy;
  final bool offline;
  final VoidCallback onFlash;
  final VoidCallback onSaveBundle;
  final VoidCallback onPreview;
  final VoidCallback onClear;
  final ValueChanged<String> onRemove;
  final VoidCallback onRemoveApp;
  final ValueChanged<int> onRemoveManual;
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
    final bundleable = !plan.isEmpty;
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
              OpTile(
                icon: plan.stagedTableProblem == null ? Icons.table_chart : Icons.error_outline,
                name: 'partition_table',
                detail: plan.partitionTableOffset.hex,
                summary: 'Write ${plan.stagedTableSource} (first)',
                warning: plan.stagedTableProblem == null ? null : 'Verification failed: ${plan.stagedTableProblem}',
                onRemove: onDiscardTable,
              ),
            if (bootloader != null)
              OpTile(
                  icon: Icons.upload_file,
                  name: 'bootloader',
                  detail: bootloader.partition.offset.hex,
                  summary: bootloader.summary,
                  warning: bootloader.warning,
                  onRemove: () => onRemove(bootloader.partition.name)),
            if (plan.app case final app?)
              OpTile(
                  icon: Icons.upload_file,
                  name: plan.appRole.fileStem,
                  detail: plan.appTarget ?? plan.appRole.label,
                  summary: 'Write ${app.name} (${app.bytes.length.bytesString}) to ${plan.appRole.description}',
                  warning: plan.appWarning,
                  onRemove: onRemoveApp),
            for (final op in erases)
              OpTile(
                  icon: Icons.delete_outline,
                  name: op.partition.name,
                  detail: op.partition.offset.hex,
                  summary: op.summary,
                  warning: op.warning,
                  onRemove: () => onRemove(op.partition.name)),
            for (final op in writes)
              OpTile(
                  icon: Icons.upload_file,
                  name: op.partition.name,
                  detail: op.partition.offset.hex,
                  summary: op.summary,
                  warning: op.warning,
                  onRemove: () => onRemove(op.partition.name)),
            for (final (i, m) in plan.manual.indexed)
              OpTile(icon: Icons.upload_file, name: m.name, detail: 'by name', summary: m.summary, warning: m.warning, onRemove: () => onRemoveManual(i)),
            for (final n in plan.nvsPlans)
              OpTile(
                  icon: Icons.edit_note,
                  name: n.partition,
                  detail: plan.row(n.partition)?.offset.hex ?? 'by name',
                  summary: n.summary,
                  onRemove: () => plan.unstageNvsAll(n.partition)),
            for (final f in plan.fsPlans)
              OpTile(
                  icon: Icons.folder_outlined,
                  name: f.partition,
                  detail: plan.row(f.partition)?.offset.hex ?? 'by name',
                  summary: f.summary,
                  onRemove: () => plan.unstageFsAll(f.partition)),
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
                onPressed: bundleable ? onPreview : null,
                icon: const Icon(Icons.visibility_outlined),
                label: const Text('Preview'),
              ),
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

/// The values queued for one NVS partition: add a set, add a delete, remove.
class _NvsPlanDialog extends StatelessWidget {
  const _NvsPlanDialog({required this.plan, required this.partition});
  final FlashPlan plan;
  final String partition;

  Future<void> _add(BuildContext context) async {
    final edit = await showDialog<NvsEdit>(context: context, builder: (context) => const NvsEntryDialog());
    if (edit != null) plan.stageNvsSet(partition, edit.qualified, NvsPlan.spec(edit));
  }

  Future<void> _delete(BuildContext context) async {
    final key = await prompt(context, title: 'Delete a value', label: 'namespace:key', hint: 'cfg:channel', action: 'Queue delete');
    if (key == null) return;
    try {
      plan.stageNvsDelete(partition, parseNvsDeleteSpec(key.trim()).qualified);
    } catch (e) {
      if (context.mounted) await confirm(context, title: 'Not a key', message: '$e', action: 'OK');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: plan,
      builder: (context, _) {
        final p = plan.nvsPlanFor(partition);
        return AlertDialog(
          title: Text('Values in $partition'),
          content: SizedBox(
            width: 560,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Applied to whatever the partition holds after any write to it, keeping the other entries. '
                  'A set without a matching entry adds one.', style: TextStyle(color: scheme.outline)),
              const SizedBox(height: 12),
              if (p == null)
                Text('Nothing queued.', style: TextStyle(color: scheme.outline))
              else ...[
                for (final e in p.set.entries)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.edit_note),
                    title: Text('${e.key} = ${e.value}', style: const TextStyle(fontFamily: 'RobotoMono', fontSize: 13)),
                    trailing: IconButton(icon: const Icon(Icons.close, size: 18), tooltip: 'Remove', onPressed: () => plan.unstageNvs(partition, e.key)),
                  ),
                for (final d in p.delete)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.delete_outline, color: scheme.error),
                    title: Text('delete $d', style: const TextStyle(fontFamily: 'RobotoMono', fontSize: 13)),
                    trailing: IconButton(icon: const Icon(Icons.close, size: 18), tooltip: 'Remove', onPressed: () => plan.unstageNvs(partition, d)),
                  ),
              ],
              const SizedBox(height: 12),
              Wrap(spacing: 8, children: [
                FilledButton.tonalIcon(onPressed: () => _add(context), icon: const Icon(Icons.add, size: 18), label: const Text('Set a value…')),
                FilledButton.tonalIcon(onPressed: () => _delete(context), icon: const Icon(Icons.delete_outline, size: 18), label: const Text('Delete a value…')),
              ]),
            ]),
          ),
          actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))],
        );
      },
    );
  }
}

/// The files queued for one filesystem partition: put a file at a path,
/// delete a path, remove.
class _FsPlanDialog extends StatelessWidget {
  const _FsPlanDialog({required this.plan, required this.partition, required this.type});
  final FlashPlan plan;
  final String partition;
  final FsType? type;

  Future<void> _put(BuildContext context) async {
    final file = await pickFile();
    if (file == null || !context.mounted) return;
    final path = await prompt(context, title: 'Put ${file.name}', label: 'Path in the filesystem', initial: file.name, action: 'Queue');
    if (path == null) return;
    final problem = plan.stageFsPut(partition, path, file);
    if (problem != null && context.mounted) await confirm(context, title: 'Not queued', message: problem, action: 'OK');
  }

  Future<void> _delete(BuildContext context) async {
    final path = await prompt(context, title: 'Delete a file', label: 'Path in the filesystem', hint: 'config/old.json', action: 'Queue delete');
    if (path == null) return;
    final problem = plan.stageFsDelete(partition, path);
    if (problem != null && context.mounted) await confirm(context, title: 'Not queued', message: problem, action: 'OK');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final littlefs = type == FsType.littlefs;
    return ListenableBuilder(
      listenable: plan,
      builder: (context, _) {
        final p = plan.fsPlanFor(partition);
        return AlertDialog(
          title: Text('Files in $partition'),
          content: SizedBox(
            width: 560,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                littlefs
                    ? 'LittleFS images cannot be rebuilt yet, so these edits will fail when flashed; write a whole image instead.'
                    : 'The partition is read, the changes applied to its files, and a fresh ${type?.label ?? 'filesystem'} image written back. '
                        'An erased partition starts empty.',
                style: TextStyle(color: littlefs ? scheme.error : scheme.outline),
              ),
              const SizedBox(height: 12),
              if (p == null)
                Text('Nothing queued.', style: TextStyle(color: scheme.outline))
              else ...[
                for (final e in p.put.entries)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.upload_file),
                    title: Text(e.key, style: const TextStyle(fontFamily: 'RobotoMono', fontSize: 13)),
                    subtitle: Text('${e.value.name} (${e.value.bytes.length.bytesString})'),
                    trailing: IconButton(icon: const Icon(Icons.close, size: 18), tooltip: 'Remove', onPressed: () => plan.unstageFs(partition, e.key)),
                  ),
                for (final d in p.delete)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.delete_outline, color: scheme.error),
                    title: Text('delete $d', style: const TextStyle(fontFamily: 'RobotoMono', fontSize: 13)),
                    trailing: IconButton(icon: const Icon(Icons.close, size: 18), tooltip: 'Remove', onPressed: () => plan.unstageFs(partition, d)),
                  ),
              ],
              const SizedBox(height: 12),
              Wrap(spacing: 8, children: [
                FilledButton.tonalIcon(onPressed: () => _put(context), icon: const Icon(Icons.add, size: 18), label: const Text('Put a file…')),
                FilledButton.tonalIcon(onPressed: () => _delete(context), icon: const Icon(Icons.delete_outline, size: 18), label: const Text('Delete a file…')),
              ]),
            ]),
          ),
          actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))],
        );
      },
    );
  }
}

/// Name and description for a bundle's manifest, with what else the
/// manifest will carry spelled out.
class _BundleDetailsDialog extends StatefulWidget {
  const _BundleDetailsDialog({required this.name, required this.description, required this.chip, required this.erases, required this.edits});
  final String name;
  final String description;
  final EspChip? chip;
  final List<String> erases;
  final int edits;

  @override
  State<_BundleDetailsDialog> createState() => _BundleDetailsDialogState();
}

class _BundleDetailsDialogState extends State<_BundleDetailsDialog> {
  late final _name = TextEditingController(text: widget.name);
  late final _description = TextEditingController(text: widget.description);

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  void _save() => Navigator.pop(context, (name: _name.text, description: _description.text));

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final carried = [
      if (widget.chip case final chip?) 'the chip it is for (${chip.name}), checked before flashing',
      if (widget.erases.isNotEmpty) 'the erase of ${widget.erases.join(', ')}',
      if (widget.edits > 0) '${widget.edits} value and file edit${widget.edits == 1 ? '' : 's'}',
    ];
    return AlertDialog(
      title: const Text('Save as bundle'),
      content: SizedBox(
        width: 480,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Shown as the heading of the one-click flasher. Both are optional.', style: TextStyle(color: scheme.outline)),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Name', hintText: 'MS5 v0.17.0', border: OutlineInputBorder()),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _description,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(labelText: 'Description', hintText: 'What this update does', border: OutlineInputBorder()),
          ),
          if (carried.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('The manifest also records ${carried.join(' and ')}.', style: TextStyle(color: scheme.outline)),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
