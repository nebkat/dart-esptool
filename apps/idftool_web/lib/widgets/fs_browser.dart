import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:idftool/idftool.dart';

import '../session/device_session.dart';
import '../util/files.dart';
import 'type_chip.dart';

/// A mounted filesystem: a collapsible tree on the left, the selected file
/// as text or hex on the right. Needs a bounded height.
class FsBrowser extends StatefulWidget {
  const FsBrowser({super.key, required this.volume, required this.sourceLabel, required this.imageSize, this.onError});
  final FsVolume volume;
  final String sourceLabel;
  final int imageSize;
  final void Function(String message)? onError;

  @override
  State<FsBrowser> createState() => _FsBrowserState();
}

class _FsBrowserState extends State<FsBrowser> {
  final _collapsed = <String>{};

  /// The file shown in the right-hand pane, its bytes, and whether it is
  /// shown as hex (`null` = decide from the content).
  FsEntry? _selected;
  Uint8List? _selectedBytes;
  bool? _hex;

  void _select(FsEntry e) {
    Uint8List? bytes;
    try {
      bytes = widget.volume.read(e.path);
    } catch (err) {
      widget.onError?.call('Could not read ${e.path}: $err');
    }
    setState(() {
      _selected = e;
      _selectedBytes = bytes;
      _hex = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final volume = widget.volume;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
          TypeChip(volume.type.label, fsColor(volume.type)),
          const SizedBox(width: 8),
          Expanded(
            child: Text('${widget.sourceLabel}: ${volume.describe()}, ${widget.imageSize.bytesString} · '
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
            child: Card(margin: const EdgeInsets.fromLTRB(16, 0, 8, 16), child: SingleChildScrollView(child: _tree(volume))),
          ),
          Expanded(child: Card(margin: const EdgeInsets.fromLTRB(8, 0, 16, 16), child: _viewer())),
        ]),
      ),
    ]);
  }

  Widget _viewer() {
    final e = _selected;
    final bytes = _selectedBytes;
    final theme = Theme.of(context);
    if (e == null || bytes == null) return const Center(child: Text('Select a file to view it.'));
    final asHex = _hex ?? !_looksLikeText(bytes);
    final text = asHex ? _hexDump(bytes) : utf8.decode(bytes, allowMalformed: true);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
        child: Row(children: [
          Expanded(
            child: Text('${e.path}  ·  ${e.size.bytesString}', style: const TextStyle(fontFamily: 'RobotoMono', fontSize: 13), overflow: TextOverflow.ellipsis),
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

  /// The listing as an indented tree; directories collapse. SPIFFS has no
  /// directories, so its '/'-containing names are grouped by prefix here.
  Widget _tree(FsVolume volume) {
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
        onTap: e.isDir ? () => setState(() => _collapsed.contains(e.path) ? _collapsed.remove(e.path) : _collapsed.add(e.path)) : () => _select(e),
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
            if (!e.isDir) Text(e.size.bytesString, style: TextStyle(fontFamily: 'RobotoMono', fontSize: 12, color: Theme.of(context).hintColor)),
          ]),
        ),
      ));
    }
    if (rows.isEmpty) return const Padding(padding: EdgeInsets.all(16), child: Text('(empty)'));
    return Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows));
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
}

Color fsColor(FsType t) => switch (t) {
      FsType.littlefs => HSLColor.fromAHSL(1, 265, 0.5, 0.5).toColor(),
      FsType.spiffs => HSLColor.fromAHSL(1, 290, 0.5, 0.5).toColor(),
      FsType.fatfs => HSLColor.fromAHSL(1, 240, 0.5, 0.5).toColor(),
    };
