import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:idftool/idftool.dart';

import '../session/device_session.dart';
import '../session/flash_plan.dart';
import '../util/files.dart';
import '../widgets/dialogs.dart';
import '../widgets/partition_grid.dart';
import '../widgets/partition_map.dart';

/// What is on the device: bootloader, partition table and partitions, with
/// per-row dump and, for NVS and filesystem partitions, a way into their
/// tools. A partition table file can be opened and viewed the same way,
/// with or without a device. Nothing here writes; changes are planned on
/// the Flash page.
class PartitionsPage extends StatefulWidget {
  const PartitionsPage({super.key, required this.session, this.onOpenNvs, this.onOpenFilesystem, this.onOpenFlash, this.onPlanTable});
  final DeviceSession session;

  /// Called to plan changes against an opened table file in the Flash tool.
  final void Function(PartitionTable table, String source)? onPlanTable;

  /// Called with a partition name to browse it in the NVS tool.
  final ValueChanged<String>? onOpenNvs;

  /// Called with a partition name to browse it in the filesystem tool.
  final ValueChanged<String>? onOpenFilesystem;

  /// Called to show the Flash page (when a plan is waiting there).
  final VoidCallback? onOpenFlash;

  @override
  State<PartitionsPage> createState() => _PartitionsPageState();
}

class _PartitionsPageState extends State<PartitionsPage> {
  /// A table opened from a file, shown instead of the device's.
  PartitionTable? _fileTable;
  String? _fileName;
  String? _fileProblem;

  DeviceSession get session => widget.session;
  FlashPlan get plan => session.plan;

  Future<void> _openTable() async {
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
    String? problem;
    try {
      table.verify(partitionTableOffset: plan.partitionTableOffset);
    } catch (e) {
      problem = '$e';
    }
    setState(() {
      _fileTable = table;
      _fileName = file.name;
      _fileProblem = problem;
    });
    session.addLog('Opened ${file.name}: ${table.length} partitions${problem == null ? '' : ' — VERIFICATION FAILED: $problem'}');
  }

  void _closeTable() => setState(() {
        _fileTable = null;
        _fileName = null;
        _fileProblem = null;
      });

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
    if (mounted) Future<void>.microtask(session.ensureLayout);
  }

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
    if (zip != null) await saveBytes('${session.deviceStem}.zip', zip, mimeType: 'application/zip');
  }

  /// The tool that can browse [p] on the device, if any.
  ValueChanged<String>? _browser(PartitionDefinition p) {
    if (!p.isData) return null;
    if (p.subtype == DataSubtype.nvs.value) return widget.onOpenNvs;
    if (FsType.forPartition(p) != null) return widget.onOpenFilesystem;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final connected = session.connected;
    final fromFile = _fileTable != null;
    if (!connected && !fromFile) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Connect a device to see its partitions, or open a partition table file to view it.'),
          const SizedBox(height: 16),
          FilledButton.tonalIcon(onPressed: _openTable, icon: const Icon(Icons.table_chart_outlined), label: const Text('Open partition table…')),
        ]),
      );
    }
    final table = fromFile ? _fileTable : plan.deviceTable;
    final otadata = fromFile ? null : plan.otadata;
    final busy = session.busy;
    final scheme = Theme.of(context).colorScheme;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        if (connected && !fromFile) ...[
          FilledButton.tonalIcon(onPressed: busy ? null : session.readLayout, icon: const Icon(Icons.refresh), label: const Text('Re-read')),
          OutlinedButton.icon(onPressed: table == null || busy ? null : _dumpBundle, icon: const Icon(Icons.archive_outlined), label: const Text('Dump bundle')),
        ],
        OutlinedButton.icon(onPressed: _openTable, icon: const Icon(Icons.table_chart_outlined), label: const Text('Open table file…')),
        MenuAnchor(
          builder: (context, controller, _) => OutlinedButton.icon(
            onPressed: table == null ? null : () => controller.isOpen ? controller.close() : controller.open(),
            icon: const Icon(Icons.download),
            label: const Text('Table'),
          ),
          menuChildren: [
            MenuItemButton(onPressed: () => saveText('partitions.csv', table!.toCsv(), mimeType: 'text/csv'), child: const Text('Save as CSV')),
            MenuItemButton(onPressed: () => saveBytes('partition-table.bin', table!.toBinary()), child: const Text('Save as binary')),
            MenuItemButton(onPressed: () => showText(context, title: 'Partition table', text: table!.format(otadata: otadata)), child: const Text('Show as text')),
          ],
        ),
        if (otadata != null)
          Chip(
            avatar: const Icon(Icons.play_arrow, size: 18),
            label: Text(otadata.slot == null ? 'OTA slot not set (factory boots)' : 'Boots ota_${otadata.slot} (seq ${otadata.entry!.seq}, ${otadata.entry!.state.name})'),
          ),
      ]),
      const SizedBox(height: 12),
      if (fromFile) ...[
        MaterialBanner(
          backgroundColor: _fileProblem == null ? scheme.surfaceContainerHighest : scheme.errorContainer,
          leading: Icon(_fileProblem == null ? Icons.table_chart : Icons.error_outline),
          content:
              Text(_fileProblem == null ? 'Viewing $_fileName, not the device. Verification passed.' : 'Viewing $_fileName, not the device. VERIFICATION FAILED: $_fileProblem'),
          actions: [
            if (widget.onPlanTable != null) TextButton(onPressed: () => widget.onPlanTable!(_fileTable!, _fileName!), child: const Text('Plan changes against it')),
            TextButton(onPressed: _closeTable, child: Text(connected ? 'Back to device' : 'Close')),
          ],
        ),
        const SizedBox(height: 12),
      ],
      if (!plan.isEmpty) ...[
        MaterialBanner(
          backgroundColor: scheme.tertiaryContainer,
          leading: const Icon(Icons.pending_actions),
          content: Text('${plan.length} operation${plan.length == 1 ? '' : 's'} planned for this device, not flashed yet.'),
          actions: [if (widget.onOpenFlash != null) TextButton(onPressed: widget.onOpenFlash, child: const Text('Open Flash'))],
        ),
        const SizedBox(height: 12),
      ],
      if (table == null)
        busy
            ? const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))
            : Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text('Could not read the partition table — see the log.', style: TextStyle(color: scheme.error)),
                    const SizedBox(height: 8),
                    FilledButton.tonalIcon(onPressed: session.readLayout, icon: const Icon(Icons.refresh), label: const Text('Try again')),
                  ]),
                ),
              )
      else ...[
        PartitionGrid(
          rows: fromFile ? plan.rowsOf(table) : plan.deviceRows,
          table: table,
          activeSlot: otadata?.slot,
          contents: (p) => Text(fromFile ? '' : appContents(plan.deviceApps, p)),
          actions: (p) => fromFile
              ? const []
              : [
                  if (_browser(p) case final browse?)
                    TextButton.icon(onPressed: busy ? null : () => browse(p.name), icon: const Icon(Icons.folder_open, size: 18), label: const Text('Browse')),
                  TextButton.icon(onPressed: busy ? null : () => _dump(p), icon: const Icon(Icons.download, size: 18), label: const Text('Dump')),
                ],
        ),
        const SizedBox(height: 16),
        PartitionMap(
          rows: fromFile ? plan.rowsOf(table) : plan.deviceRows,
          flashSize: fromFile ? null : session.flashSize,
          activeSlot: otadata?.slot,
        ),
      ],
    ]);
  }
}
