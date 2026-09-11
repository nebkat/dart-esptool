/// Changing key/value pairs in an existing NVS image.
///
/// NVS is log-structured: flash bits only go 1→0, so an update never rewrites
/// an entry where it sits. It appends a new entry and flips the old one's
/// bitmap state from WRITTEN to ERASED, and that is exactly what
/// [applyNvsEdits] does — the same thing the firmware would do, which keeps
/// everything else in the partition byte-for-byte identical and lets a device
/// write touch only the pages that actually changed.
///
/// When there is no room left to append, the firmware garbage-collects.
/// Rather than reimplement that, [applyNvsEdits] falls back to [rewriteNvs],
/// which regenerates a compacted image from the parsed contents.
/// `forceRewrite` asks for that path up front.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:collection/collection.dart';

import 'common.dart';
import 'parser.dart';
import 'writer.dart';

/// One requested change. [value] is `null` for a delete, [type] `null` to
/// infer it from the entry being replaced (see `resolveUntyped`).
class NvsEdit {
  const NvsEdit(this.namespace, this.key, {this.type, this.value});

  const NvsEdit.set(this.namespace, this.key, {this.type, required Object this.value});

  const NvsEdit.delete(this.namespace, this.key)
      : type = null,
        value = null;

  final String namespace;
  final String key;
  final NvsType? type;
  final Object? value;

  bool get isDelete => value == null;

  String get qualified => '$namespace:$key';
}

enum NvsChangeAction { set, added, deleted, unchanged }

/// What actually happened to one edit, for reporting.
class NvsChange {
  const NvsChange(this.edit, this.action, {this.before, this.type});
  final NvsEdit edit;
  final NvsChangeAction action;
  final NvsEntry? before;
  final NvsType? type;
}

/// The outcome of [applyNvsEdits].
class NvsEditResult {
  const NvsEditResult({required this.image, required this.changes, required this.dirtyPages, required this.compacted});

  /// The new image.
  final Uint8List image;
  final List<NvsChange> changes;

  /// Indices of the pages that differ from the original.
  final List<int> dirtyPages;

  /// Whether the image had to be compacted rather than appended to.
  final bool compacted;
}

/// Pair an edit with the entry it replaces, and settle on the type to write.
(NvsEntry?, NvsType?) _resolve(NvsImage image, NvsEdit edit) {
  final existing = image.get(edit.namespace, edit.key);
  if (edit.isDelete) return (existing, existing?.type);
  if (edit.type != null) return (existing, edit.type);
  if (existing == null) {
    throw NvsError("'${edit.qualified}' is not in the image, so there is no type to infer — write it "
        'as ${edit.namespace}:${edit.key}:<type>=<value> '
        '(types: ${NvsType.writable.map((t) => t.label).join(', ')})');
  }
  return (existing, existing.type);
}

bool _same(NvsEntry entry, NvsType type, Object? value) => entry.type == type && valuesEqual(entry.value, value);

/// Whether two entry values are equal, comparing blobs by content.
bool valuesEqual(Object? a, Object? b) {
  if (a is List<int> && b is List<int>) return const ListEquality<int>().equals(a, b);
  return a == b;
}

/// Apply [edits] to an NVS image.
///
/// Appends in place when there is room, otherwise (or with [forceRewrite])
/// compacts via [rewriteNvs]. Throws [NvsError] for a damaged image or an
/// over-long key, and [NoSpaceError] if even the compacted contents don't
/// fit.
NvsEditResult applyNvsEdits(Uint8List data, List<NvsEdit> edits, {bool forceRewrite = false}) {
  final image = parseNvs(data);
  if (image.errors.isNotEmpty) {
    throw NvsError('Refusing to edit a damaged NVS image:\n  ${image.errors.join('\n  ')}');
  }

  for (final edit in edits) {
    if (utf8.encode(edit.key).length > NvsLayout.maxKeyLength) {
      throw NvsError("Key '${edit.key}' is longer than the ${NvsLayout.maxKeyLength}-character NVS limit");
    }
  }

  NvsEditResult compact() {
    // _append mutates the model it walks, so a fallback always starts from a fresh parse
    // rather than whatever state the abandoned append left behind.
    final pristine = parseNvs(data);
    return NvsEditResult(
      image: rewriteNvs(pristine, edits),
      changes: _plan(pristine, edits),
      dirtyPages: [for (var i = 0; i < data.length ~/ NvsLayout.pageSize; i++) i],
      compacted: true,
    );
  }

  if (forceRewrite) return compact();

  final Uint8List result;
  final List<NvsChange> changes;
  try {
    (result, changes) = _append(data, image, edits);
  } on NoSpaceError {
    return compact();
  }

  final dirty = <int>[];
  for (var i = 0; i < data.length ~/ NvsLayout.pageSize; i++) {
    final start = i * NvsLayout.pageSize, end = start + NvsLayout.pageSize;
    if (!const ListEquality<int>()
        .equals(Uint8List.sublistView(data, start, end), Uint8List.sublistView(result, start, end))) {
      dirty.add(i);
    }
  }
  return NvsEditResult(image: result, changes: changes, dirtyPages: dirty, compacted: false);
}

/// Work out what each edit will do, without touching the image.
List<NvsChange> _plan(NvsImage image, List<NvsEdit> edits) {
  final changes = <NvsChange>[];
  for (final edit in edits) {
    final (existing, type) = _resolve(image, edit);
    if (edit.isDelete) {
      changes.add(NvsChange(edit, existing != null ? NvsChangeAction.deleted : NvsChangeAction.unchanged,
          before: existing, type: type));
    } else if (existing == null) {
      changes.add(NvsChange(edit, NvsChangeAction.added, type: type));
    } else if (_same(existing, type!, edit.value)) {
      changes.add(NvsChange(edit, NvsChangeAction.unchanged, before: existing, type: type));
    } else {
      changes.add(NvsChange(edit, NvsChangeAction.set, before: existing, type: type));
    }
  }
  return changes;
}

(Uint8List, List<NvsChange>) _append(Uint8List data, NvsImage image, List<NvsEdit> edits) {
  final buffer = Uint8List.fromList(data);
  final writer = NvsWriter(buffer, image);
  final changes = <NvsChange>[];

  for (final edit in edits) {
    final (existing, type) = _resolve(image, edit);

    if (edit.isDelete) {
      if (existing == null) {
        changes.add(NvsChange(edit, NvsChangeAction.unchanged, type: type));
        continue;
      }
      writer.erase(existing);
      changes.add(NvsChange(edit, NvsChangeAction.deleted, before: existing, type: type));
      image.entries.remove(existing);
      continue;
    }

    if (existing != null && _same(existing, type!, edit.value)) {
      // Writing an identical value would burn entries for nothing.
      changes.add(NvsChange(edit, NvsChangeAction.unchanged, before: existing, type: type));
      continue;
    }

    var nsIndex = image.namespaceIndex(edit.namespace);
    if (nsIndex == null) {
      nsIndex = (image.namespaces.keys.maxOrNull ?? 0) + 1;
      if (nsIndex > 0xFE) throw NoSpaceError('no namespace indices left');
      writer.writeNamespace(edit.namespace, nsIndex);
      image.namespaces[nsIndex] = edit.namespace;
    }

    // Write the replacement before erasing what it replaces: if there turns out to be no
    // room, the original image is still intact and we fall back to compacting.
    final raw = writer.writeItem(nsIndex, edit.key, type!, edit.value!, previous: existing);
    if (existing != null) {
      writer.erase(existing);
      image.entries.remove(existing);
    }
    changes.add(NvsChange(edit, existing != null ? NvsChangeAction.set : NvsChangeAction.added,
        before: existing, type: type));
    // Keep the model current so a later edit in this batch that touches the same key
    // replaces (and erases) what was just written.
    image.entries.add(NvsEntry(
        namespace: edit.namespace, key: edit.key, type: type, value: edit.value!, size: 0, nsIndex: nsIndex, raw: raw));
  }

  return (buffer, changes);
}

/// Regenerate a compacted image from an image's contents plus [edits].
///
/// Used when there is no room to append. Builds a fresh image the way
/// `nvs_partition_gen` would: namespaces in their original index order (so
/// the rebuilt image reads like the old one), each followed by its keys in
/// the order they were found, with new keys appended. Throws [NoSpaceError]
/// if the contents don't fit.
Uint8List rewriteNvs(NvsImage image, List<NvsEdit> edits) {
  final entries = {for (final e in image.entries) (e.namespace, e.key): e};
  final order = [for (final e in image.entries) (e.namespace, e.key)];

  for (final edit in edits) {
    final (_, type) = _resolve(image, edit);
    final key = (edit.namespace, edit.key);
    if (edit.isDelete) {
      entries.remove(key);
      order.remove(key);
      continue;
    }
    if (!entries.containsKey(key)) order.add(key);
    entries[key] = NvsEntry(
        namespace: edit.namespace,
        key: edit.key,
        type: type!,
        value: edit.value!,
        size: 0,
        nsIndex: image.namespaceIndex(edit.namespace) ?? 0);
  }

  final namespaces = <String>[];
  for (final index in image.namespaces.keys.sorted((a, b) => a.compareTo(b))) {
    namespaces.add(image.namespaces[index]!);
  }
  for (final (namespace, _) in order) {
    if (!namespaces.contains(namespace)) namespaces.add(namespace);
  }

  final writer = NvsWriter.blank(image.size, version: image.version)..ensureActivePage();
  var nsIndex = 0;
  for (final namespace in namespaces) {
    final keys = [for (final (ns, key) in order) if (ns == namespace) key];
    if (keys.isEmpty) continue;
    writer.writeNamespace(namespace, ++nsIndex);
    for (final key in keys) {
      final entry = entries[(namespace, key)]!;
      writer.writeItem(nsIndex, key, entry.type, entry.value);
    }
  }
  return writer.data;
}
