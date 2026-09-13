import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:idftool/idftool.dart';

import '../session/device_session.dart';
import '../util/files.dart';
import '../widgets/dialogs.dart';
import '../widgets/dropdown.dart';
import '../widgets/empty_state.dart';
import '../widgets/fs_browser.dart';
import '../widgets/nvs_editor.dart';
import '../widgets/partition_item.dart';

/// What the page is showing: an NVS image to edit, or a filesystem to browse.
sealed class _Content {}

class _Nvs extends _Content {
  _Nvs(this.image);
  final NvsImage image;
}

class _Fs extends _Content {
  _Fs(this.volume, this.size);
  final FsVolume volume;
  final int size;
}

/// The data partitions — NVS and filesystems (LittleFS, SPIFFS, FAT) — as
/// one tool: pick a partition on the device, or open an image or NVS CSV
/// file, and the content decides whether you get the NVS editor or the file
/// browser. The partition's subtype or the file's contents say which.
class DataPage extends StatefulWidget {
  const DataPage({super.key, required this.session, this.initialPartition, this.initialFile});
  final DeviceSession session;

  /// The partition to open first, by name.
  final String? initialPartition;

  /// A file to open instead of anything on the device.
  final PickedFile? initialFile;

  @override
  State<DataPage> createState() => _DataPageState();
}

class _DataPageState extends State<DataPage> {
  List<PartitionDefinition> _partitions = const [];
  PartitionDefinition? _partition;
  _Content? _content;

  /// The file the content came from, when it wasn't read from the device.
  String? _source;
  FsType? _typeOverride;
  bool _listedFor = false;

  DeviceSession get session => widget.session;
  bool get _fromFile => _content != null && _partition == null;
  String get _sourceLabel => _source ?? _partition?.name ?? '';
  String get _stem {
    final s = _sourceLabel.isEmpty ? 'data' : _sourceLabel;
    return s.contains('.') ? s.substring(0, s.lastIndexOf('.')) : s;
  }

  static bool _isNvs(PartitionDefinition p) => p.isData && p.subtype == DataSubtype.nvs.value;
  static bool _isData(PartitionDefinition p) => _isNvs(p) || FsType.forPartition(p) != null;

  @override
  void initState() {
    super.initState();
    session.addListener(_onSessionChanged);
    _onSessionChanged();
    if (widget.initialFile case final f?) _openBytes(f);
  }

  @override
  void dispose() {
    session.removeListener(_onSessionChanged);
    super.dispose();
  }

  /// On connect, list the data partitions; nothing is read until one is
  /// picked, unless the page was opened for a specific partition.
  void _onSessionChanged() {
    if (!mounted) return;
    if (session.connected && !_listedFor && !session.busy) {
      _listedFor = true;
      Future<void>.microtask(_listPartitions);
    }
    if (!session.connected && _listedFor) {
      _listedFor = false;
      setState(() {
        _partitions = const [];
        if (_partition != null) {
          // an opened file survives; a device partition does not
          _content = null;
          _partition = null;
        }
      });
    }
  }

  Future<void> _listPartitions() async {
    final partitions = await session.runDevice('List data partitions', (device) async => (await device.partitionTable()).where(_isData).toList());
    if (partitions == null || !mounted) return;
    setState(() => _partitions = partitions);
    if (partitions.isEmpty) session.addLog('No NVS or filesystem partition in the partition table', error: true);
    final wanted = partitions.where((p) => p.name == widget.initialPartition).firstOrNull;
    if (wanted != null && _content == null) await _read(wanted);
  }

  Future<void> _reload() async {
    final p = _partition;
    if (p != null) await _read(p);
  }

  Future<void> _read(PartitionDefinition partition) async {
    setState(() {
      _partition = partition;
      _source = null;
      _content = null;
    });
    await session.runDevice('Read ${partition.name}', (device) async {
      final _Content content;
      if (_isNvs(partition)) {
        final (partition: _, image: image) = await device.readNvs(name: partition.name, onProgress: session.reportProgress);
        for (final e in image.errors) {
          session.addLog('NVS: $e', error: true);
        }
        content = _Nvs(image);
      } else {
        final (partition: _, volume: volume) = await device.readFs(name: partition.name, type: _typeOverride, onProgress: session.reportProgress);
        for (final e in volume.errors) {
          session.addLog('${volume.type.label}: $e', error: true);
        }
        session.addLog('${partition.name}: ${volume.describe()}, ${volume.entries.where((e) => !e.isDir).length} files');
        content = _Fs(volume, partition.size);
      }
      if (mounted) setState(() => _content = content);
    });
  }

  // --------------------------------------------------------------------------
  // Files
  // --------------------------------------------------------------------------

  Future<void> _openFile() async {
    final file = await pickFile();
    if (file == null || !mounted) return;
    _openBytes(file);
  }

  /// Open an NVS image, an NVS CSV (built into an image of whatever size it
  /// takes) or a filesystem image, whichever [file] turns out to be.
  void _openBytes(PickedFile file) {
    final _Content content;
    try {
      if (looksLikeNvsBinary(file.bytes)) {
        content = _Nvs(parseNvs(file.bytes));
      } else if (_nvsCsv(file.bytes) case final csv?) {
        content = _Nvs(parseNvs(_buildNvs(csv)));
      } else {
        final volume = FsVolume.mount(file.bytes, type: _typeOverride);
        content = _Fs(volume, file.bytes.length);
      }
    } catch (e) {
      session.addLog('Could not open ${file.name}: $e', error: true);
      return;
    }
    switch (content) {
      case _Nvs(:final image):
        for (final e in image.errors) {
          session.addLog('NVS: $e', error: true);
        }
        session.addLog('Opened ${file.name}: NVS, ${image.entries.length} entries, ${image.data.length.bytesString}');
      case _Fs(:final volume):
        for (final e in volume.errors) {
          session.addLog('${volume.type.label}: $e', error: true);
        }
        session.addLog('Opened ${file.name}: ${volume.type.label}, ${volume.describe()}, ${volume.entries.where((e) => !e.isDir).length} files');
    }
    setState(() {
      _content = content;
      _partition = null;
      _source = file.name;
    });
  }

  /// [bytes] as text if it is an NVS CSV (`key,type,encoding,value` header).
  static String? _nvsCsv(Uint8List bytes) {
    final String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      return null;
    }
    final first = LineSplitter.split(text).map((l) => l.trim()).where((l) => l.isNotEmpty && !l.startsWith('#')).firstOrNull ?? '';
    return first.toLowerCase().startsWith('key,type,encoding') ? text : null;
  }

  static Uint8List _buildNvs(String csv, {int? size}) {
    if (size != null) return generateNvsImage(csv, size);
    Object? lastError;
    for (final s in const [0x6000, 0x10000, 0x40000, 0x100000, 0x400000]) {
      try {
        return generateNvsImage(csv, s);
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError!;
  }

  // --------------------------------------------------------------------------
  // Writes
  // --------------------------------------------------------------------------

  /// Apply NVS edits: to the device partition, or in memory for a file.
  Future<bool> _applyNvs(List<NvsEdit> edits) async {
    final image = (_content as _Nvs).image;
    if (_fromFile) {
      try {
        final result = applyNvsEdits(image.data, resolveUntypedNvsEdits(image, edits));
        for (final c in result.changes) {
          session.addLog(describeNvsChange(c));
        }
        setState(() => _content = _Nvs(parseNvs(result.image)));
        session.addLog('Applied ${edits.length} change${edits.length == 1 ? '' : 's'} to $_source; save it with CSV or Image');
        return true;
      } catch (e) {
        session.addLog('Could not apply changes: $e', error: true);
        return false;
      }
    }
    final result = await session.runDevice(
        'Write ${edits.length} NVS change${edits.length == 1 ? '' : 's'}', (device) => device.editNvs(edits, partitionName: _partition!.name, onProgress: session.reportProgress));
    if (result != null) {
      for (final c in result.result.changes) {
        session.addLog(describeNvsChange(c));
      }
      session.addLog(result.result.compacted
          ? 'No room to append — the image was compacted and rewritten in full (${result.written.bytesString})'
          : 'Appended in place; ${result.result.dirtyPages.length} page(s) rewritten (${result.written.bytesString})');
    }
    await _reload();
    return result != null;
  }

  /// Replace the selected partition from a file: an NVS image or CSV for an
  /// NVS partition, a filesystem image for a filesystem partition.
  Future<void> _replaceFromFile() async {
    final p = _partition;
    if (p == null) return;
    final file = await pickFile();
    if (file == null || !mounted) return;
    if (_isNvs(p)) {
      final Uint8List image;
      try {
        if (looksLikeNvsBinary(file.bytes)) {
          image = file.bytes;
        } else if (_nvsCsv(file.bytes) case final csv?) {
          image = _buildNvs(csv, size: p.size);
        } else {
          throw 'not an NVS image or CSV';
        }
      } catch (e) {
        session.addLog('Cannot write ${file.name} to ${p.name}: $e', error: true);
        return;
      }
      if (!await confirm(context, title: 'Replace ${p.name}?', message: 'Replace the whole ${p.name} partition with ${file.name}.', destructive: true)) return;
      await session.runDevice('Write ${file.name} to ${p.name}', (d) => d.writeNvs(image, partitionName: p.name, onProgress: session.reportProgress));
    } else {
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
      await session.runDevice('Write ${file.name} to ${p.name}', (d) => d.writeFs(file.bytes, partitionName: p.name, onProgress: session.reportProgress));
    }
    await _reload();
  }

  /// Build a filesystem image from a ZIP of files and write it (FAT and
  /// SPIFFS; LittleFS images can't be built yet).
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
        title: 'Replace ${p.name}?', message: 'Build a ${type.label} image from the files in ${file.name} and write it over partition ${p.name}.', destructive: true)) {
      return;
    }
    await session.runDevice('Write ${type.label} from ${file.name} to ${p.name}', (d) => d.writeFs(image, partitionName: p.name, onProgress: session.reportProgress));
    await _reload();
  }

  // --------------------------------------------------------------------------
  // Build
  // --------------------------------------------------------------------------

  Widget _partitionPicker(bool busy) => AppDropdown<PartitionDefinition>(
        value: _partition,
        label: 'Partition',
        hint: _partitions.isEmpty ? 'No data partitions' : 'Select…',
        width: 360,
        entries: [for (final p in _partitions) DropdownMenuEntry(value: p, label: PartitionItem.label(p), labelWidget: PartitionItem(partition: p))],
        enabled: !busy && _partitions.isNotEmpty,
        onSelected: (p) {
          if (p != null) _read(p);
        },
      );

  Widget _openButton(bool busy) => FilledButton.tonalIcon(onPressed: busy ? null : _openFile, icon: const Icon(Icons.folder_open), label: const Text('Open file…'));

  Widget _typePicker() => AppDropdown<FsType?>(
        value: _typeOverride,
        label: 'Filesystem',
        hint: 'Auto-detect',
        width: 180,
        entries: [const DropdownMenuEntry(value: null, label: 'Auto-detect'), for (final t in FsType.values) DropdownMenuEntry(value: t, label: t.label)],
        onSelected: (t) => setState(() => _typeOverride = t),
      );

  @override
  Widget build(BuildContext context) {
    final content = _content;
    final busy = session.busy;
    final connected = session.connected;
    if (content == null) {
      if (busy) return LoadingState('Reading ${_partition?.name ?? 'data'}…');
      if (!connected) {
        return EmptyState.noDevice(
          message: 'Connect a device and select an NVS or filesystem partition, or open an NVS image, NVS CSV or filesystem image file.',
          actions: [_openButton(busy), _typePicker()],
        );
      }
      if (_partition == null) {
        return EmptyState(
          icon: Icons.storage,
          title: 'No partition selected',
          message: 'Select an NVS or filesystem partition to read it, or open an NVS image, NVS CSV or filesystem image file.',
          actions: [_partitionPicker(busy), _openButton(busy), _typePicker()],
        );
      }
      return EmptyState(
        icon: Icons.error_outline,
        error: true,
        title: 'Could not read ${_partition!.name}',
        message: 'See the log for the error.',
        actions: [
          FilledButton.tonalIcon(onPressed: _reload, icon: const Icon(Icons.refresh), label: const Text('Try again')),
          _partitionPicker(busy),
          _openButton(busy),
          _typePicker(),
        ],
      );
    }
    final p = _partition;
    final canBuild = p != null && !_isNvs(p) && (FsType.forPartition(p) ?? _typeOverride) != FsType.littlefs;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          if (connected) ...[
            _partitionPicker(busy),
            FilledButton.tonalIcon(onPressed: busy || p == null ? null : _reload, icon: const Icon(Icons.refresh), label: const Text('Re-read')),
          ],
          _openButton(busy),
          if (content is _Fs || !connected) _typePicker(),
          switch (content) {
            _Nvs(:final image) => Wrap(spacing: 8, runSpacing: 8, children: [
                OutlinedButton.icon(
                    onPressed: () => saveText('$_stem.csv', nvsToCsv(image.entries), mimeType: 'text/csv'), icon: const Icon(Icons.download), label: const Text('CSV')),
                OutlinedButton.icon(onPressed: () => saveBytes('$_stem.bin', image.data), icon: const Icon(Icons.download), label: const Text('Image')),
                OutlinedButton.icon(
                    onPressed: () => showText(context, title: 'NVS pages', text: '${formatNvsPages(image)}\n\n${formatNvsEntries(image.entries)}'),
                    icon: const Icon(Icons.article_outlined),
                    label: const Text('Pages')),
              ]),
            _Fs(:final volume) => Wrap(spacing: 8, runSpacing: 8, children: [
                OutlinedButton.icon(
                    onPressed: () => saveBytes('$_stem.zip', volume.toZip(), mimeType: 'application/zip'),
                    icon: const Icon(Icons.download),
                    label: const Text('Extract all (zip)')),
                OutlinedButton.icon(
                    onPressed: () => showText(context, title: _sourceLabel, text: '${volume.describe()}\n\n${formatFsListing(volume.entries)}'),
                    icon: const Icon(Icons.article_outlined),
                    label: const Text('Text')),
              ]),
          },
          if (connected && p != null) ...[
            const SizedBox(width: 16),
            FilledButton.icon(
                onPressed: busy ? null : _replaceFromFile, icon: const Icon(Icons.upload_file), label: Text(_isNvs(p) ? 'Replace from image or CSV…' : 'Replace from image…')),
            if (!_isNvs(p))
              FilledButton.icon(
                onPressed: busy || !canBuild ? null : _replaceFromZip,
                icon: const Icon(Icons.upload_file),
                label: Text(canBuild ? 'Replace from ZIP of files…' : 'Replace from ZIP (LittleFS build not supported)'),
              ),
          ],
        ]),
      ),
      Expanded(
        child: switch (content) {
          _Nvs(:final image) => NvsEditor(key: ObjectKey(image), image: image, sourceLabel: _sourceLabel, busy: busy, fromFile: _fromFile, onApply: _applyNvs),
          _Fs(:final volume, :final size) =>
            FsBrowser(key: ObjectKey(volume), volume: volume, sourceLabel: _sourceLabel, imageSize: size, onError: (m) => session.addLog(m, error: true)),
        },
      ),
    ]);
  }
}
