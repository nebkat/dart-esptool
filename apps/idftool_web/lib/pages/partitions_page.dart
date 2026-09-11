import 'dart:typed_data';

import 'package:esptool/esptool.dart';
import 'package:flutter/material.dart';
import 'package:idftool/idftool.dart';

import '../session/device_session.dart';
import '../util/files.dart';
import '../widgets/dialogs.dart';

/// The device's partition table, with per-partition read/write/erase and
/// table export/replace.
class PartitionsPage extends StatefulWidget {
  const PartitionsPage({super.key, required this.session});
  final DeviceSession session;

  @override
  State<PartitionsPage> createState() => _PartitionsPageState();
}

class _PartitionsPageState extends State<PartitionsPage> {
  PartitionTable? _table;
  OtaDataParameters? _otadata;
  final _apps = <String, AppDescription>{};
  bool _loadedFor = false;

  DeviceSession get session => widget.session;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (session.connected && !_loadedFor && !session.busy) {
      _loadedFor = true;
      _refresh();
    }
    if (!session.connected) {
      _loadedFor = false;
      _table = null;
      _otadata = null;
      _apps.clear();
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
      final apps = <String, AppDescription>{};
      for (final p in table.where((p) => p.isApp)) {
        final head = await device.loader.readFlash(p.offset, ImageHeader.size + 8 + AppDescription.size);
        final desc = AppDescription.fromBytesOrNull(Uint8List.sublistView(head, ImageHeader.size + 8));
        if (desc != null) apps[p.name] = desc;
      }
      if (mounted) {
        setState(() {
          _table = table;
          _otadata = otadata;
          _apps
            ..clear()
            ..addAll(apps);
        });
      }
    });
  }

  Future<void> _read(PartitionDefinition p) async {
    final data = await session.runDevice('Read ${p.name}', (device) => device.readPartition(p.name, onProgress: session.reportProgress));
    if (data != null) await saveBytes('${p.name}.bin', data);
  }

  Future<void> _write(PartitionDefinition p) async {
    final file = await pickFile();
    if (file == null || !mounted) return;
    if (file.bytes.length > p.size) {
      session.addLog('${file.name} (${file.bytes.length.bytesString}) does not fit in ${p.name} (${p.size.bytesString})', error: true);
      return;
    }
    if (!await confirm(context,
        title: 'Write ${p.name}?', message: 'Write ${file.name} (${file.bytes.length.bytesString}) to partition ${p.name} at ${p.offset.hex}.')) {
      return;
    }
    final outcome = await session.runDevice('Write ${file.name} to ${p.name}',
        (device) => device.writePartition(p.name, file.bytes, onProgress: session.reportProgress));
    if (outcome != null) session.addLog(_describe(outcome));
    await _refresh();
  }

  Future<void> _erase(PartitionDefinition p) async {
    if (!await confirm(context,
        title: 'Erase ${p.name}?', message: 'Erase ${p.size.bytesString} at ${p.offset.hex}. This cannot be undone.', action: 'Erase', destructive: true)) {
      return;
    }
    await session.runDevice('Erase ${p.name}', (device) => device.erasePartition(p.name));
    await _refresh();
  }

  Future<void> _setBoot(PartitionDefinition p) async {
    await session.runDevice('Set boot partition to ${p.name}', (device) => device.setBoot(p.name));
    await _refresh();
  }

  Future<void> _replaceTable() async {
    final file = await pickFile(extensions: ['csv', 'bin']);
    if (file == null || !mounted) return;
    final device = session.device;
    if (device == null) return;
    final PartitionTable table;
    try {
      table = PartitionTable.isBinary(file.bytes)
          ? PartitionTable.fromBinary(file.bytes)
          : parsePartitionTableCsv(PartitionTable.decodeCsv(file.bytes),
              source: file.name, partitionTableOffset: device.partitionTableOffset, primaryBootloaderOffset: device.primaryBootloaderOffset);
    } catch (e) {
      session.addLog('Could not parse ${file.name}: $e', error: true);
      return;
    }
    String? problem;
    try {
      table.verify(partitionTableOffset: device.partitionTableOffset);
      if (session.flashSize != null) table.verifySizeFits(session.flashSize!);
    } catch (e) {
      problem = '$e';
    }
    if (!mounted) return;
    final ok = await confirm(context,
        title: 'Replace the partition table?',
        message: '${table.format()}\n\n'
            '${problem == null ? 'Verification passed.' : 'VERIFICATION FAILED: $problem'}\n\n'
            'This replaces only the partition map at ${device.partitionTableOffset.hex}; existing partition data is not moved, resized or erased. '
            'A table that no longer matches the flash contents can make the device unbootable.',
        action: problem == null ? 'Write table' : 'Write anyway',
        destructive: true);
    if (!ok) return;
    await session.runDevice('Write partition table', (device) => device.writePartitionTable(table, force: true));
    await _refresh();
  }

  static String _describe(WriteOutcome o) => o.skipped
      ? 'Already in flash, nothing written'
      : 'Wrote ${o.written.bytesString} in ${o.runs} region${o.runs == 1 ? '' : 's'} in ${(o.elapsed.inMilliseconds / 1000).toStringAsFixed(1)} s'
          '${o.abandoned ? ' (comparison abandoned part-way)' : ''}';

  @override
  Widget build(BuildContext context) {
    if (!session.connected) return const Center(child: Text('Connect to a device first.'));
    final table = _table;
    final busy = session.busy;
    final activeSlot = _otadata?.slot;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        FilledButton.tonalIcon(onPressed: busy ? null : _refresh, icon: const Icon(Icons.refresh), label: const Text('Re-read')),
        OutlinedButton.icon(
          onPressed: table == null ? null : () => saveText('partitions.csv', table.toCsv(), mimeType: 'text/csv'),
          icon: const Icon(Icons.download),
          label: const Text('CSV'),
        ),
        OutlinedButton.icon(
          onPressed: table == null ? null : () => saveBytes('partition-table.bin', table.toBinary()),
          icon: const Icon(Icons.download),
          label: const Text('Binary'),
        ),
        OutlinedButton.icon(
          onPressed: table == null ? null : () => showText(context, title: 'Partition table', text: table.format(otadata: _otadata)),
          icon: const Icon(Icons.article_outlined),
          label: const Text('Text'),
        ),
        const SizedBox(width: 16),
        FilledButton.tonalIcon(
          onPressed: busy ? null : _replaceTable,
          icon: const Icon(Icons.upload_file),
          label: const Text('Replace table from file…'),
        ),
        if (_otadata != null)
          Chip(
            avatar: const Icon(Icons.play_arrow, size: 18),
            label: Text(activeSlot == null
                ? 'OTA slot not set (factory boots)'
                : 'Boots ota_$activeSlot (seq ${_otadata!.entry!.seq}, ${_otadata!.entry!.state.name})'),
          ),
      ]),
      const SizedBox(height: 12),
      if (table == null)
        const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))
      else
        Card(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columnSpacing: 20,
              columns: const [
                DataColumn(label: Text('Name')),
                DataColumn(label: Text('Type')),
                DataColumn(label: Text('Subtype')),
                DataColumn(label: Text('Offset')),
                DataColumn(label: Text('Size')),
                DataColumn(label: Text('Flags')),
                DataColumn(label: Text('Contents')),
                DataColumn(label: Text('')),
              ],
              rows: [
                for (final p in table)
                  DataRow(cells: [
                    DataCell(Row(children: [
                      Text(p.name, style: const TextStyle(fontFamily: 'monospace')),
                      if (p.isOtaApp && activeSlot == p.subtype - AppSubtype.otaMin)
                        const Padding(padding: EdgeInsets.only(left: 6), child: Icon(Icons.play_arrow, size: 16, color: Colors.green)),
                    ])),
                    DataCell(_TypeChip(p.typeName, _typeColor(p, context))),
                    DataCell(_TypeChip(p.subtypeName, _typeColor(p, context), outlined: true)),
                    DataCell(Text(p.offset.hex, style: const TextStyle(fontFamily: 'monospace'))),
                    DataCell(Text('${p.size.hex} (${p.size.bytesString})', style: const TextStyle(fontFamily: 'monospace'))),
                    DataCell(Text(p.flagNames.join(', '))),
                    DataCell(Text(_apps[p.name] == null ? '' : '${_apps[p.name]!.projectName} ${_apps[p.name]!.version}')),
                    DataCell(Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(tooltip: 'Read to file', icon: const Icon(Icons.download, size: 20), onPressed: busy ? null : () => _read(p)),
                      IconButton(tooltip: 'Write file…', icon: const Icon(Icons.upload, size: 20), onPressed: busy ? null : () => _write(p)),
                      IconButton(tooltip: 'Erase', icon: const Icon(Icons.delete_outline, size: 20), onPressed: busy ? null : () => _erase(p)),
                      if (p.isOtaApp && _otadata != null)
                        IconButton(tooltip: 'Boot this slot', icon: const Icon(Icons.play_circle_outline, size: 20), onPressed: busy ? null : () => _setBoot(p)),
                    ])),
                  ]),
              ],
            ),
          ),
        ),
    ]);
  }
}

/// One hue per partition type so the table scans by kind: bootloader and
/// partition-table rows in the chip's own colours, apps and the data
/// subtypes people care about (nvs, otadata, filesystems) each distinct.
Color _typeColor(PartitionDefinition p, BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  return switch (p.knownType) {
    PartitionType.bootloader => Colors.deepOrange,
    PartitionType.partitionTable => Colors.brown,
    PartitionType.app => p.subtype == AppSubtype.factory.value ? Colors.teal : Colors.green,
    PartitionType.data => switch (p.subtype) {
        _ when p.subtype == DataSubtype.nvs.value => Colors.blue,
        _ when p.subtype == DataSubtype.ota.value => Colors.lightGreen,
        _ when p.subtype == DataSubtype.phy.value => Colors.blueGrey,
        _ when p.subtype == DataSubtype.coredump.value => Colors.red,
        _ when p.subtype == DataSubtype.spiffs.value || p.subtype == DataSubtype.littlefs.value || p.subtype == DataSubtype.fat.value => Colors.purple,
        _ => Colors.indigo,
      },
    null => scheme.outline,
  };
}

class _TypeChip extends StatelessWidget {
  const _TypeChip(this.label, this.color, {this.outlined = false});
  final String label;
  final Color color;
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final fill = outlined ? Colors.transparent : color.withValues(alpha: dark ? 0.35 : 0.18);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: fill,
        border: Border.all(color: color.withValues(alpha: 0.7)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(label, style: TextStyle(fontSize: 12, color: dark ? Color.lerp(color, Colors.white, 0.4) : Color.lerp(color, Colors.black, 0.3))),
    );
  }
}
