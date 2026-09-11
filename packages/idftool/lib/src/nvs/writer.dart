/// Encoding entries and appending them into an image, the way the firmware
/// (and `nvs_partition_gen`) would.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'common.dart';

/// Blob chunk indices start at one of two offsets, so a half-written
/// replacement can never be confused with the copy it replaces. ESP-IDF calls
/// these `VER_0_OFFSET` and `VER_1_OFFSET`.
const int ver0Offset = 0x00;
const int ver1Offset = 0x80;

// --------------------------------------------------------------------------
// Encoding entries
// --------------------------------------------------------------------------

Uint8List _entryHeader(int nsIndex, int typeCode, int span, int chunkIndex, String key) {
  final entry = Uint8List(NvsLayout.entrySize)..fillRange(0, NvsLayout.entrySize, 0xFF);
  entry[0] = nsIndex;
  entry[1] = typeCode;
  entry[2] = span;
  entry[3] = chunkIndex;
  entry.fillRange(8, 24, 0);
  final keyBytes = utf8.encode(key);
  entry.setRange(8, 8 + keyBytes.length, keyBytes);
  return entry;
}

Uint8List _seal(Uint8List entry) {
  ByteData.sublistView(entry).setUint32(4, entryCrc(entry), Endian.little);
  return entry;
}

/// Pad a payload out to a whole number of entries with erased flash.
Uint8List _pad(List<int> payload) {
  final out = Uint8List(NvsLayout.entriesFor(payload.length) * NvsLayout.entrySize)..fillRange(0, payload.length, 0);
  out.setRange(0, payload.length, payload);
  out.fillRange(payload.length, out.length, 0xFF);
  return out;
}

/// A single-entry primitive item.
Uint8List encodePrimitive(int nsIndex, String key, NvsType type, int value) {
  final entry = _entryHeader(nsIndex, type.code, 1, NvsLayout.chunkAny, key);
  entry.setRange(24, 32, packPrimitive(type, value));
  return _seal(entry);
}

/// A string, a v1 blob, or a v2 blob chunk: a header entry followed by its
/// payload.
Uint8List encodeVarlen(int nsIndex, String key, NvsType type, List<int> payload,
    {int chunkIndex = NvsLayout.chunkAny}) {
  final span = 1 + NvsLayout.entriesFor(payload.length);
  final entry = _entryHeader(nsIndex, type.code, span, chunkIndex, key);
  ByteData.sublistView(entry)
    ..setUint16(24, payload.length, Endian.little)
    ..setUint32(28, dataCrc(payload), Endian.little);
  return Uint8List.fromList([..._seal(entry), ..._pad(payload)]);
}

/// The index entry that ties a v2 blob's chunks together.
Uint8List encodeBlobIndex(int nsIndex, String key, int total, int chunkCount, int chunkStart) {
  final entry = _entryHeader(nsIndex, NvsType.blobIndex.code, 1, NvsLayout.chunkAny, key);
  ByteData.sublistView(entry).setUint32(24, total, Endian.little);
  entry[28] = chunkCount;
  entry[29] = chunkStart;
  return _seal(entry);
}

// --------------------------------------------------------------------------
// Appending into an image's free space
// --------------------------------------------------------------------------

/// Appends entries into the pages of a mutable image, the way the firmware
/// would.
///
/// Fills the active page, then marks it FULL and initialises the next erased
/// page. The very last page is left alone: NVS needs one free page in hand to
/// garbage-collect at runtime, and `nvs_partition_gen` reserves it for the
/// same reason.
///
/// With [generatorLayout] the writer reproduces two `nvs_partition_gen`
/// quirks so that a generated image is byte-identical to the python tool's:
/// a string (or v1 blob) is never allowed to fill a page exactly, and a v2
/// blob starts its next chunk on the current page even when only the header
/// fits there (leaving an empty chunk). Either way the result parses the same.
class NvsWriter {
  /// Wrap [data], a mutable copy of [image]'s bytes, to append to it.
  NvsWriter(this.data, NvsImage image, {this.generatorLayout = false})
      : version = image.version,
        pageCount = data.length ~/ NvsLayout.pageSize,
        _states = [for (final page in image.pages) page.state],
        _used = [for (final page in image.pages) page.isUninit ? 0 : page.usedEntries],
        _nextSeq = _nextSequence(image.pages) {
    if (data.length != image.size) throw ArgumentError('data does not match the image size');
  }

  /// A writer over a fresh, fully erased image of [size] bytes.
  NvsWriter.blank(int size, {this.version = NvsVersion.v2, this.generatorLayout = true})
      : data = Uint8List(size)..fillRange(0, size, 0xFF),
        pageCount = size ~/ NvsLayout.pageSize,
        _states = List.filled(size ~/ NvsLayout.pageSize, NvsPageState.uninitialised.value),
        _used = List.filled(size ~/ NvsLayout.pageSize, 0),
        _nextSeq = 0 {
    if (size < NvsLayout.pageSize) {
      throw NvsError('An NVS partition must be at least 0x${NvsLayout.pageSize.toRadixString(16)} bytes, '
          'not 0x${size.toRadixString(16)}');
    }
    if (size % NvsLayout.pageSize != 0) {
      throw NvsError('NVS partition size 0x${size.toRadixString(16)} is not a multiple of '
          '0x${NvsLayout.pageSize.toRadixString(16)}');
    }
  }

  final Uint8List data;
  final NvsVersion version;
  final bool generatorLayout;
  final int pageCount;
  final List<int> _states;
  final List<int> _used;
  int _nextSeq;

  /// Usable pages, keeping one in reserve for the firmware's garbage collector
  /// — except on a partition under 0x3000, which has none to spare and is
  /// read-only to the firmware anyway. Same rule `nvs_partition_gen` applies
  /// (see [generatorSize]).
  int get usable => pageCount >= 3 ? pageCount - 1 : pageCount;

  static int _nextSequence(List<NvsPage> pages) {
    var next = 0;
    for (final page in pages) {
      if (!page.isUninit && page.seq + 1 > next) next = page.seq + 1;
    }
    return next;
  }

  // -- page helpers ---------------------------------------------------------

  void _setPageState(int index, int state) {
    ByteData.sublistView(data).setUint32(index * NvsLayout.pageSize, state, Endian.little);
    _states[index] = state;
  }

  /// Turn an erased page into an ACTIVE one with a fresh sequence number.
  void _initPage(int index) {
    final header = Uint8List(NvsLayout.headerSize)..fillRange(0, NvsLayout.headerSize, 0xFF);
    ByteData.sublistView(header)
      ..setUint32(0, NvsPageState.active.value, Endian.little)
      ..setUint32(4, _nextSeq, Endian.little);
    header[8] = version.byte;
    ByteData.sublistView(header).setUint32(28, headerCrc(header), Endian.little);
    data.setRange(index * NvsLayout.pageSize, index * NvsLayout.pageSize + NvsLayout.headerSize, header);
    _states[index] = NvsPageState.active.value;
    _used[index] = 0;
    _nextSeq++;
  }

  int _room(int index) => NvsLayout.maxEntries - _used[index];

  /// Open the first page if nothing is active yet. `nvs_partition_gen` does
  /// this on open, so even an empty CSV yields one ACTIVE page.
  void ensureActivePage() {
    if (_states.any((s) => s == NvsPageState.active.value)) return;
    pageWithRoom(1);
  }

  /// Find (or open) a page with [entries] free entries, marking full pages
  /// FULL. Throws [NoSpaceError] when nothing is left.
  int pageWithRoom(int entries) {
    if (entries > NvsLayout.maxEntries) {
      throw NoSpaceError('an item of $entries entries cannot fit in a '
          '0x${NvsLayout.pageSize.toRadixString(16)}-byte page');
    }
    for (var index = 0; index < usable; index++) {
      if (_states[index] == NvsPageState.active.value && _room(index) >= entries) return index;
    }
    // Nothing active has room. Retire the active pages and open the next erased one.
    for (var index = 0; index < usable; index++) {
      if (_states[index] == NvsPageState.active.value) _setPageState(index, NvsPageState.full.value);
    }
    for (var index = 0; index < usable; index++) {
      if (_states[index] == NvsPageState.uninitialised.value) {
        _initPage(index);
        return index;
      }
    }
    throw NoSpaceError('no free pages left to append to');
  }

  /// A page for a single-page item of [total] entries. The generator refuses
  /// to fill a page exactly with one (`entry_num + total >= max_entries`), so
  /// under [generatorLayout] one spare entry is demanded — unless the item
  /// needs the whole page, which the generator can't write at all and which
  /// there is no reason to refuse.
  int _pageForSinglePageItem(int total) =>
      pageWithRoom(generatorLayout && total < NvsLayout.maxEntries ? total + 1 : total);

  // -- writing --------------------------------------------------------------

  /// Write [encoded] (whole entries) at the end of page [index], marking them
  /// WRITTEN. Returns the headers as they would parse, for [erase].
  List<RawEntry> append(int index, Uint8List encoded) {
    final count = encoded.length ~/ NvsLayout.entrySize;
    final first = _used[index];
    final base = index * NvsLayout.pageSize;
    final start = base + NvsLayout.firstEntryOffset + first * NvsLayout.entrySize;
    data.setRange(start, start + encoded.length, encoded);

    final bitmap = Uint8List.sublistView(data, base + NvsLayout.bitmapOffset, base + NvsLayout.bitmapOffset + NvsLayout.bitmapSize);
    for (var n = 0; n < count; n++) {
      setEntryState(bitmap, first + n, NvsEntryState.written);
    }
    _used[index] = first + count;

    final header = Uint8List.sublistView(encoded, 0, NvsLayout.entrySize);
    return [
      RawEntry(
        page: index,
        index: first,
        state: NvsEntryState.written,
        nsIndex: header[0],
        typeCode: header[1],
        span: header[2],
        chunkIndex: header[3],
        key: decodeKey(Uint8List.sublistView(header, 8, 24)),
        data: Uint8List.fromList(header.sublist(24, 32)),
        crcOk: true,
      ),
    ];
  }

  /// Mark every entry backing [entry] — headers, payload, blob chunks — as
  /// erased.
  void erase(NvsEntry entry) {
    for (final raw in entry.raw) {
      final base = raw.page * NvsLayout.pageSize;
      final bitmap = Uint8List.sublistView(data, base + NvsLayout.bitmapOffset, base + NvsLayout.bitmapOffset + NvsLayout.bitmapSize);
      for (var n = 0; n < raw.span; n++) {
        setEntryState(bitmap, raw.index + n, NvsEntryState.erased);
      }
    }
  }

  // -- items ----------------------------------------------------------------

  List<RawEntry> writeNamespace(String name, int index) =>
      append(pageWithRoom(1), encodePrimitive(0, name, NvsType.u8, index));

  /// Write one item. [previous] is the entry it replaces, if any, which
  /// decides where a v2 blob's chunk numbering starts. Returns the headers
  /// written, so a later edit in the same batch can [erase] them.
  List<RawEntry> writeItem(int nsIndex, String key, NvsType type, Object value, {NvsEntry? previous}) {
    if (type.isPrimitive) {
      if (value is! int) throw NvsError("Value for ${type.label} '$key' must be an int, not ${value.runtimeType}");
      return append(pageWithRoom(1), encodePrimitive(nsIndex, key, type, value));
    }
    if (type == NvsType.string) {
      if (value is! String) throw NvsError("Value for string '$key' must be a String, not ${value.runtimeType}");
      // NVS stores strings NUL-terminated, and never splits one across pages.
      final payload = [...utf8.encode(value), 0];
      final limit = version.maxStringSize;
      if (payload.length > limit) {
        throw NvsError("string '$key' is ${payload.length} bytes, over the $limit-byte NVS limit");
      }
      final page = _pageForSinglePageItem(1 + NvsLayout.entriesFor(payload.length));
      return append(page, encodeVarlen(nsIndex, key, NvsType.string, payload));
    }
    if (type == NvsType.blob) {
      if (value is! List<int>) throw NvsError("Value for blob '$key' must be bytes, not ${value.runtimeType}");
      return _writeBlob(nsIndex, key, value, previous);
    }
    throw NvsError("Cannot write type '${type.label}'");
  }

  List<RawEntry> _writeBlob(int nsIndex, String key, List<int> payload, NvsEntry? previous) {
    if (version == NvsVersion.v1) {
      final limit = version.maxStringSize;
      if (payload.length > limit) {
        throw NvsError("blob '$key' is ${payload.length} bytes, over the $limit-byte limit for a "
            'version 1 NVS partition');
      }
      final page = _pageForSinglePageItem(1 + NvsLayout.entriesFor(payload.length));
      return append(page, encodeVarlen(nsIndex, key, NvsType.blob, payload));
    }

    // Version 2 splits a blob into chunks that may live on different pages, indexed by a
    // final blobIndex entry. Start the chunk numbering at whichever offset the copy being
    // replaced did not use, so the two generations can never be mistaken for each other.
    var chunkStart = ver0Offset;
    if (previous != null &&
        previous.raw.any((raw) => raw.type == NvsType.blobData && raw.chunkIndex & ver1Offset == ver0Offset)) {
      chunkStart = ver1Offset;
    }

    final written = <RawEntry>[];
    var offset = 0;
    var chunks = 0;
    while (offset < payload.length || chunks == 0) {
      // A chunk needs its header plus, unless mimicking the generator, at least one data
      // entry to be worth placing.
      final page = pageWithRoom(generatorLayout ? 1 : 2);
      final capacity = (_room(page) - 1) * NvsLayout.entrySize;
      final end = offset + capacity < payload.length ? offset + capacity : payload.length;
      final chunk = payload.sublist(offset, end);
      written.addAll(append(page, encodeVarlen(nsIndex, key, NvsType.blobData, chunk, chunkIndex: chunkStart + chunks)));
      offset = end;
      chunks++;
      if (chunks > 0xFF - ver1Offset) throw NoSpaceError("blob '$key' needs more chunks than NVS can index");
    }

    written.addAll(append(pageWithRoom(1), encodeBlobIndex(nsIndex, key, payload.length, chunks, chunkStart)));
    return written;
  }
}

/// The size `nvs_partition_gen` would be handed so it emits a partition of
/// exactly [size] bytes.
///
/// The generator treats its size argument as the *writable* space and adds a
/// page on top, reserved for the firmware's garbage collector — except on a
/// partition too small to spare one, which it builds read-only instead.
/// Mirrors `nvs_partition_gen.check_size`.
int generatorSize(int size) {
  if (size < NvsLayout.pageSize) {
    throw NvsError('An NVS partition must be at least 0x${NvsLayout.pageSize.toRadixString(16)} bytes, '
        'not 0x${size.toRadixString(16)}');
  }
  return size - NvsLayout.pageSize < 2 * NvsLayout.pageSize ? size : size - NvsLayout.pageSize;
}
