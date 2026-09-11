import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:idftool/idftool.dart';

import '../session/device_session.dart';
import '../util/files.dart';
import '../widgets/dialogs.dart';
import '../widgets/type_chip.dart';

/// Browse and edit an NVS partition: entries grouped by namespace, pending
/// edits applied in one write of only the pages that changed.
class NvsPage extends StatefulWidget {
  const NvsPage({super.key, required this.session});
  final DeviceSession session;

  @override
  State<NvsPage> createState() => _NvsPageState();
}

class _NvsPageState extends State<NvsPage> {
  List<PartitionDefinition> _nvsPartitions = const [];
  PartitionDefinition? _partition;
  NvsImage? _image;
  final _edits = <NvsEdit>[];
  bool _loadedFor = false;

  DeviceSession get session => widget.session;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (session.connected && !_loadedFor && !session.busy) {
      _loadedFor = true;
      _load();
    }
    if (!session.connected) {
      _loadedFor = false;
      _image = null;
      _partition = null;
      _edits.clear();
    }
  }

  Future<void> _load() async {
    await session.runDevice('Read NVS', (device) async {
      final table = await device.partitionTable();
      final partitions = table.findByType(PartitionType.data, DataSubtype.nvs).toList();
      final partition = _partition != null && partitions.contains(_partition) ? _partition : partitions.firstOrNull;
      if (partition == null) throw IdfToolException('No NVS partition in the partition table');
      final (partition: _, image: image) = await device.readNvs(name: partition.name, onProgress: session.reportProgress);
      for (final e in image.errors) {
        session.addLog('NVS: $e', error: true);
      }
      if (mounted) {
        setState(() {
          _nvsPartitions = partitions;
          _partition = partition;
          _image = image;
          _edits.clear();
        });
      }
    });
  }

  Future<void> _applyEdits() async {
    final edits = List.of(_edits);
    final result = await session.runDevice('Write ${edits.length} NVS change${edits.length == 1 ? '' : 's'}',
        (device) => device.editNvs(edits, partitionName: _partition!.name, onProgress: session.reportProgress));
    if (result != null) {
      for (final c in result.result.changes) {
        session.addLog(describeNvsChange(c));
      }
      session.addLog(result.result.compacted
          ? 'No room to append — the image was compacted and rewritten in full (${result.written.bytesString})'
          : 'Appended in place; ${result.result.dirtyPages.length} page(s) rewritten (${result.written.bytesString})');
    }
    await _load();
  }

  Future<void> _writeCsv() async {
    final file = await pickFile(extensions: ['csv']);
    if (file == null || !mounted || _partition == null) return;
    final Uint8List image;
    try {
      image = generateNvsImage(String.fromCharCodes(file.bytes), _partition!.size);
    } catch (e) {
      session.addLog('Could not generate NVS image from ${file.name}: $e', error: true);
      return;
    }
    if (!await confirm(context,
        title: 'Replace NVS?', message: 'Replace the whole ${_partition!.name} partition with an image generated from ${file.name}.', destructive: true)) {
      return;
    }
    await session.runDevice('Write NVS from ${file.name}',
        (device) => device.writeNvs(image, partitionName: _partition!.name, onProgress: session.reportProgress));
    await _load();
  }

  Future<void> _writeImage() async {
    final file = await pickFile(extensions: ['bin']);
    if (file == null || !mounted || _partition == null) return;
    if (!looksLikeNvsBinary(file.bytes)) {
      session.addLog('${file.name} does not look like an NVS image', error: true);
      return;
    }
    if (!await confirm(context, title: 'Replace NVS?', message: 'Replace the whole ${_partition!.name} partition with ${file.name}.', destructive: true)) return;
    await session.runDevice('Write NVS image ${file.name}',
        (device) => device.writeNvs(file.bytes, partitionName: _partition!.name, onProgress: session.reportProgress));
    await _load();
  }

  Future<void> _editEntry({NvsEntry? existing, String? namespace}) async {
    final result = await showDialog<NvsEdit>(
      context: context,
      builder: (context) => _EntryDialog(existing: existing, namespace: namespace, namespaces: _image?.namespaces.values.toSet() ?? {}),
    );
    if (result != null) {
      setState(() {
        _edits.removeWhere((e) => e.qualified == result.qualified);
        _edits.add(result);
      });
    }
  }

  void _delete(NvsEntry entry) {
    setState(() {
      _edits.removeWhere((e) => e.qualified == '${entry.namespace}:${entry.key}');
      _edits.add(NvsEdit.delete(entry.namespace, entry.key));
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!session.connected) return const Center(child: Text('Connect to a device first.'));
    final image = _image;
    final busy = session.busy;
    final pending = {for (final e in _edits) e.qualified: e};
    final theme = Theme.of(context);
    return ListView(padding: const EdgeInsets.all(16), children: [
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        if (_nvsPartitions.length > 1)
          DropdownButton<PartitionDefinition>(
            value: _partition,
            items: [for (final p in _nvsPartitions) DropdownMenuItem(value: p, child: Text('${p.name} (${p.size.bytesString})'))],
            onChanged: busy
                ? null
                : (p) {
                    _partition = p;
                    _load();
                  },
          )
        else if (_partition != null)
          Text('${_partition!.name} (${_partition!.size.bytesString} at ${_partition!.offset.hex})', style: theme.textTheme.titleMedium),
        FilledButton.tonalIcon(onPressed: busy ? null : _load, icon: const Icon(Icons.refresh), label: const Text('Re-read')),
        OutlinedButton.icon(
          onPressed: image == null ? null : () => saveText('nvs.csv', nvsToCsv(image.entries), mimeType: 'text/csv'),
          icon: const Icon(Icons.download),
          label: const Text('CSV'),
        ),
        OutlinedButton.icon(
          onPressed: image == null ? null : () => saveBytes('nvs.bin', image.data),
          icon: const Icon(Icons.download),
          label: const Text('Image'),
        ),
        OutlinedButton.icon(
          onPressed: image == null ? null : () => showText(context, title: 'NVS pages', text: '${formatNvsPages(image)}\n\n${formatNvsEntries(image.entries)}'),
          icon: const Icon(Icons.article_outlined),
          label: const Text('Pages'),
        ),
        const SizedBox(width: 16),
        OutlinedButton.icon(onPressed: busy || image == null ? null : _writeCsv, icon: const Icon(Icons.upload_file), label: const Text('Replace from CSV…')),
        OutlinedButton.icon(onPressed: busy || image == null ? null : _writeImage, icon: const Icon(Icons.upload_file), label: const Text('Replace from image…')),
      ]),
      const SizedBox(height: 12),
      if (image == null)
        const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))
      else ...[
        Row(children: [
          Text('${image.entries.length} entries in ${image.namespaces.length} namespace${image.namespaces.length == 1 ? '' : 's'}, '
              'NVS v${image.version == NvsVersion.v1 ? 1 : 2}, ${image.pages.where((p) => !p.isUninit).length}/${image.pages.length} pages used'),
          const Spacer(),
          FilledButton.tonalIcon(onPressed: busy ? null : () => _editEntry(), icon: const Icon(Icons.add), label: const Text('Add entry')),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: busy || _edits.isEmpty ? null : _applyEdits,
            icon: const Icon(Icons.save),
            label: Text(_edits.isEmpty ? 'No changes' : 'Write ${_edits.length} change${_edits.length == 1 ? '' : 's'}'),
          ),
          if (_edits.isNotEmpty) TextButton(onPressed: () => setState(_edits.clear), child: const Text('Discard')),
        ]),
        const SizedBox(height: 8),
        // One table for every namespace so columns line up; it fills the
        // width and the value column takes whatever is left.
        LayoutBuilder(
          builder: (context, constraints) => Card(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: constraints.maxWidth),
                child: DataTable(
                  columnSpacing: 20,
                  dataTextStyle: const TextStyle(fontFamily: 'RobotoMono', fontSize: 13),
                  headingTextStyle: const TextStyle(fontFamily: 'RobotoMono', fontWeight: FontWeight.bold, fontSize: 13),
                  columns: const [
                    DataColumn(label: Text('Namespace')),
                    DataColumn(label: Text('Key')),
                    DataColumn(label: Text('Type')),
                    DataColumn(label: Expanded(child: Text('Value'))),
                    DataColumn(label: Text('')),
                  ],
                  rows: [
                    for (final entry in _sortedEntries(image))
                      _row(entry: entry, pending: pending['${entry.namespace}:${entry.key}'], busy: busy),
                    for (final edit in _edits.where((e) => !e.isDelete && image.get(e.namespace, e.key) == null))
                      _row(pending: edit, busy: busy),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    ]);
  }

  /// Entries in namespace order of first appearance, keys sorted within.
  List<NvsEntry> _sortedEntries(NvsImage image) {
    final order = <String>[];
    for (final e in image.entries) {
      if (!order.contains(e.namespace)) order.add(e.namespace);
    }
    return List.of(image.entries)
      ..sort((a, b) {
        final ns = order.indexOf(a.namespace).compareTo(order.indexOf(b.namespace));
        return ns != 0 ? ns : a.key.compareTo(b.key);
      });
  }

  DataRow _row({NvsEntry? entry, NvsEdit? pending, required bool busy}) {
    final theme = Theme.of(context);
    final deleted = pending?.isDelete ?? false;
    final changed = pending != null && !deleted;
    final key = entry?.key ?? pending!.key;
    final type = changed ? pending.type : entry?.type;
    final valueText = changed ? formatNvsValue(pending.value!) : entry?.valueText ?? '';
    final style = TextStyle(
      fontFamily: 'RobotoMono',
      decoration: deleted ? TextDecoration.lineThrough : null,
      color: deleted ? theme.disabledColor : (changed ? theme.colorScheme.primary : null),
      fontWeight: changed ? FontWeight.bold : null,
    );
    final namespace = entry?.namespace ?? pending!.namespace;
    return DataRow(
      color: changed || deleted ? WidgetStatePropertyAll(theme.colorScheme.primaryContainer.withValues(alpha: 0.25)) : null,
      cells: [
        DataCell(TypeChip(namespace, colorForName(namespace))),
        DataCell(Text(key, style: style)),
        DataCell(type == null ? const SizedBox.shrink() : TypeChip(type.label, _nvsTypeColor(type))),
        DataCell(Text(valueText, style: style, overflow: TextOverflow.ellipsis, maxLines: 1)),
        DataCell(Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(
            tooltip: 'Edit',
            icon: const Icon(Icons.edit, size: 20),
            onPressed: busy ? null : () => _editEntry(existing: entry, namespace: entry?.namespace ?? pending!.namespace),
          ),
          if (pending != null)
            IconButton(tooltip: 'Undo change', icon: const Icon(Icons.undo, size: 20), onPressed: () => setState(() => _edits.remove(pending)))
          else
            IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline, size: 20), onPressed: busy ? null : () => _delete(entry!)),
        ])),
      ],
    );
  }
}

/// Add or edit one entry. Returns the [NvsEdit] to queue.
class _EntryDialog extends StatefulWidget {
  const _EntryDialog({this.existing, this.namespace, required this.namespaces});
  final NvsEntry? existing;
  final String? namespace;
  final Set<String> namespaces;

  @override
  State<_EntryDialog> createState() => _EntryDialogState();
}

class _EntryDialogState extends State<_EntryDialog> {
  late final _namespace = TextEditingController(text: widget.existing?.namespace ?? widget.namespace ?? '');
  late final _key = TextEditingController(text: widget.existing?.key ?? '');
  late final _value = TextEditingController(text: widget.existing?.valueText ?? '');
  late NvsType _type = widget.existing?.type ?? NvsType.string;
  String? _error;

  @override
  void dispose() {
    _namespace.dispose();
    _key.dispose();
    _value.dispose();
    super.dispose();
  }

  void _submit() {
    final ns = _namespace.text.trim(), key = _key.text.trim();
    if (ns.isEmpty || key.isEmpty) {
      setState(() => _error = 'Namespace and key are required');
      return;
    }
    if (ns.length > NvsLayout.maxKeyLength || key.length > NvsLayout.maxKeyLength) {
      setState(() => _error = 'Namespace and key are at most ${NvsLayout.maxKeyLength} characters');
      return;
    }
    final Object value;
    try {
      value = parseNvsValue(_type, _value.text);
    } catch (e) {
      setState(() => _error = '$e');
      return;
    }
    Navigator.pop(context, NvsEdit.set(ns, key, type: _type, value: value));
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null;
    return AlertDialog(
      title: Text(editing ? 'Edit ${widget.existing!.namespace}:${widget.existing!.key}' : 'Add entry'),
      content: SizedBox(
        width: 520,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Expanded(
              child: TextField(
                controller: _namespace,
                enabled: !editing,
                decoration: const InputDecoration(labelText: 'Namespace', border: OutlineInputBorder(), isDense: true),
                style: const TextStyle(fontFamily: 'RobotoMono'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _key,
                enabled: !editing,
                decoration: const InputDecoration(labelText: 'Key', border: OutlineInputBorder(), isDense: true),
                style: const TextStyle(fontFamily: 'RobotoMono'),
              ),
            ),
            const SizedBox(width: 8),
            DropdownButton<NvsType>(
              value: _type,
              items: [for (final t in NvsType.writable) DropdownMenuItem(value: t, child: Text(t.label))],
              onChanged: (t) => setState(() => _type = t!),
            ),
          ]),
          const SizedBox(height: 12),
          TextField(
            controller: _value,
            maxLines: _type == NvsType.string || _type == NvsType.blob ? 6 : 1,
            decoration: InputDecoration(
              labelText: _type == NvsType.blob ? 'Value (hex bytes)' : 'Value',
              border: const OutlineInputBorder(),
              errorText: _error,
            ),
            style: const TextStyle(fontFamily: 'RobotoMono'),
            onSubmitted: (_) => _submit(),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: Text(editing ? 'Apply' : 'Add')),
      ],
    );
  }
}

/// Integers share a blue band (wider = deeper), strings green, blobs purple.
Color _nvsTypeColor(NvsType type) => switch (type) {
      NvsType.string => HSLColor.fromAHSL(1, 140, 0.55, 0.42).toColor(),
      NvsType.blob => HSLColor.fromAHSL(1, 280, 0.5, 0.5).toColor(),
      _ => HSLColor.fromAHSL(1, 205 + (type.signed ? 12 : 0), 0.6, 0.62 - 0.07 * (type.width! ~/ 2)).toColor(),
    };
