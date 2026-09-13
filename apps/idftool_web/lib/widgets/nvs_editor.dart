import 'package:flutter/material.dart';
import 'package:idftool/idftool.dart';

import 'dropdown.dart';
import 'type_chip.dart';

/// An NVS image as an editable table: entries grouped by namespace, with
/// pending adds, changes and deletes queued until [onApply] takes them.
/// Give it a new [key] when the image changes so the queue resets.
class NvsEditor extends StatefulWidget {
  const NvsEditor(
      {super.key, required this.image, required this.sourceLabel, required this.busy, required this.fromFile, this.encrypted = false, required this.onApply});
  final NvsImage image;
  final String sourceLabel;
  final bool busy;

  /// Whether the image is encrypted on flash (or in its file) and was
  /// decrypted with the session's key; edits are encrypted again.
  final bool encrypted;

  /// Whether the image is an opened file (edits apply in memory) rather
  /// than a device partition (edits are written).
  final bool fromFile;

  /// Apply the queued edits; return whether they were taken.
  final Future<bool> Function(List<NvsEdit> edits) onApply;

  @override
  State<NvsEditor> createState() => _NvsEditorState();
}

class _NvsEditorState extends State<NvsEditor> {
  final _edits = <NvsEdit>[];

  Future<void> _editEntry({NvsEntry? existing, String? namespace}) async {
    final result = await showDialog<NvsEdit>(
      context: context,
      builder: (context) => _EntryDialog(existing: existing, namespace: namespace, namespaces: widget.image.namespaces.values.toSet()),
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

  Future<void> _apply() async {
    if (await widget.onApply(List.of(_edits)) && mounted) setState(_edits.clear);
  }

  @override
  Widget build(BuildContext context) {
    final image = widget.image;
    final busy = widget.busy;
    final pending = {for (final e in _edits) e.qualified: e};
    return ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [
      Row(children: [
        if (widget.encrypted)
          const Padding(
            padding: EdgeInsets.only(right: 8),
            child: Tooltip(message: 'Encrypted NVS, decrypted with the HMAC key; changes are encrypted again', child: Icon(Icons.lock_outline, size: 20)),
          ),
        Expanded(
          child: Text('${widget.sourceLabel}: ${image.entries.length} entries in ${image.namespaces.length} namespace${image.namespaces.length == 1 ? '' : 's'}, '
              'NVS v${image.version == NvsVersion.v1 ? 1 : 2}, ${image.pages.where((p) => !p.isUninit).length}/${image.pages.length} pages used'),
        ),
        FilledButton.tonalIcon(onPressed: busy ? null : () => _editEntry(), icon: const Icon(Icons.add), label: const Text('Add entry')),
        const SizedBox(width: 8),
        FilledButton.icon(
          onPressed: busy || _edits.isEmpty ? null : _apply,
          icon: const Icon(Icons.save),
          label: Text(_edits.isEmpty ? 'No changes' : '${widget.fromFile ? 'Apply' : 'Write'} ${_edits.length} change${_edits.length == 1 ? '' : 's'}'),
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
                    _row(entry: entry, pending: pending['${entry.namespace}:${entry.key}'], busy: busy, valueWidth: _valueWidth(constraints.maxWidth)),
                  for (final edit in _edits.where((e) => !e.isDelete && image.get(e.namespace, e.key) == null))
                    _row(pending: edit, busy: busy, valueWidth: _valueWidth(constraints.maxWidth)),
                ],
              ),
            ),
          ),
        ),
      ),
    ]);
  }

  /// The value column gets whatever the fixed columns (namespace, key, type,
  /// actions, spacing and card padding) leave over.
  static double _valueWidth(double tableWidth) => (tableWidth - 640).clamp(240, double.infinity);

  /// Entries in namespace order of first appearance, keys sorted within.
  static List<NvsEntry> _sortedEntries(NvsImage image) {
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

  DataRow _row({NvsEntry? entry, NvsEdit? pending, required bool busy, required double valueWidth}) {
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
        DataCell(type == null ? const SizedBox.shrink() : TypeChip(type.label, nvsTypeColor(type))),
        DataCell(SizedBox(width: valueWidth, child: Text(valueText, style: style, overflow: TextOverflow.ellipsis, maxLines: 1))),
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
                decoration: const InputDecoration(labelText: 'Namespace'),
                style: const TextStyle(fontFamily: 'RobotoMono'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _key,
                enabled: !editing,
                decoration: const InputDecoration(labelText: 'Key'),
                style: const TextStyle(fontFamily: 'RobotoMono'),
              ),
            ),
            const SizedBox(width: 8),
            AppDropdown<NvsType>(
              value: _type,
              label: 'Type',
              entries: [for (final t in NvsType.writable) DropdownMenuEntry(value: t, label: t.label)],
              onSelected: (t) => setState(() => _type = t ?? _type),
            ),
          ]),
          const SizedBox(height: 12),
          TextField(
            controller: _value,
            maxLines: _type == NvsType.string || _type == NvsType.blob ? 6 : 1,
            decoration: InputDecoration(labelText: _type == NvsType.blob ? 'Value (hex bytes)' : 'Value', errorText: _error),
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
Color nvsTypeColor(NvsType type) => switch (type) {
      NvsType.string => HSLColor.fromAHSL(1, 140, 0.55, 0.42).toColor(),
      NvsType.blob => HSLColor.fromAHSL(1, 280, 0.5, 0.5).toColor(),
      _ => HSLColor.fromAHSL(1, 205 + (type.signed ? 12 : 0), 0.6, 0.62 - 0.07 * (type.width! ~/ 2)).toColor(),
    };
