/// The command-line grammar of `set-nvs` / `get-nvs`, and the helpers a CLI
/// (or UI) needs around [applyNvsEdits]: turning `namespace:key=value` specs
/// into edits, resolving untyped ones against an image, describing what
/// changed, and grouping dirty pages into flash writes.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'common.dart';
import 'csv.dart';
import 'edit.dart';

/// A spec that could not be understood — the user-facing counterpart of
/// [NvsError], for a CLI to print as usage help.
class NvsSpecError extends NvsError {
  NvsSpecError(super.message);
}

/// How to write a spec, for error messages.
const String nvsSpecHelp = 'A spec is `namespace:key=value`, or `namespace:key:type=value` to give the type '
    'explicitly.\nWith a default namespace set, `key=value` and `:key:type=value` work too — a leading '
    'colon means\n"the default namespace". Two colon-separated parts are read as namespace and key; if '
    'the\nsecond one also names a type the spec is rejected rather than guessed at.';

String _knownTypes() => NvsType.writable.map((t) => t.label).join(', ');

/// Turn the text after the `=` into the value the entry will hold: an `int`
/// for a primitive, a `String`, or bytes decoded from hex for a blob.
///
/// A value of `@path` is read through [readFile] instead — raw bytes for a
/// blob, text for a string, and trimmed text for a number.
Object parseNvsValue(NvsType type, String text, {Uint8List? Function(String path)? readFile}) {
  if (text.startsWith('@')) {
    final path = text.substring(1);
    if (readFile == null) throw NvsSpecError("Cannot read value file '$path': no file access here");
    final raw = readFile(path);
    if (raw == null) throw NvsSpecError("Cannot read value file '$path'");
    if (type == NvsType.blob) return raw;
    if (type == NvsType.string) return utf8.decode(raw);
    text = utf8.decode(raw).trim();
  }

  if (type == NvsType.string) return text;
  if (type == NvsType.blob) {
    final cleaned = text.replaceAll(RegExp(r'\s+'), '');
    try {
      return hexDecode(cleaned);
    } on FormatException catch (e) {
      throw NvsSpecError('Blob value must be hex (or @file): ${e.message}');
    }
  }
  final value = parseNvsInt(text, type);
  if (value == null) throw NvsError("'$text' is not a valid ${type.label} value");
  return value;
}

/// Parse a `set` spec into an edit.
///
/// Without a type the value can only be decoded once the existing entry is
/// known, so the edit carries the raw text as its value and `type == null`;
/// pass it through [resolveUntypedNvsEdits] before applying.
NvsEdit parseNvsSetSpec(String spec, {String? defaultNamespace, Uint8List? Function(String path)? readFile}) {
  final eq = spec.indexOf('=');
  if (eq < 0) throw NvsSpecError("'$spec' has no '='.\n$nvsSpecHelp");
  final target = spec.substring(0, eq), text = spec.substring(eq + 1);
  final parts = target.split(':');

  final String? namespace, typeName;
  final String key;
  switch (parts.length) {
    case 1:
      (namespace, key, typeName) = (defaultNamespace, parts[0], null);
    case 2:
      if (NvsType.fromLabel(parts[1]) != null) {
        // 'a:b' is namespace:key by the grammar, but a second part that names a type is
        // almost always someone reaching for key:type. Too easy to get silently wrong —
        // both readings are valid, so make them spell out which one they meant.
        throw NvsSpecError("'$spec' is ambiguous: '${parts[1]}' is both a plausible key and a type name.\n"
            "  For namespace '${parts[0]}', key '${parts[1]}':  ${parts[0]}:${parts[1]}=$text\n"
            "  For key '${parts[0]}' of type '${parts[1]}':     "
            '${defaultNamespace ?? '<namespace>'}:${parts[0]}:${parts[1]}=$text'
            '${defaultNamespace != null ? '  (or :${parts[0]}:${parts[1]}=$text)' : ''}');
      }
      (namespace, key, typeName) = (parts[0].isNotEmpty ? parts[0] : defaultNamespace, parts[1], null);
    case 3:
      (namespace, key, typeName) = (parts[0].isNotEmpty ? parts[0] : defaultNamespace, parts[1], parts[2]);
    default:
      throw NvsSpecError("'$spec' has too many ':' separators.\n$nvsSpecHelp");
  }

  if (namespace == null || namespace.isEmpty) {
    throw NvsSpecError("'$spec' does not name a namespace — write it as namespace:$key=… or pass a default namespace");
  }
  if (key.isEmpty) throw NvsSpecError("'$spec' does not name a key.\n$nvsSpecHelp");

  NvsType? type;
  if (typeName != null) {
    type = NvsType.fromLabel(typeName);
    if (type == null) throw NvsError("Unknown type '$typeName' (expected one of ${_knownTypes()})");
  }

  final value = type != null ? parseNvsValue(type, text, readFile: readFile) : text;
  return NvsEdit(namespace, key, type: type, value: value);
}

/// Parse a `namespace:key` (or, with a default namespace, `key`) into the two
/// parts.
(String namespace, String key) parseNvsKeySpec(String spec, {String? defaultNamespace, String what = ''}) {
  final parts = spec.split(':');
  final String? namespace;
  final String key;
  switch (parts.length) {
    case 1:
      (namespace, key) = (defaultNamespace, parts[0]);
    case 2:
      (namespace, key) = (parts[0].isNotEmpty ? parts[0] : defaultNamespace, parts[1]);
    default:
      throw NvsSpecError("$what'$spec' should be namespace:key or key");
  }
  if (namespace == null || namespace.isEmpty) {
    throw NvsSpecError("$what'$spec' does not name a namespace — write it as namespace:$key or pass a default namespace");
  }
  return (namespace, key);
}

/// Parse a `--delete` spec into an edit.
NvsEdit parseNvsDeleteSpec(String spec, {String? defaultNamespace}) {
  final (namespace, key) = parseNvsKeySpec(spec, defaultNamespace: defaultNamespace, what: '--delete ');
  return NvsEdit.delete(namespace, key);
}

/// Parse a `get` spec into `(namespace, key)`.
(String namespace, String key) parseNvsGetSpec(String spec, {String? defaultNamespace}) =>
    parseNvsKeySpec(spec, defaultNamespace: defaultNamespace);

/// Fill in the type of any set edit that didn't give one, from the entry it
/// replaces, decoding its raw-text value accordingly.
List<NvsEdit> resolveUntypedNvsEdits(NvsImage image, List<NvsEdit> edits, {Uint8List? Function(String path)? readFile}) {
  final resolved = <NvsEdit>[];
  for (final edit in edits) {
    if (edit.isDelete || edit.type != null) {
      resolved.add(edit);
      continue;
    }
    final existing = image.get(edit.namespace, edit.key);
    if (existing == null) {
      throw NvsError("'${edit.qualified}' is not in the image, so its type cannot be inferred — write it as "
          '${edit.namespace}:${edit.key}:<type>=${edit.value} (types: ${_knownTypes()})');
    }
    final text = edit.value is String ? edit.value as String : formatNvsValue(edit.value!);
    resolved.add(NvsEdit.set(edit.namespace, edit.key,
        type: existing.type, value: parseNvsValue(existing.type, text, readFile: readFile)));
  }
  return resolved;
}

/// Group dirty page indices into `(address, data)` runs so a device write is
/// one erase run per contiguous stretch. [offset] is the partition's flash
/// address.
List<(int address, Uint8List data)> contiguousNvsWrites(int offset, Uint8List image, List<int> dirty) {
  final writes = <(int, int, int)>[]; // (address, first page, page count)
  for (final page in dirty) {
    if (writes.isNotEmpty && writes.last.$2 + writes.last.$3 == page) {
      final (address, first, count) = writes.removeLast();
      writes.add((address, first, count + 1));
    } else {
      writes.add((offset + page * NvsLayout.pageSize, page, 1));
    }
  }
  return [
    for (final (address, first, count) in writes)
      (address, Uint8List.sublistView(image, first * NvsLayout.pageSize, (first + count) * NvsLayout.pageSize)),
  ];
}

/// One line describing a change, as `set-nvs` prints it.
String describeNvsChange(NvsChange change) {
  final edit = change.edit;
  final type = change.type?.label;
  return switch (change.action) {
    NvsChangeAction.unchanged => '  = ${edit.qualified} unchanged',
    NvsChangeAction.deleted => '  - ${edit.qualified} ($type) deleted',
    NvsChangeAction.added => '  + ${edit.qualified} ($type) = ${shortNvsValue(edit.value!, type: change.type)}',
    NvsChangeAction.set => '  ~ ${edit.qualified} ($type): '
        '${shortNvsValue(change.before!.value, type: change.type)} -> ${shortNvsValue(edit.value!, type: change.type)}',
  };
}

/// A value abbreviated to [limit] characters for a one-line report.
String shortNvsValue(Object value, {NvsType? type, int limit = 48}) {
  final text = formatNvsValue(value, type: type);
  return text.length <= limit ? text : '${text.substring(0, limit)}…';
}
