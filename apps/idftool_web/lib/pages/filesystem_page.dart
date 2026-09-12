import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:idftool/idftool.dart';

import '../session/device_session.dart';
import '../util/files.dart';
import '../widgets/dialogs.dart';
import '../widgets/type_chip.dart';

/// Browse a filesystem partition (LittleFS, SPIFFS, FAT) or an image file:
/// tree of files, view/download, extract everything as a ZIP, and replace
/// the partition from an image or (SPIFFS/FAT) a ZIP of files.
class FilesystemPage extends StatefulWidget {
  const FilesystemPage({super.key, required this.session, this.initialPartition});
  final DeviceSession session;

  /// The filesystem partition to open first, by name (the first one if `null`).
  final String? initialPartition;

  @override
  State<FilesystemPage> createState() => _FilesystemPageState();
}

class _FilesystemPageState extends State<FilesystemPage> {
  List<PartitionDefinition> _fsPartitions = const [];
  PartitionDefinition? _partition;
  FsVolume? _volume;
  String? _sourceLabel;
  int? _imageSize;
  FsType? _typeOverride;
  bool _loadedFor = false;
  final _collapsed = <String>{};

  /// The file shown in the right-hand pane, its bytes, and whether it is
  /// shown as hex (`null` = decide from the content).
  FsEntry? _selected;
  Uint8List? _selectedBytes;
  bool? _hex;

  DeviceSession get session => widget.session;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (session.connected && !_loadedFor && !session.busy) {
      _loadedFor = true;
      _load();
    }
    if (!session.connected) _loadedFor = false;
  }

  Future<void> _load() async {
    await session.runDevice('Read filesystem', (device) async {
      final table = await device.partitionTable();
      final partitions = table.where((p) => FsType.forPartition(p) != null).toList();
      final wanted = _partition?.name ?? widget.initialPartition;
      final partition = partitions.where((p) => p.name == wanted).firstOrNull ?? partitions.firstOrNull;
      if (partition == null) throw IdfToolException('No filesystem partition in the partition table');
      final (partition: _, volume: volume) =
          await device.readFs(name: partition.name, type: _typeOverride, onProgress: session.reportProgress);
      for (final e in volume.errors) {
        session.addLog('${volume.type.label}: $e', error: true);
      }
      session.addLog('${partition.name}: ${volume.describe()}, ${volume.entries.where((e) => !e.isDir).length} files');
      if (mounted) {
        setState(() {
          _fsPartitions = partitions;
          _partition = partition;
          _volume = volume;
          _sourceLabel = "partition '${partition.name}'";
          _imageSize = partition.size;
          _collapsed.clear();
          _selected = null;
          _selectedBytes = null;
        });
      }
    });
  }

  Future<void> _openImage() async {
    final file = await pickFile();
    if (file == null) return;
    try {
      final volume = FsVolume.mount(file.bytes, type: _typeOverride);
      for (final e in volume.errors) {
        session.addLog('${volume.type.label}: $e', error: true);
      }
      setState(() {
        _volume = volume;
        _sourceLabel = file.name;
        _imageSize = file.bytes.length;
        _collapsed.clear();
        _selected = null;
        _selectedBytes = null;
      });
    } catch (e) {
      session.addLog('Could not mount ${file.name}: $e', error: true);
    }
  }

  Future<void> _replaceFromImage() async {
    final p = _partition;
    if (p == null) return;
    final file = await pickFile();
    if (file == null || !mounted) return;
    final type = FsType.detect(file.bytes);
    if (type == null) {
      session.addLog('${file.name} does not look like a filesystem image', error: true);
      return;
    }
    if (!await confirm(context,
        title: 'Replace ${p.name}?',
        message: 'Write ${file.name} (${type.label}, ${file.bytes.length.bytesString}) over partition ${p.name} (${p.size.bytesString}).'
            '${file.bytes.length < p.size ? '\n\nThe image is smaller than the partition; it must have been built for this size to mount.' : ''}',
        destructive: true)) {
      return;
    }
    await session.runDevice('Write ${file.name} to ${p.name}',
        (d) => d.writeFs(file.bytes, partitionName: p.name, onProgress: session.reportProgress));
    await _load();
  }

  Future<void> _replaceFromZip() async {
    final p = _partition;
    if (p == null) return;
    final type = FsType.forPartition(p) ?? _typeOverride;
    if (type == null) return;
    final file = await pickFile(extensions: ['zip']);
    if (file == null || !mounted) return;
    final Uint8List image;
    try {
      image = createFs(type, sourcesFromZip(file.bytes), p.size);
    } catch (e) {
      session.addLog('Could not build ${type.label} image from ${file.name}: $e', error: true);
      return;
    }
    if (!await confirm(context,
        title: 'Replace ${p.name}?',
        message: 'Build a ${type.label} image from the files in ${file.name} and write it over partition ${p.name}.',
        destructive: true)) {
      return;
    }
    await session.runDevice('Write ${type.label} from ${file.name} to ${p.name}',
        (d) => d.writeFs(image, partitionName: p.name, onProgress: session.reportProgress));
    await _load();
  }

  void _select(FsEntry e) {
    Uint8List? bytes;
    try {
      bytes = _volume!.read(e.path);
    } catch (err) {
      session.addLog('Could not read ${e.path}: $err', error: true);
    }
    setState(() {
      _selected = e;
      _selectedBytes = bytes;
      _hex = null;
    });
  }

  /// Text if it decodes as UTF-8 without control characters (tabs and
  /// newlines aside); otherwise it's binary and shown as hex.
  static bool _looksLikeText(Uint8List bytes) {
    if (bytes.isEmpty) return true;
    try {
      final text = utf8.decode(bytes);
      return !text.codeUnits.any((c) => c < 9 || (c > 13 && c < 32) || c == 127);
    } on FormatException {
      return false;
    }
  }

  static String _hexDump(Uint8List data) {
    final out = StringBuffer();
    for (var i = 0; i < data.length && i < 0x10000; i += 16) {
      final row = data.sublist(i, (i + 16).clamp(0, data.length));
      final hex = row.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ').padRight(47);
      final ascii = row.map((b) => b >= 32 && b < 127 ? String.fromCharCode(b) : '.').join();
      out.writeln('${i.toRadixString(16).padLeft(8, '0')}  $hex  |$ascii|');
    }
    if (data.length > 0x10000) out.writeln('… (${data.length - 0x10000} more bytes)');
    return out.toString();
  }

  @override
  Widget build(BuildContext context) {
    final volume = _volume;
    final busy = session.busy;
    final theme = Theme.of(context);
    final canBuild = _partition != null && (FsType.forPartition(_partition!) ?? _typeOverride) != FsType.littlefs;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 0), child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        if (session.connected) ...[
          if (_fsPartitions.length > 1)
            DropdownButton<PartitionDefinition>(
              value: _partition,
              items: [
                for (final p in _fsPartitions)
                  DropdownMenuItem(value: p, child: Text('${p.name} (${p.subtypeName}, ${p.size.bytesString})')),
              ],
              onChanged: busy
                  ? null
                  : (p) {
                      _partition = p;
                      _load();
                    },
            )
          else if (_partition != null)
            Text('${_partition!.name} (${_partition!.subtypeName}, ${_partition!.size.bytesString})', style: theme.textTheme.titleMedium),
          FilledButton.tonalIcon(onPressed: busy ? null : _load, icon: const Icon(Icons.refresh), label: const Text('Re-read')),
        ],
        OutlinedButton.icon(onPressed: busy ? null : _openImage, icon: const Icon(Icons.folder_open), label: const Text('Open image file…')),
        DropdownButton<FsType?>(
          value: _typeOverride,
          hint: const Text('Type: auto'),
          items: [
            const DropdownMenuItem(value: null, child: Text('Type: auto')),
            for (final t in FsType.values) DropdownMenuItem(value: t, child: Text('Type: ${t.label}')),
          ],
          onChanged: (t) => setState(() => _typeOverride = t),
        ),
        if (volume != null) ...[
          OutlinedButton.icon(
            onPressed: () => saveBytes('${_partition?.name ?? 'fs'}.zip', volume.toZip(), mimeType: 'application/zip'),
            icon: const Icon(Icons.download),
            label: const Text('Extract all (zip)'),
          ),
          OutlinedButton.icon(
            onPressed: () => showText(context, title: _sourceLabel ?? '', text: '${volume.describe()}\n\n${formatFsListing(volume.entries)}'),
            icon: const Icon(Icons.article_outlined),
            label: const Text('Text'),
          ),
        ],
        if (session.connected && _partition != null) ...[
          const SizedBox(width: 16),
          OutlinedButton.icon(onPressed: busy ? null : _replaceFromImage, icon: const Icon(Icons.upload_file), label: const Text('Replace from image…')),
          OutlinedButton.icon(
            onPressed: busy || !canBuild ? null : _replaceFromZip,
            icon: const Icon(Icons.upload_file),
            label: Text(canBuild ? 'Replace from ZIP of files…' : 'Replace from ZIP (LittleFS build not supported)'),
          ),
        ],
      ])),
      const SizedBox(height: 8),
      if (volume == null)
        Expanded(
          child: Center(child: Text(session.connected ? 'Reading…' : 'Connect to a device, or open a filesystem image file.')),
        )
      else ...[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            TypeChip(volume.type.label, _fsColor(volume.type)),
            const SizedBox(width: 8),
            Expanded(
              child: Text('${_sourceLabel ?? ''}: ${volume.describe()}, ${_imageSize?.bytesString ?? ''} · '
                  '${volume.entries.where((e) => !e.isDir).length} files, '
                  '${volume.entries.where((e) => !e.isDir).fold(0, (n, e) => n + e.size).bytesString}'),
            ),
          ]),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // Browser on the left, viewer on the right; each scrolls on its own.
            SizedBox(
              width: 420,
              child: Card(
                margin: const EdgeInsets.fromLTRB(16, 0, 8, 12),
                child: SingleChildScrollView(child: _tree(volume, busy)),
              ),
            ),
            Expanded(
              child: Card(margin: const EdgeInsets.fromLTRB(8, 0, 16, 12), child: _viewer(volume)),
            ),
          ]),
        ),
      ],
    ]);
  }

  Widget _viewer(FsVolume volume) {
    final e = _selected;
    final bytes = _selectedBytes;
    final theme = Theme.of(context);
    if (e == null || bytes == null) {
      return const Center(child: Text('Select a file to view it.'));
    }
    final asHex = _hex ?? !_looksLikeText(bytes);
    final text = asHex ? _hexDump(bytes) : utf8.decode(bytes, allowMalformed: true);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
        child: Row(children: [
          Expanded(
            child: Text('${e.path}  ·  ${e.size.bytesString}',
                style: const TextStyle(fontFamily: 'RobotoMono', fontSize: 13), overflow: TextOverflow.ellipsis),
          ),
          SegmentedButton<bool>(
            segments: const [ButtonSegment(value: false, label: Text('Text')), ButtonSegment(value: true, label: Text('Hex'))],
            selected: {asHex},
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            onSelectionChanged: (v) => setState(() => _hex = v.first),
          ),
          IconButton(tooltip: 'Download', icon: const Icon(Icons.download, size: 20), onPressed: () => saveBytes(e.name, bytes)),
        ]),
      ),
      const Divider(height: 1),
      Expanded(
        child: SelectionArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Text(text, style: TextStyle(fontFamily: 'RobotoMono', fontSize: 12, color: theme.colorScheme.onSurface)),
            ),
          ),
        ),
      ),
    ]);
  }

  Color _fsColor(FsType t) => switch (t) {
        FsType.littlefs => HSLColor.fromAHSL(1, 265, 0.5, 0.5).toColor(),
        FsType.spiffs => HSLColor.fromAHSL(1, 290, 0.5, 0.5).toColor(),
        FsType.fatfs => HSLColor.fromAHSL(1, 240, 0.5, 0.5).toColor(),
      };

  /// The listing as an indented tree; directories collapse. SPIFFS has no
  /// directories, so its '/'-containing names are grouped by prefix here.
  Widget _tree(FsVolume volume, bool busy) {
    final entries = List.of(volume.entries)..sort((a, b) => a.path.compareTo(b.path));
    // Synthesise directory rows for path prefixes that have no entry (SPIFFS).
    final known = {for (final e in entries) e.path};
    final synthetic = <FsEntry>[];
    for (final e in entries) {
      var p = e.parent;
      while (p.isNotEmpty && known.add(p)) {
        synthetic.add(FsEntry(path: p, isDir: true, size: 0));
        p = FsEntry(path: p, isDir: true, size: 0).parent;
      }
    }
    final all = [...entries, ...synthetic]..sort((a, b) => a.path.compareTo(b.path));
    bool hidden(FsEntry e) {
      var p = e.parent;
      while (p.isNotEmpty) {
        if (_collapsed.contains(p)) return true;
        p = FsEntry(path: p, isDir: true, size: 0).parent;
      }
      return false;
    }

    final rows = <Widget>[];
    for (final e in all.where((e) => !hidden(e))) {
      final depth = '/'.allMatches(e.path).length;
      final selected = !e.isDir && _selected?.path == e.path;
      rows.add(InkWell(
        onTap: e.isDir
            ? () => setState(() => _collapsed.contains(e.path) ? _collapsed.remove(e.path) : _collapsed.add(e.path))
            : () => _select(e),
        child: Container(
          color: selected ? Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.4) : null,
          padding: EdgeInsets.only(left: 12.0 + depth * 20, right: 8, top: 3, bottom: 3),
          child: Row(children: [
            Icon(
              e.isDir ? (_collapsed.contains(e.path) ? Icons.folder : Icons.folder_open) : Icons.insert_drive_file_outlined,
              size: 18,
              color: e.isDir ? Colors.amber : null,
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(e.name, style: const TextStyle(fontFamily: 'RobotoMono', fontSize: 13), overflow: TextOverflow.ellipsis)),
            if (!e.isDir)
              Text(e.size.bytesString, style: TextStyle(fontFamily: 'RobotoMono', fontSize: 12, color: Theme.of(context).hintColor)),
          ]),
        ),
      ));
    }
    if (rows.isEmpty) return const Padding(padding: EdgeInsets.all(16), child: Text('(empty)'));
    return Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows));
  }
}
