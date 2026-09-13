import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:idftool/idftool.dart';

import '../session/device_session.dart';
import '../util/files.dart';
import '../util/inspect.dart';
import '../widgets/type_chip.dart';
import '../widgets/dropdown.dart';
import '../widgets/empty_state.dart';

/// Open any idftool file without a device — partition tables, flash images,
/// app and bootloader images, bundles, NVS images and CSVs, filesystem
/// images and ZIPs of files — see what is in it, convert it, and hand
/// tables and bundles to the partitions planner.
class InspectPage extends StatefulWidget {
  const InspectPage({super.key, required this.session, this.onPlanTable, this.onPlanBundle, this.onOpenData});
  final DeviceSession session;

  /// Open an NVS or filesystem file in the Data tool.
  final void Function(PickedFile file)? onOpenData;

  /// Plan changes against this table in the partitions tool.
  final void Function(PartitionTable table, String source)? onPlanTable;

  /// Stage this bundle in the partitions tool.
  final void Function(Uint8List zip, String name)? onPlanBundle;

  @override
  State<InspectPage> createState() => _InspectPageState();
}

class _InspectPageState extends State<InspectPage> {
  Inspected? _current;
  bool _busy = false;
  bool _dragging = false;
  final _size = TextEditingController(text: '0x6000');
  FsType _fsType = FsType.fatfs;

  DeviceSession get session => widget.session;

  @override
  void dispose() {
    _size.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    final file = await pickFile();
    if (file == null || !mounted) return;
    await _inspect(file);
  }

  Future<void> _inspect(PickedFile file) async {
    setState(() => _busy = true);
    try {
      final result = await inspectFile(file);
      if (!mounted) return;
      setState(() {
        _current = result;
        if (result.kind == FileKind.fsImage) _size.text = file.bytes.length.hex;
      });
      session.addLog('${file.name}: ${result.kind.label.toLowerCase()} — ${result.summary}');
    } catch (e) {
      session.addLog('Could not inspect ${file.name}: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _onDrop(DropDoneDetails d) async {
    setState(() => _dragging = false);
    if (d.files.isEmpty) return;
    if (d.files.length > 1) session.addLog('Inspecting the first of ${d.files.length} dropped files');
    final f = d.files.first;
    await _inspect((name: f.name, bytes: await f.readAsBytes()));
  }

  int? _sizeValue() {
    final t = _size.text.trim().toLowerCase();
    final v = t.startsWith('0x') ? int.tryParse(t.substring(2), radix: 16) : int.tryParse(t);
    if (v == null || v <= 0) session.addLog('Size "${_size.text}" is not a positive number (try 0x6000)', error: true);
    return v;
  }

  // --------------------------------------------------------------------------
  // Actions
  // --------------------------------------------------------------------------

  Future<void> _splitToBundle(Inspected i) async {
    final table = i.table!;
    final bytes = i.file.bytes;
    final archive = Archive();
    Uint8List slice(int offset, int length) {
      final end = (offset + length).clamp(0, bytes.length);
      return offset >= bytes.length ? Uint8List(0) : Uint8List.sublistView(bytes, offset, end);
    }

    if (i.bootloader case final chip?) {
      archive.add(ArchiveFile.bytes('bootloader.bin', slice(chip.bootloaderFlashOffset, PartitionTable.defaultOffset - chip.bootloaderFlashOffset)));
    }
    var skipped = 0;
    for (final p in table) {
      final data = slice(p.offset, p.size);
      if (data.isEmpty) {
        skipped++;
        continue;
      }
      archive.add(ArchiveFile.bytes('${p.name}.bin', data));
    }
    archive.add(ArchiveFile.string('partition_table.csv', table.toCsv()));
    if (skipped > 0) session.addLog('$skipped partition${skipped == 1 ? '' : 's'} lie beyond the end of the image and were left out');
    await saveBytes('${i.stem}.zip', ZipEncoder().encodeBytes(archive), mimeType: 'application/zip');
  }

  Future<void> _buildNvs(Inspected i) async {
    final size = _sizeValue();
    if (size == null) return;
    final Uint8List image;
    try {
      image = generateNvsImage(utf8.decode(i.file.bytes), size);
    } catch (e) {
      session.addLog('Could not build an NVS image from ${i.file.name}: $e', error: true);
      return;
    }
    session.addLog('Built ${image.length.bytesString} NVS image from ${i.file.name}');
    await saveBytes('${i.stem}.bin', image);
  }

  Future<void> _buildFs(Inspected i) async {
    final size = _sizeValue();
    if (size == null) return;
    final Uint8List image;
    try {
      image = createFs(_fsType, sourcesFromZip(i.file.bytes), size);
    } catch (e) {
      session.addLog('Could not build a ${_fsType.label} image from ${i.file.name}: $e', error: true);
      return;
    }
    session.addLog('Built ${image.length.bytesString} ${_fsType.label} image from ${i.file.name}');
    await saveBytes('${i.stem}.bin', image);
  }

  List<Widget> _actions(Inspected i) {
    final table = i.table;
    return switch (i.kind) {
      FileKind.partitionTable || FileKind.flashImage => [
          OutlinedButton.icon(
              onPressed: () => saveText('${i.stem}.csv', table!.toCsv(), mimeType: 'text/csv'), icon: const Icon(Icons.download), label: const Text('Save table as CSV')),
          OutlinedButton.icon(onPressed: () => saveBytes('${i.stem}-table.bin', table!.toBinary()), icon: const Icon(Icons.download), label: const Text('Save table as binary')),
          if (i.kind == FileKind.flashImage)
            OutlinedButton.icon(onPressed: () => _splitToBundle(i), icon: const Icon(Icons.archive_outlined), label: const Text('Split into bundle')),
          if (widget.onPlanTable != null)
            FilledButton.tonalIcon(
                onPressed: () => widget.onPlanTable!(table!, i.file.name), icon: const Icon(Icons.edit_outlined), label: const Text('Plan changes against this table')),
        ],
      FileKind.bundle => [
          OutlinedButton.icon(
              onPressed: () => saveText('${i.stem}.csv', table!.toCsv(), mimeType: 'text/csv'), icon: const Icon(Icons.download), label: const Text('Save table as CSV')),
          if (widget.onPlanBundle != null)
            FilledButton.tonalIcon(onPressed: () => widget.onPlanBundle!(i.file.bytes, i.file.name), icon: const Icon(Icons.edit_outlined), label: const Text('Plan this bundle')),
        ],
      FileKind.nvsImage => [
          if (widget.onOpenData != null) FilledButton.tonalIcon(onPressed: () => widget.onOpenData!(i.file), icon: const Icon(Icons.storage), label: const Text('Open in Data')),
          if (!i.nvs!.looksEncrypted)
            OutlinedButton.icon(
                onPressed: () => saveText('${i.stem}.csv', nvsToCsv(i.nvs!.entries), mimeType: 'text/csv'), icon: const Icon(Icons.download), label: const Text('Save as CSV')),
        ],
      FileKind.nvsCsv => [
          if (widget.onOpenData != null) FilledButton.tonalIcon(onPressed: () => widget.onOpenData!(i.file), icon: const Icon(Icons.storage), label: const Text('Open in Data')),
          _sizeField('Image size'),
          FilledButton.tonalIcon(onPressed: () => _buildNvs(i), icon: const Icon(Icons.build_outlined), label: const Text('Build NVS image')),
        ],
      FileKind.fsImage => [
          if (widget.onOpenData != null) FilledButton.tonalIcon(onPressed: () => widget.onOpenData!(i.file), icon: const Icon(Icons.storage), label: const Text('Open in Data')),
          OutlinedButton.icon(
              onPressed: () => saveBytes('${i.stem}.zip', i.volume!.toZip(), mimeType: 'application/zip'),
              icon: const Icon(Icons.download),
              label: const Text('Extract all (zip)')),
        ],
      FileKind.fileZip => [
          AppDropdown<FsType>(
            value: _fsType,
            label: 'Type',
            entries: [for (final t in FsType.values.where((t) => t != FsType.littlefs)) DropdownMenuEntry(value: t, label: t.label)],
            onSelected: (t) => setState(() => _fsType = t ?? _fsType),
          ),
          _sizeField('Image size'),
          FilledButton.tonalIcon(onPressed: () => _buildFs(i), icon: const Icon(Icons.build_outlined), label: const Text('Build filesystem image')),
        ],
      FileKind.appImage || FileKind.bootloaderImage || FileKind.unknown => const [],
    };
  }

  Widget _sizeField(String label) => SizedBox(
        width: 160,
        child: TextField(
          controller: _size,
          decoration: InputDecoration(labelText: label, isDense: true, border: const OutlineInputBorder()),
          style: const TextStyle(fontFamily: 'RobotoMono', fontSize: 13),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final i = _current;
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: _onDrop,
      child: Container(
        decoration: _dragging ? BoxDecoration(border: Border.all(color: scheme.primary, width: 2)) : null,
        child: i == null && !_busy
            ? EmptyState(
                icon: Icons.folder_open,
                title: 'Nothing opened',
                message: 'Open a file, or drop one anywhere on this page, to see what is in it: partition tables, flash images, app and bootloader images, '
                    'bundles, NVS images and CSVs, filesystem images and ZIPs of files. No device needed.',
                actions: [FilledButton.tonalIcon(onPressed: _open, icon: const Icon(Icons.folder_open), label: const Text('Open file…'))],
              )
            : ListView(padding: const EdgeInsets.all(16), children: [
                Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  FilledButton.tonalIcon(onPressed: _busy ? null : _open, icon: const Icon(Icons.folder_open), label: const Text('Open file…')),
                  Text('or drop a file anywhere on this page.', style: TextStyle(color: scheme.outline)),
                ]),
                const SizedBox(height: 12),
                if (_busy)
                  const LoadingState('Inspecting…')
                else if (i != null) ...[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          TypeChip(i.kind.label, _kindColor(i.kind)),
                          const SizedBox(width: 12),
                          Expanded(child: Text(i.file.name, style: theme.textTheme.titleMedium)),
                          Text(i.file.bytes.length.bytesString, style: TextStyle(color: scheme.outline)),
                        ]),
                        const SizedBox(height: 8),
                        Text(i.summary),
                        if (i.problem != null) ...[
                          const SizedBox(height: 8),
                          Text('Table verification failed: ${i.problem}', style: TextStyle(color: scheme.error)),
                        ] else if (i.table != null) ...[
                          const SizedBox(height: 8),
                          Text('Table verification passed.', style: TextStyle(color: scheme.outline)),
                        ],
                        if (_actions(i) case final actions when actions.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: actions),
                        ],
                      ]),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: SelectableText(i.report, style: const TextStyle(fontFamily: 'RobotoMono', fontSize: 12)),
                      ),
                    ),
                  ),
                ],
              ]),
      ),
    );
  }

  static Color _kindColor(FileKind k) => switch (k) {
        FileKind.partitionTable => HSLColor.fromAHSL(1, 45, 0.6, 0.45).toColor(),
        FileKind.flashImage => HSLColor.fromAHSL(1, 20, 0.6, 0.45).toColor(),
        FileKind.appImage => HSLColor.fromAHSL(1, 140, 0.6, 0.4).toColor(),
        FileKind.bootloaderImage => HSLColor.fromAHSL(1, 20, 0.6, 0.45).toColor(),
        FileKind.bundle => HSLColor.fromAHSL(1, 320, 0.5, 0.45).toColor(),
        FileKind.nvsImage || FileKind.nvsCsv => HSLColor.fromAHSL(1, 215, 0.6, 0.45).toColor(),
        FileKind.fsImage || FileKind.fileZip => HSLColor.fromAHSL(1, 275, 0.5, 0.5).toColor(),
        FileKind.unknown => Colors.grey,
      };
}
