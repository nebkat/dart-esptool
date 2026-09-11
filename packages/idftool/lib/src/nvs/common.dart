/// The NVS on-flash layout, and the types shared by the NVS modules.
///
/// An NVS partition is a sequence of 4 KiB pages, each laid out as:
///
/// ```
/// +-------+------+---------------------------------------------------------+
/// | 0x00  |   32 | page header: state, sequence number, version, CRC32     |
/// | 0x20  |   32 | entry state bitmap — 2 bits per entry, 126 entries used |
/// | 0x40  | 4032 | 126 entries of 32 bytes                                 |
/// +-------+------+---------------------------------------------------------+
/// ```
///
/// and each entry as:
///
/// ```
/// +-------+------+---------------------------------------------------------+
/// |   0   |    1 | namespace index (0 addresses the namespace table)       |
/// |   1   |    1 | type (see NvsType)                                      |
/// |   2   |    1 | span — entries this item occupies, including this one   |
/// |   3   |    1 | chunk index (chunkAny unless this is blob data)         |
/// |   4   |    4 | CRC32 of bytes [0:4] + [8:32], seeded 0xFFFFFFFF        |
/// |   8   |   16 | key, NUL-padded                                         |
/// |  24   |    8 | data: the value itself, or a descriptor of what follows |
/// +-------+------+---------------------------------------------------------+
/// ```
///
/// A primitive holds its value in the data field. A string or a v1 blob puts
/// its length in `data[0:2]` and the payload CRC32 in `data[4:8]`, with the
/// payload in the `span - 1` entries that follow. A v2 blob is split:
/// `blobData` chunks each carry a slice of the payload and may be spread
/// across pages, and a single `blobIndex` entry names the total size, the
/// number of chunks, and the index the chunks start at.
///
/// NVS never rewrites an entry in place — flash bits only go 1→0. An update
/// appends a new entry and flips the old one's bitmap state from WRITTEN to
/// ERASED, which is why a parse has to walk the bitmap rather than just
/// reading entries end to end.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;
import 'package:collection/collection.dart';

/// Sizes and offsets of the on-flash layout.
abstract final class NvsLayout {
  /// NVS partitions are laid out as 4 KiB pages.
  static const int pageSize = 0x1000;
  static const int headerSize = 32;
  static const int bitmapOffset = 32;
  static const int bitmapSize = 32;
  static const int firstEntryOffset = 64;
  static const int entrySize = 32;
  static const int maxEntries = 126;

  /// Chunk index used by everything that is not a blob data chunk.
  static const int chunkAny = 0xFF;

  /// NVS truncates keys at 15 characters plus a NUL.
  static const int maxKeyLength = 15;

  /// How many 32-byte entries a payload of [size] bytes occupies.
  static int entriesFor(int size) => (size + entrySize - 1) ~/ entrySize;
}

/// The page header version byte. Version 2 added blobs split into chunks
/// that can span pages; version 1 keeps every item on a single page.
enum NvsVersion {
  v1(0xFF, 1),
  v2(0xFE, 2);

  const NvsVersion(this.byte, this.number);

  /// The value stored at offset 8 of the page header.
  final int byte;

  /// The human number (1 or 2).
  final int number;

  static NvsVersion? fromByte(int byte) => values.firstWhereOrNull((v) => v.byte == byte);

  /// The largest string (including its NUL) NVS will store — a string never
  /// spans pages.
  int get maxStringSize => this == v1 ? 1984 : 4000;
}

/// Page states. Each transition only clears bits, so an erased (all `0xFF`)
/// page is [uninitialised].
enum NvsPageState {
  uninitialised(0xFFFFFFFF),
  active(0xFFFFFFFE),
  full(0xFFFFFFFC),
  freeing(0xFFFFFFF8),
  corrupt(0xFFFFFFF0);

  const NvsPageState(this.value);
  final int value;

  static NvsPageState? fromValue(int value) => values.firstWhereOrNull((s) => s.value == value);
}

/// Entry states, two bits each, again only ever clearing bits. The enum index
/// is the bit pattern.
enum NvsEntryState {
  erased, // 0b00
  illegal, // 0b01
  written, // 0b10
  empty; // 0b11

  int get bits => index;
}

/// Item type codes, matching `nvs_partition_gen`'s `Page` class. [label] is
/// the name used on the command line and in a CSV's `encoding` column.
enum NvsType {
  u8(0x01, 'u8', width: 1),
  i8(0x11, 'i8', width: 1, signed: true),
  u16(0x02, 'u16', width: 2),
  i16(0x12, 'i16', width: 2, signed: true),
  u32(0x04, 'u32', width: 4),
  i32(0x14, 'i32', width: 4, signed: true),
  u64(0x08, 'u64', width: 8),
  i64(0x18, 'i64', width: 8, signed: true),
  string(0x21, 'string'),
  blob(0x41, 'blob'),
  blobData(0x42, 'blob_data'),
  blobIndex(0x48, 'blob_idx');

  const NvsType(this.code, this.label, {this.width, this.signed = false});

  final int code;
  final String label;

  /// Width in bytes of a primitive, `null` for the variable-length types.
  final int? width;
  final bool signed;

  bool get isPrimitive => width != null;

  /// Whether the payload lives in the entries after the header.
  bool get isVariableLength => this == string || this == blob;

  /// The types a user can ask for: everything but the v2 blob internals.
  bool get isWritable => isPrimitive || isVariableLength;

  static List<NvsType> get writable => values.where((t) => t.isWritable).toList();

  static NvsType? fromCode(int code) => values.firstWhereOrNull((t) => t.code == code);

  /// Look a type up by its [label]; only the [isWritable] ones are accepted.
  static NvsType? fromLabel(String label) => values.firstWhereOrNull((t) => t.isWritable && t.label == label);
}

/// An NVS image could not be parsed, edited, generated, or fitted to a
/// partition.
class NvsError implements Exception {
  NvsError(this.message);
  final String message;
  @override
  String toString() => 'NvsError: $message';
}

/// The image has no room left to append — the caller should compact instead.
class NoSpaceError extends NvsError {
  NoSpaceError(super.message);
}

/// The CRC32 NVS uses everywhere: zlib's `crc32(data, 0xFFFFFFFF)`. zlib
/// treats the start value as a running CRC (it XORs it with `0xFFFFFFFF` on
/// the way in and out), so this is *not* a plain seed of `0xFFFFFFFF`;
/// `getCrc32` has the same convention.
int nvsCrc32(List<int> data) => getCrc32(data, 0xFFFFFFFF) & 0xFFFFFFFF;

/// The CRC32 an entry header should carry, over bytes `[0:4] + [8:32]`.
int entryCrc(Uint8List entry) => nvsCrc32([...entry.sublist(0, 4), ...entry.sublist(8, 32)]);

/// The CRC32 a variable-length item's payload should carry.
int dataCrc(List<int> payload) => nvsCrc32(payload);

/// The CRC32 a page header should carry, over bytes `[4:28]`.
int headerCrc(Uint8List header) => nvsCrc32(Uint8List.sublistView(header, 4, 28));

/// Read the two-bit state of entry [index] out of a page's state bitmap.
NvsEntryState entryState(Uint8List bitmap, int index) {
  final bit = index * 2;
  return NvsEntryState.values[(bitmap[bit ~/ 8] >> (bit & 7)) & 0x3];
}

/// Write the two-bit state of entry [index] into a page's state bitmap.
///
/// Only clears bits, matching what flash can actually do: EMPTY → WRITTEN →
/// ERASED.
void setEntryState(Uint8List bitmap, int index, NvsEntryState state) {
  final bit = index * 2;
  final byte = bit ~/ 8, offset = bit & 7;
  bitmap[byte] &= ~(0x3 << offset) & 0xFF;
  bitmap[byte] |= state.bits << offset;
}

/// One 32-byte entry as it sits on flash, before blob chunks are reassembled.
class RawEntry {
  RawEntry({
    required this.page,
    required this.index,
    required this.state,
    required this.nsIndex,
    required this.typeCode,
    required this.span,
    required this.chunkIndex,
    required this.key,
    required this.data,
    required this.crcOk,
    this.payload,
    this.payloadCrcOk,
  });

  /// Index of the page within the image.
  final int page;

  /// Index of the entry within the page.
  final int index;
  final NvsEntryState state;
  final int nsIndex;

  /// The raw type code; see [type] for the decoded form.
  final int typeCode;
  final int span;
  final int chunkIndex;
  final String key;

  /// The 8-byte data field.
  final Uint8List data;
  final bool crcOk;

  /// Payload bytes for a string / v1 blob / blob chunk, already trimmed to its
  /// length.
  final Uint8List? payload;
  final bool? payloadCrcOk;

  NvsType? get type => NvsType.fromCode(typeCode);

  String get typeName => type?.label ?? '0x${typeCode.toRadixString(16).padLeft(2, '0')}';

  /// Byte offset of this entry from the start of the image.
  int get offset => page * NvsLayout.pageSize + NvsLayout.firstEntryOffset + index * NvsLayout.entrySize;
}

/// One 4 KiB page, parsed.
class NvsPage {
  NvsPage({
    required this.index,
    required this.state,
    required this.seq,
    required this.versionByte,
    required this.crcOk,
    List<NvsEntryState>? entryStates,
    List<RawEntry>? entries,
  })  : entryStates = entryStates ?? List.filled(NvsLayout.maxEntries, NvsEntryState.empty),
        entries = entries ?? [];

  final int index;

  /// The raw state word; see [pageState] for the decoded form.
  final int state;
  final int seq;
  final int versionByte;
  final bool crcOk;
  final List<NvsEntryState> entryStates;
  final List<RawEntry> entries;

  NvsPageState? get pageState => NvsPageState.fromValue(state);
  NvsVersion? get version => NvsVersion.fromByte(versionByte);

  bool get isUninit => state == NvsPageState.uninitialised.value;

  String get stateName => pageState?.name ?? '0x${state.toRadixString(16).padLeft(8, '0')}';

  /// Entries that are no longer EMPTY — NVS only ever appends, so this is a
  /// high-water mark.
  int get usedEntries {
    for (var i = NvsLayout.maxEntries - 1; i >= 0; i--) {
      if (entryStates[i] != NvsEntryState.empty) return i + 1;
    }
    return 0;
  }

  int get freeEntries => NvsLayout.maxEntries - usedEntries;
}

/// One logical key/value pair, with its blob chunks already stitched together.
///
/// [value] is an `int` for a primitive up to 32 bits, a `BigInt` for `u64` /
/// `i64` (a JavaScript `int` cannot hold them), a `String` for a string, and
/// a `Uint8List` for a blob.
class NvsEntry {
  NvsEntry({
    required this.namespace,
    required this.key,
    required this.type,
    required this.value,
    required this.size,
    required this.nsIndex,
    List<RawEntry>? raw,
  }) : raw = raw ?? [];

  final String namespace;
  final String key;
  final NvsType type;
  final Object value;

  /// Payload bytes on the wire (the declared width for a primitive).
  final int size;
  final int nsIndex;

  /// The entry headers backing this item — one, plus a chunk header per v2
  /// blob chunk. Each covers `span` consecutive entries starting at its own
  /// index.
  final List<RawEntry> raw;

  int get page => raw.isNotEmpty ? raw.first.page : -1;

  String get qualified => '$namespace:$key';

  /// The value as text: hex for a blob, decimal for a number.
  String get valueText => formatNvsValue(value);

  /// Render the value for a listing, abbreviating anything long.
  String formatValue({int limit = 48}) {
    final text = valueText;
    if (text.length <= limit) return text;
    final head = text.substring(0, limit);
    return value is Uint8List ? '$head… ($size bytes)' : '$head…';
  }
}

/// A parsed NVS partition image.
class NvsImage {
  NvsImage({
    required this.data,
    List<NvsPage>? pages,
    List<NvsEntry>? entries,
    Map<int, String>? namespaces,
    List<String>? errors,
    this.version = NvsVersion.v2,
  })  : pages = pages ?? [],
        entries = entries ?? [],
        namespaces = namespaces ?? {},
        errors = errors ?? [];

  final Uint8List data;
  final List<NvsPage> pages;
  final List<NvsEntry> entries;

  /// Namespace index → name, from the entries with `nsIndex` 0.
  final Map<int, String> namespaces;

  /// Anything that did not parse cleanly. Empty unless the image is damaged.
  final List<String> errors;

  /// The version of the first initialised page (v2 for a blank image).
  final NvsVersion version;

  int get size => data.length;

  NvsEntry? get(String namespace, String key) =>
      entries.firstWhereOrNull((e) => e.namespace == namespace && e.key == key);

  int? namespaceIndex(String namespace) => namespaces.entries.firstWhereOrNull((e) => e.value == namespace)?.key;
}

/// Render a value as text: hex for bytes, `toString` otherwise (a `BigInt`
/// prints as plain decimal).
String formatNvsValue(Object value) => value is Uint8List ? hexEncode(value) : value.toString();

/// Coerce a number to the representation an entry of [type] holds: `BigInt`
/// for the 64-bit types, `int` otherwise. Anything else is returned as is.
Object normalizeNvsValue(NvsType type, Object value) {
  if (type.width == 8 && value is int) return BigInt.from(value);
  if (type.width != null && type.width! < 8 && value is BigInt && value.isValidInt) return value.toInt();
  return value;
}

/// Whether two entry values are equal, comparing blobs by content.
bool valuesEqual(Object? a, Object? b) {
  if (a is List<int> && b is List<int>) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
  return a == b;
}

final BigInt _mask32 = BigInt.from(0xFFFFFFFF);

String hexEncode(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Decode a hex string; throws [FormatException] on odd length or bad digits.
Uint8List hexDecode(String text) {
  if (text.length.isOdd) throw FormatException('odd-length hex string', text);
  final out = Uint8List(text.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final byte = int.tryParse(text.substring(i * 2, i * 2 + 2), radix: 16);
    if (byte == null) throw FormatException('non-hexadecimal digit', text, i * 2);
    out[i] = byte;
  }
  return out;
}

/// Pack a primitive into the 8-byte data field, padded with erased flash.
///
/// [value] is an `int` for the types up to 32 bits and a `BigInt` (or an
/// `int`, converted) for `u64` / `i64`. Throws [NvsError] if it is out of
/// range or of the wrong kind.
Uint8List packPrimitive(NvsType type, Object value) {
  final width = type.width;
  if (width == null) throw ArgumentError.value(type, 'type', 'not a primitive');
  final out = Uint8List(8)..fillRange(0, 8, 0xFF);
  final view = ByteData.sublistView(out);

  if (width == 8) {
    final big = switch (value) {
      BigInt v => v,
      int v => BigInt.from(v),
      _ => throw NvsError("Value for ${type.label} must be a BigInt, not ${value.runtimeType}"),
    };
    final (min, max) = type.signed ? (-(BigInt.one << 63), (BigInt.one << 63) - BigInt.one) : (BigInt.zero, (BigInt.one << 64) - BigInt.one);
    if (big < min || big > max) throw NvsError('Value $big does not fit in ${type.label} ($min..$max)');
    // Two 32-bit halves through BigInt: dart2js has neither setUint64 nor 64-bit shifts.
    final bits = big.toUnsigned(64);
    view.setUint32(0, (bits & _mask32).toInt(), Endian.little);
    view.setUint32(4, (bits >> 32).toInt(), Endian.little);
    return out;
  }

  if (value is! int) throw NvsError("Value for ${type.label} must be an int, not ${value.runtimeType}");
  // Literal bounds: `1 << 32` wraps under dart2js, where shifts are 32-bit.
  final (min, max) = switch ((width, type.signed)) {
    (1, false) => (0, 0xFF),
    (1, true) => (-0x80, 0x7F),
    (2, false) => (0, 0xFFFF),
    (2, true) => (-0x8000, 0x7FFF),
    (4, false) => (0, 0xFFFFFFFF),
    _ => (-0x80000000, 0x7FFFFFFF),
  };
  if (value < min || value > max) throw NvsError('Value $value does not fit in ${type.label} ($min..$max)');
  switch (width) {
    case 1:
      view.setUint8(0, value);
    case 2:
      view.setUint16(0, value, Endian.little);
    default:
      view.setUint32(0, value, Endian.little);
  }
  return out;
}

/// Read a primitive out of the 8-byte data field: an `int`, or a `BigInt`
/// for the 64-bit types.
Object unpackPrimitive(NvsType type, Uint8List data) {
  final width = type.width;
  if (width == null) throw ArgumentError.value(type, 'type', 'not a primitive');
  final view = ByteData.sublistView(data);
  if (width == 8) {
    final value = (BigInt.from(view.getUint32(4, Endian.little)) << 32) | BigInt.from(view.getUint32(0, Endian.little));
    return type.signed ? value.toSigned(64) : value;
  }
  return switch ((width, type.signed)) {
    (1, false) => view.getUint8(0),
    (1, true) => view.getInt8(0),
    (2, false) => view.getUint16(0, Endian.little),
    (2, true) => view.getInt16(0, Endian.little),
    (4, false) => view.getUint32(0, Endian.little),
    _ => view.getInt32(0, Endian.little),
  };
}

/// Decode a 16-byte NUL-padded key field.
String decodeKey(Uint8List raw) {
  final end = raw.indexOf(0);
  return utf8.decode(end < 0 ? raw : Uint8List.sublistView(raw, 0, end), allowMalformed: true);
}
