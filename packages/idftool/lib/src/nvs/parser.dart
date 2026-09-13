/// Reading an NVS partition image back into key/value pairs.
///
/// `nvs_partition_gen` only writes — there is no way to load an existing
/// image with it — so everything that reads an NVS partition goes through
/// [parseNvs]. The layout it walks is documented in `common.dart`.
///
/// The parse is deliberately forgiving: a page or an entry that fails its CRC
/// is recorded in [NvsImage.errors] and skipped rather than aborting, because
/// an image read off a live device can legitimately contain a half-written
/// entry — the firmware ignores those too. Pass `strict: true` to turn them
/// into errors.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:collection/collection.dart';

import 'common.dart';
import 'crypto.dart' show looksEncryptedNvs;

/// Parse an NVS partition image into its pages, namespaces, and key/value
/// pairs.
///
/// Damage is collected into [NvsImage.errors] and skipped unless [strict] is
/// set, in which case it throws [NvsError].
NvsImage parseNvs(Uint8List image, {bool strict = false}) {
  if (image.isEmpty) throw NvsError('NVS image is empty');
  if (image.length % NvsLayout.pageSize != 0) {
    throw NvsError('NVS image size 0x${image.length.toRadixString(16)} is not a multiple of the '
        '0x${NvsLayout.pageSize.toRadixString(16)}-byte page size');
  }

  if (looksEncryptedNvs(image)) {
    // Every entry would fail its CRC. Say why once rather than once per entry, and keep the
    // page map, which is not encrypted.
    const message = 'No entry passes its CRC check: this looks like an encrypted NVS partition — decrypt it with its key';
    if (strict) throw NvsError(message);
    final pages = [for (var i = 0; i < image.length ~/ NvsLayout.pageSize; i++) _parsePage(image, i, <String>[], false)];
    final version = pages.firstWhereOrNull((p) => !p.isUninit && p.crcOk)?.version ?? NvsVersion.v2;
    return NvsImage(data: image, pages: pages, errors: [message], version: version, looksEncrypted: true);
  }

  final errors = <String>[];
  final pages = [for (var i = 0; i < image.length ~/ NvsLayout.pageSize; i++) _parsePage(image, i, errors, strict)];
  if (pages.every((p) => p.isUninit)) {
    // A blank partition is a valid NVS partition with nothing in it, not an error.
    return NvsImage(data: image, pages: pages, errors: errors);
  }

  final (namespaces, entries) = _reassemble(pages, errors, strict);
  final version = pages.firstWhereOrNull((p) => !p.isUninit && p.crcOk)?.version ?? NvsVersion.v2;
  return NvsImage(
      data: image, pages: pages, entries: entries, namespaces: namespaces, errors: errors, version: version);
}

void _fail(List<String> errors, bool strict, String message) {
  if (strict) throw NvsError(message);
  errors.add(message);
}

NvsPage _parsePage(Uint8List image, int index, List<String> errors, bool strict) {
  final base = index * NvsLayout.pageSize;
  final raw = Uint8List.sublistView(image, base, base + NvsLayout.pageSize);
  final header = Uint8List.sublistView(raw, 0, NvsLayout.headerSize);
  final view = ByteData.sublistView(header);

  final state = view.getUint32(0, Endian.little);
  final seq = view.getUint32(4, Endian.little);
  final version = header[8];
  final storedCrc = view.getUint32(28, Endian.little);

  if (state == NvsPageState.uninitialised.value) {
    // An erased page. Nothing else in it is meaningful, and its sequence number is
    // 0xFFFFFFFF rather than a real one, so don't let it sort with the written pages.
    return NvsPage(index: index, state: state, seq: seq, versionByte: version, crcOk: true);
  }

  final computedCrc = headerCrc(header);
  final page = NvsPage(index: index, state: state, seq: seq, versionByte: version, crcOk: storedCrc == computedCrc);
  if (!page.crcOk) {
    _fail(errors, strict,
        'page $index: header CRC mismatch (stored ${_hex32(storedCrc)}, computed ${_hex32(computedCrc)})');
    return page;
  }
  if (page.pageState == null) _fail(errors, strict, 'page $index: unknown page state ${_hex32(state)}');
  if (page.version == null) {
    _fail(errors, strict, 'page $index: unknown version byte 0x${version.toRadixString(16).padLeft(2, '0')}');
    return page;
  }

  final bitmap = Uint8List.sublistView(raw, NvsLayout.bitmapOffset, NvsLayout.bitmapOffset + NvsLayout.bitmapSize);
  for (var i = 0; i < NvsLayout.maxEntries; i++) {
    page.entryStates[i] = entryState(bitmap, i);
  }

  Uint8List entryBytes(int i) {
    final start = NvsLayout.firstEntryOffset + i * NvsLayout.entrySize;
    return Uint8List.sublistView(raw, start, start + NvsLayout.entrySize);
  }

  var i = 0;
  while (i < NvsLayout.maxEntries) {
    // Only WRITTEN entries are item headers. An erased item leaves its payload entries
    // marked erased too, so stepping one at a time never mistakes payload for a header.
    if (page.entryStates[i] != NvsEntryState.written) {
      i++;
      continue;
    }

    final data = entryBytes(i);
    final span = data[2];
    final stored = ByteData.sublistView(data).getUint32(4, Endian.little);
    final entry = RawEntry(
      page: index,
      index: i,
      state: NvsEntryState.written,
      nsIndex: data[0],
      typeCode: data[1],
      span: span,
      chunkIndex: data[3],
      key: decodeKey(Uint8List.sublistView(data, 8, 24)),
      data: Uint8List.fromList(data.sublist(24, 32)),
      crcOk: stored == entryCrc(data),
    );

    if (!entry.crcOk) {
      _fail(errors, strict, 'page $index entry $i: header CRC mismatch');
      i++;
      continue;
    }
    final type = entry.type;
    if (type == null) {
      _fail(errors, strict,
          "page $index entry $i ('${entry.key}'): unknown type 0x${entry.typeCode.toRadixString(16).padLeft(2, '0')}");
      i++;
      continue;
    }
    if (span < 1 || i + span > NvsLayout.maxEntries) {
      _fail(errors, strict, "page $index entry $i ('${entry.key}'): span $span runs past the end of the page");
      i++;
      continue;
    }

    if (type == NvsType.string || type == NvsType.blob || type == NvsType.blobData) {
      final dataView = ByteData.sublistView(entry.data);
      final length = dataView.getUint16(0, Endian.little);
      final expected = dataView.getUint32(4, Endian.little);
      final available = (span - 1) * NvsLayout.entrySize;
      if (length > available) {
        _fail(errors, strict,
            "page $index entry $i ('${entry.key}'): declared length $length exceeds its span of ${span - 1} data entries");
        i += span;
        continue;
      }
      final start = NvsLayout.firstEntryOffset + (i + 1) * NvsLayout.entrySize;
      final payload = Uint8List.fromList(raw.sublist(start, start + length));
      final payloadCrcOk = dataCrc(payload) == expected;
      if (!payloadCrcOk) _fail(errors, strict, "page $index entry $i ('${entry.key}'): data CRC mismatch");
      page.entries.add(RawEntry(
        page: entry.page,
        index: entry.index,
        state: entry.state,
        nsIndex: entry.nsIndex,
        typeCode: entry.typeCode,
        span: entry.span,
        chunkIndex: entry.chunkIndex,
        key: entry.key,
        data: entry.data,
        crcOk: entry.crcOk,
        payload: payload,
        payloadCrcOk: payloadCrcOk,
      ));
    } else {
      page.entries.add(entry);
    }
    i += span;
  }

  return page;
}

String _hex32(int value) => '0x${value.toRadixString(16).padLeft(8, '0')}';

/// Turn the raw entries of every page into namespaces and logical key/value
/// pairs.
(Map<int, String>, List<NvsEntry>) _reassemble(List<NvsPage> pages, List<String> errors, bool strict) {
  // Pages in the order the firmware wrote them, so a later duplicate of a key wins.
  // (Ties on the sequence number keep page order, like python's stable sort.)
  final ordered = pages.where((p) => !p.isUninit && p.crcOk).sortedByCompare((p) => (p.seq, p.index), _compareSeq);
  final rawEntries = [for (final page in ordered) ...page.entries];

  // Namespace table first: every other entry's nsIndex refers into it.
  final namespaces = <int, String>{};
  for (final entry in rawEntries) {
    final type = entry.type;
    if (entry.nsIndex == 0 && type != null && type.isPrimitive) {
      // Namespace entries are u8; a 64-bit one would be nonsense, so squash it to an int.
      final unpacked = unpackPrimitive(type, entry.data);
      final index = unpacked is BigInt ? (unpacked.isValidInt ? unpacked.toInt() : -1) : unpacked as int;
      final existing = namespaces[index];
      if (existing != null && existing != entry.key) {
        _fail(errors, strict, "namespace index $index is claimed by both '$existing' and '${entry.key}'");
      }
      namespaces[index] = entry.key;
    }
  }

  // Blob chunks, keyed the way a blobIndex addresses them.
  final chunks = <(int, String, int), RawEntry>{};
  for (final entry in rawEntries) {
    if (entry.type == NvsType.blobData) chunks[(entry.nsIndex, entry.key, entry.chunkIndex)] = entry;
  }

  final entries = <NvsEntry>[];
  for (final entry in rawEntries) {
    if (entry.nsIndex == 0) continue; // the namespace table itself
    final type = entry.type!;
    if (type == NvsType.blobData) continue; // accounted for by its blobIndex
    var namespace = namespaces[entry.nsIndex];
    if (namespace == null) {
      _fail(errors, strict,
          "page ${entry.page} entry ${entry.index} ('${entry.key}'): namespace index ${entry.nsIndex} is not in the namespace table");
      namespace = '<${entry.nsIndex}>';
    }

    final NvsEntry item;
    if (type == NvsType.blobIndex) {
      final joined = _joinBlob(entry, namespace, chunks, errors, strict);
      if (joined == null) continue;
      item = joined;
    } else if (type.isVariableLength) {
      final payload = entry.payload ?? Uint8List(0);
      final Object value;
      if (type == NvsType.string) {
        // NVS stores strings with their terminating NUL; the CSV value does not have one.
        var end = payload.length;
        while (end > 0 && payload[end - 1] == 0) {
          end--;
        }
        value = utf8.decode(Uint8List.sublistView(payload, 0, end), allowMalformed: true);
      } else {
        value = payload;
      }
      item = NvsEntry(
          namespace: namespace,
          key: entry.key,
          type: type,
          value: value,
          size: payload.length,
          nsIndex: entry.nsIndex,
          raw: [entry]);
    } else {
      item = NvsEntry(
          namespace: namespace,
          key: entry.key,
          type: type,
          value: unpackPrimitive(type, entry.data),
          size: type.width!,
          nsIndex: entry.nsIndex,
          raw: [entry]);
    }

    // A key written twice without the old copy being erased shouldn't happen, but if it
    // does the newest page wins — matching the firmware's own read order.
    final existing = entries.indexWhere((e) => e.nsIndex == item.nsIndex && e.key == item.key);
    if (existing >= 0) {
      entries[existing] = item;
    } else {
      entries.add(item);
    }
  }

  return (namespaces, entries);
}

int _compareSeq((int, int) a, (int, int) b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2);

/// Stitch a v2 blob back together from the chunks its index entry points at.
NvsEntry? _joinBlob(
    RawEntry indexEntry, String namespace, Map<(int, String, int), RawEntry> chunks, List<String> errors, bool strict) {
  final total = ByteData.sublistView(indexEntry.data).getUint32(0, Endian.little);
  final chunkCount = indexEntry.data[4];
  final chunkStart = indexEntry.data[5];

  final payload = BytesBuilder(copy: false);
  final raw = [indexEntry];
  for (var n = 0; n < chunkCount; n++) {
    final chunk = chunks[(indexEntry.nsIndex, indexEntry.key, chunkStart + n)];
    if (chunk == null) {
      _fail(errors, strict, "blob '$namespace:${indexEntry.key}': chunk ${chunkStart + n} of $chunkCount is missing");
      return null;
    }
    payload.add(chunk.payload ?? Uint8List(0));
    raw.add(chunk);
  }

  if (payload.length != total) {
    _fail(errors, strict, "blob '$namespace:${indexEntry.key}': chunks total ${payload.length} bytes, index says $total");
    return null;
  }

  return NvsEntry(
      namespace: namespace,
      key: indexEntry.key,
      type: NvsType.blob,
      value: payload.toBytes(),
      size: total,
      nsIndex: indexEntry.nsIndex,
      raw: raw);
}

// --------------------------------------------------------------------------
// Listings
// --------------------------------------------------------------------------

/// Render key/value pairs as a table, in the style of the partition table
/// listing.
String formatNvsEntries(List<NvsEntry> entries) {
  if (entries.isEmpty) return '(empty)';

  final sorted = entries.sortedByCompare((e) => (e.namespace, e.key), _compareStrings);
  final rows = [for (final e in sorted) [e.namespace, e.key, e.type.label, e.formatValue()]];
  final out = _table(const ['Namespace', 'Key', 'Type', 'Value'], rows);

  final count = entries.length;
  final total = entries.fold(0, (sum, e) => sum + e.size);
  final namespaces = entries.map((e) => e.namespace).toSet().length;
  out.add('$count entr${count == 1 ? 'y' : 'ies'} in $namespaces '
      'namespace${namespaces == 1 ? '' : 's'}, $total bytes of data');
  return out.join('\n');
}

int _compareStrings((String, String) a, (String, String) b) =>
    a.$1 != b.$1 ? _codePoints(a.$1, b.$1) : _codePoints(a.$2, b.$2);

/// Order strings by code point, like python does, rather than by UTF-16 unit.
int _codePoints(String a, String b) {
  final ai = a.runes.iterator, bi = b.runes.iterator;
  while (true) {
    final an = ai.moveNext(), bn = bi.moveNext();
    if (!an || !bn) return an == bn ? 0 : (an ? 1 : -1);
    if (ai.current != bi.current) return ai.current.compareTo(bi.current);
  }
}

/// Render the page map — states, sequence numbers, and how full each page is.
String formatNvsPages(NvsImage image) {
  final rows = <List<String>>[];
  for (final page in image.pages) {
    if (page.isUninit) {
      rows.add(['${page.index}', '-', 'uninitialised', '', '']);
      continue;
    }
    final written = page.entryStates.where((s) => s == NvsEntryState.written).length;
    final erased = page.entryStates.where((s) => s == NvsEntryState.erased).length;
    rows.add([
      '${page.index}',
      '${page.seq}',
      page.stateName,
      '${page.usedEntries}/${NvsLayout.maxEntries}',
      '$written written, $erased erased',
    ]);
  }
  return _table(const ['Page', 'Seq', 'State', 'Used', 'Entries'], rows).join('\n');
}

List<String> _table(List<String> headings, List<List<String>> rows) {
  final widths = [
    for (var i = 0; i < headings.length; i++) [headings[i], ...rows.map((r) => r[i])].map(_width).max,
  ];
  String line(List<String> cells) =>
      '| ${[for (var i = 0; i < cells.length; i++) cells[i] + ' ' * (widths[i] - _width(cells[i]))].join(' | ')} |';
  return [
    line(headings),
    '|${widths.map((w) => '-' * (w + 2)).join('|')}|',
    for (final row in rows) line(row),
  ];
}

/// Column width counted in code points, matching python's `len`.
int _width(String s) => s.runes.length;
