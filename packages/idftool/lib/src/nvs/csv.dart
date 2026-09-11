/// The `nvs_partition_gen` CSV format: reading one to generate an image, and
/// writing one from parsed entries.
///
/// A CSV has a `key,type,encoding,value` header (columns in any order) and
/// one row per item. `type` is `namespace` (opens a namespace for the rows
/// that follow), `data` (the value is in the row) or `file` (the value names
/// a file holding it). `encoding` is one of the primitive types, `string`,
/// `hex2bin`, `base64`, `binary`, or `blob_fill(N;0xBB)` /
/// `blob_sz_fill(N;0xBB)`. Lines starting with `#` are comments.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'common.dart';
import 'writer.dart';

/// One data row of an NVS CSV.
class NvsCsvRow {
  const NvsCsvRow({required this.key, required this.type, required this.encoding, required this.value, this.line});
  final String key;
  final String type;
  final String encoding;
  final String value;

  /// 1-based line the row came from, for error messages.
  final int? line;
}

/// Parse the CSV text into rows, honouring quoting and `#` comment lines.
///
/// Throws [NvsError] if the header lacks any of the four columns.
List<NvsCsvRow> parseNvsCsv(String text) {
  // Comments are dropped per physical line before CSV parsing, as the generator does.
  final lines = const LineSplitter().convert(text);
  final kept = <(int, String)>[
    for (var i = 0; i < lines.length; i++)
      if (!lines[i].startsWith('#')) (i + 1, lines[i]),
  ];
  final records = _csvRecords(kept);
  if (records.isEmpty) throw NvsError('CSV has no header row');

  final (_, header) = records.first;
  int column(String name) {
    final index = header.indexOf(name);
    if (index < 0) throw NvsError("CSV header lacks a '$name' column: ${header.join(',')}");
    return index;
  }

  final keyCol = column('key'), typeCol = column('type'), encodingCol = column('encoding'), valueCol = column('value');
  final rows = <NvsCsvRow>[];
  for (final (line, fields) in records.skip(1)) {
    if (fields.length == 1 && fields.first.isEmpty) continue; // blank line
    if (fields.length < header.length) throw NvsError('line $line: expected ${header.length} columns, got ${fields.length}');
    rows.add(NvsCsvRow(
        key: fields[keyCol], type: fields[typeCol], encoding: fields[encodingCol], value: fields[valueCol], line: line));
  }
  return rows;
}

/// Split lines into records of fields, RFC 4180 style: a quoted field may
/// contain commas, doubled quotes, and (spanning lines) newlines.
List<(int, List<String>)> _csvRecords(List<(int, String)> lines) {
  final records = <(int, List<String>)>[];
  var fields = <String>[];
  final field = StringBuffer();
  var inQuotes = false;
  int? recordLine;

  for (final (number, line) in lines) {
    recordLine ??= number;
    if (inQuotes) field.write('\n');
    var i = 0;
    while (i < line.length) {
      final c = line[i];
      if (inQuotes) {
        if (c == '"') {
          if (i + 1 < line.length && line[i + 1] == '"') {
            field.write('"');
            i++;
          } else {
            inQuotes = false;
          }
        } else {
          field.write(c);
        }
      } else if (c == '"') {
        inQuotes = true;
      } else if (c == ',') {
        fields.add(field.toString());
        field.clear();
      } else {
        field.write(c);
      }
      i++;
    }
    if (!inQuotes) {
      fields.add(field.toString());
      field.clear();
      records.add((recordLine, fields));
      fields = [];
      recordLine = null;
    }
  }
  if (inQuotes) throw NvsError('line ${recordLine ?? '?'}: unterminated quoted field');
  return records;
}

/// Generate an NVS partition image of [size] bytes from an
/// `nvs_partition_gen` CSV.
///
/// [readFile] resolves the path in a `file` row (or a `binary`/`string`/...
/// value read from a file) to its contents; without one such rows throw
/// [NvsError], since this library has no file access of its own.
///
/// Follows the generator's size rules: one page is kept in reserve for the
/// firmware's garbage collector, unless the partition is under 0x3000 bytes
/// (read-only to the firmware). Unlike the generator, which emits only the
/// pages it wrote for a read-only size, the result is always padded to [size]
/// with erased flash — that parses the same and is what gets flashed anyway.
/// Throws [NoSpaceError] if the contents don't fit.
Uint8List generateNvsImage(
  String csv,
  int size, {
  NvsVersion version = NvsVersion.v2,
  Uint8List? Function(String path)? readFile,
}) {
  final rows = parseNvsCsv(csv);
  final writer = NvsWriter.blank(size, version: version)..ensureActivePage();
  final namespaces = <String, int>{};
  int? current;

  for (final row in rows) {
    final where = 'line ${row.line}';
    if (row.key.runes.length > NvsLayout.maxKeyLength) {
      throw NvsError("$where: length of key '${row.key}' should be <= ${NvsLayout.maxKeyLength} characters");
    }
    if (row.type == 'namespace') {
      // The generator assigns indices in first-appearance order. (It also, through a bug,
      // keeps writing to the *latest* namespace after a re-open; here a re-opened namespace
      // really does receive the rows that follow.)
      current = namespaces.putIfAbsent(row.key, () {
        final index = namespaces.length + 1;
        writer.writeNamespace(row.key, index);
        return index;
      });
      continue;
    }
    if (row.type != 'data' && row.type != 'file') {
      throw NvsError("$where: unknown row type '${row.type}' (expected namespace, data or file)");
    }
    if (current == null) throw NvsError("$where: '${row.key}' comes before any namespace row");

    var text = row.value;
    Uint8List? fileBytes;
    if (row.type == 'file') {
      if (readFile == null) throw NvsError("$where: '${row.key}' is a file row, but no file reader was given");
      fileBytes = readFile(text);
      if (fileBytes == null) throw NvsError("$where: cannot read value file '$text' for '${row.key}'");
      if (row.encoding != 'binary') text = utf8.decode(fileBytes, allowMalformed: true);
    }

    final (type, value) = _decodeCsvValue(row.key, row.encoding.toLowerCase(), text, fileBytes, where);
    writer.writeItem(current, row.key, type, value);
  }
  return writer.data;
}

final _fillPattern = RegExp(r'^(blob_fill|blob_sz_fill)\((\d+);(0x[0-9a-fA-F]{2})\)$');

(NvsType, Object) _decodeCsvValue(String key, String encoding, String text, Uint8List? fileBytes, String where) {
  final fill = _fillPattern.firstMatch(encoding);
  if (fill != null) {
    // A fixed-size blob padded with a byte; blob_sz_fill prefixes the real length.
    final length = int.parse(fill.group(2)!);
    final padding = int.parse(fill.group(3)!.substring(2), radix: 16);
    final valueBytes = utf8.encode(text);
    if (valueBytes.length > length) throw NvsError("$where: '$key': value length exceeds specified length $length");
    final out = BytesBuilder(copy: false);
    if (fill.group(1) == 'blob_sz_fill') {
      out.add(Uint8List(4)..buffer.asByteData().setUint32(0, valueBytes.length, Endian.little));
    }
    out.add(valueBytes);
    out.add(Uint8List(length - valueBytes.length)..fillRange(0, length - valueBytes.length, padding));
    return (NvsType.blob, out.toBytes());
  }

  switch (encoding) {
    case 'string':
      return (NvsType.string, text);
    case 'hex2bin':
      try {
        return (NvsType.blob, hexDecode(text.trim()));
      } on FormatException catch (e) {
        throw NvsError("$where: '$key': invalid hex2bin value (${e.message})");
      }
    case 'base64':
      try {
        return (NvsType.blob, base64.decode(text.trim()));
      } on FormatException catch (e) {
        throw NvsError("$where: '$key': invalid base64 value (${e.message})");
      }
    case 'binary':
      return (NvsType.blob, fileBytes ?? Uint8List.fromList(utf8.encode(text)));
  }

  final type = NvsType.fromLabel(encoding);
  if (type == null || !type.isPrimitive) throw NvsError("$where: '$key': unsupported encoding '$encoding'");
  final value = parseNvsInt(text.trim(), type);
  if (value == null) throw NvsError("$where: '$key': '$text' is not a valid ${type.label} value");
  return (type, value);
}

/// Parse an integer for [type], accepting a sign and `0x`/`0o`/`0b`
/// prefixes like python's `int(text, 0)`. Returns a `BigInt` for the 64-bit
/// types and an `int` otherwise, or `null` if the text is not a number or is
/// hopelessly large. Range checks are left to [packPrimitive].
Object? parseNvsInt(String text, NvsType type) {
  var body = text.trim();
  var negative = false;
  if (body.startsWith('-') || body.startsWith('+')) {
    negative = body[0] == '-';
    body = body.substring(1);
  }
  var radix = 10;
  final lower = body.toLowerCase();
  if (lower.startsWith('0x')) {
    radix = 16;
  } else if (lower.startsWith('0o')) {
    radix = 8;
  } else if (lower.startsWith('0b')) {
    radix = 2;
  }
  if (radix != 10) body = body.substring(2);
  if (body.isEmpty) return null;
  final magnitude = BigInt.tryParse(body, radix: radix);
  if (magnitude == null) return null;
  final value = negative ? -magnitude : magnitude;
  if (type.width == 8) return value;
  // A JavaScript int holds 53 bits; anything bigger is out of range for the ≤32-bit
  // types anyway, and packPrimitive reports the range on what does come through.
  if (value.bitLength > 52) return null;
  return value.toInt();
}

/// Entry type → the `encoding` column that reproduces it through
/// [generateNvsImage].
String csvEncodingFor(NvsType type) => type == NvsType.blob ? 'hex2bin' : type.label;

/// Serialise parsed entries as an `nvs_partition_gen` CSV.
///
/// The result round-trips: feeding it back to [generateNvsImage] rebuilds an
/// image with the same contents. Blobs come out as `hex2bin` because that is
/// the only binary encoding the CSV format can carry inline.
String nvsToCsv(List<NvsEntry> entries) {
  final out = StringBuffer('key,type,encoding,value\n');

  // Group by namespace, keeping the order the namespaces appear in the image so the CSV
  // reads like the original — the generator assigns namespace indices in row order.
  final namespaces = <String>[];
  for (final entry in entries) {
    if (!namespaces.contains(entry.namespace)) namespaces.add(entry.namespace);
  }

  for (final namespace in namespaces) {
    out.writeln(_csvRow([namespace, 'namespace', '', '']));
    final members = entries.where((e) => e.namespace == namespace).toList()
      ..sort((a, b) => _compareCodePoints(a.key, b.key));
    for (final entry in members) {
      out.writeln(_csvRow([entry.key, 'data', csvEncodingFor(entry.type), entry.valueText]));
    }
  }
  return out.toString();
}

int _compareCodePoints(String a, String b) {
  final ai = a.runes.iterator, bi = b.runes.iterator;
  while (true) {
    final an = ai.moveNext(), bn = bi.moveNext();
    if (!an || !bn) return an == bn ? 0 : (an ? 1 : -1);
    if (ai.current != bi.current) return ai.current.compareTo(bi.current);
  }
}

/// Python `csv.writer` minimal quoting: only fields holding a delimiter,
/// quote or line break are quoted.
String _csvRow(List<String> fields) => fields.map((f) {
      if (f.contains(',') || f.contains('"') || f.contains('\n') || f.contains('\r')) {
        return '"${f.replaceAll('"', '""')}"';
      }
      return f;
    }).join(',');
