import 'dart:convert';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';

import 'int_literal.dart';
import 'otadata.dart';

/// A malformed partition table (CSV or binary) or an invalid operation on one.
///
/// Mirrors `InputError` in ESP-IDF's `gen_esp32part.py`; messages are kept
/// identical to the Python tool so users see the same diagnostics.
class PartitionTableException implements Exception {
  PartitionTableException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A single partition failed [PartitionDefinition.verify].
class PartitionValidationException extends PartitionTableException {
  PartitionValidationException(this.partition, String message) : super('Partition ${partition.name} invalid: $message');
  final PartitionDefinition partition;
}

/// Which secure boot scheme the app partitions must be laid out for; changes
/// the app size alignment rule in [PartitionDefinition.verify].
enum SecureBoot { v1, v2 }

/// The well-known partition types (`esp_partition_type_t`). Types are stored
/// as plain ints in [PartitionDefinition.type] because custom types
/// (`0x40`-`0xFE`) are allowed; these are the ones with CSV keywords.
///
/// Declaration order matches the Python `TYPES` dict, which is the order the
/// "Known keywords" error message lists them in.
enum PartitionType {
  bootloader(0x02, 'bootloader'),
  partitionTable(0x03, 'partition_table'),
  app(0x00, 'app'),
  data(0x01, 'data');

  const PartitionType(this.value, this.keyword);
  final int value;

  /// Name used in the CSV `Type` column.
  final String keyword;

  static PartitionType? fromValue(int value) => values.firstWhereOrNull((t) => t.value == value);

  /// CSV keyword → type value.
  static final Map<String, int> keywords = {for (final t in values) t.keyword: t.value};
}

/// Subtypes of [PartitionType.bootloader].
enum BootloaderSubtype {
  primary(0x00),
  ota(0x01),
  recovery(0x02);

  const BootloaderSubtype(this.value);
  final int value;
  String get keyword => name;
}

/// Subtypes of [PartitionType.partitionTable].
enum PartitionTableSubtype {
  primary(0x00),
  ota(0x01);

  const PartitionTableSubtype(this.value);
  final int value;
  String get keyword => name;
}

/// Subtypes of [PartitionType.app] (`esp_partition_subtype_t`, `APP_*`).
enum AppSubtype {
  factory(0x00, 'factory'),
  test(0x20, 'test'),
  ota0(0x10, 'ota_0'),
  ota1(0x11, 'ota_1'),
  ota2(0x12, 'ota_2'),
  ota3(0x13, 'ota_3'),
  ota4(0x14, 'ota_4'),
  ota5(0x15, 'ota_5'),
  ota6(0x16, 'ota_6'),
  ota7(0x17, 'ota_7'),
  ota8(0x18, 'ota_8'),
  ota9(0x19, 'ota_9'),
  ota10(0x1A, 'ota_10'),
  ota11(0x1B, 'ota_11'),
  ota12(0x1C, 'ota_12'),
  ota13(0x1D, 'ota_13'),
  ota14(0x1E, 'ota_14'),
  ota15(0x1F, 'ota_15'),
  tee0(0x30, 'tee_0'),
  tee1(0x31, 'tee_1');

  const AppSubtype(this.value, this.keyword);
  final int value;
  final String keyword;

  /// `MIN_PARTITION_SUBTYPE_APP_OTA` — subtype of `ota_0`.
  static const int otaMin = 0x10;

  /// `NUM_PARTITION_SUBTYPE_APP_OTA` — number of OTA app slots.
  static const int otaCount = 16;

  /// Whether [subtype] is one of the `ota_0`..`ota_15` slots.
  static bool isOta(int subtype) => subtype >= otaMin && subtype < otaMin + otaCount;
}

/// Subtypes of [PartitionType.data] (`esp_partition_subtype_t`, `DATA_*`).
enum DataSubtype {
  ota(0x00, 'ota'),
  phy(0x01, 'phy'),
  nvs(0x02, 'nvs'),
  coredump(0x03, 'coredump'),
  nvsKeys(0x04, 'nvs_keys'),
  efuse(0x05, 'efuse'),
  undefined(0x06, 'undefined'),
  esphttpd(0x80, 'esphttpd'),
  fat(0x81, 'fat'),
  spiffs(0x82, 'spiffs'),
  littlefs(0x83, 'littlefs'),
  teeOta(0x90, 'tee_ota');

  const DataSubtype(this.value, this.keyword);
  final int value;
  final String keyword;
}

final Map<int, Map<String, int>> _subtypeKeywords = {
  PartitionType.bootloader.value: {for (final s in BootloaderSubtype.values) s.keyword: s.value},
  PartitionType.partitionTable.value: {for (final s in PartitionTableSubtype.values) s.keyword: s.value},
  PartitionType.app.value: {for (final s in AppSubtype.values) s.keyword: s.value},
  PartitionType.data.value: {for (final s in DataSubtype.values) s.keyword: s.value},
};

/// CSV subtype keyword → value for a partition [type]; empty for custom types
/// (whose subtypes must then be numeric).
Map<String, int> subtypeKeywords(int type) => _subtypeKeywords[type] ?? const {};

/// Required alignment of a partition's offset: app partitions must sit on a
/// 64K boundary (the MMU maps flash in 64K pages), everything else on a 4K
/// sector.
int offsetAlignment(int type) => type == PartitionType.app.value ? 0x10000 : 0x1000;

/// Required alignment of a partition's size. Only app partitions are
/// constrained: 64K under secure boot v1 (the 68-byte signature block sits at
/// the very end of a 64K block), otherwise 4K (the minimum erase size; secure
/// boot v2 keeps its 4K signature sector after padding the image to 64K).
int sizeAlignment(int type, [SecureBoot? secure]) {
  if (type != PartitionType.app.value) return 0x1;
  return secure == SecureBoot.v1 ? 0x10000 : 0x1000;
}

/// Parse an integer CSV field: a Python-style int literal with an optional
/// `K`/`M` suffix (any case, applied recursively so `1MK` is 1 GiB like the
/// original), falling back to a case-insensitive [keywords] lookup.
int parseIntField(String value, [Map<String, int> keywords = const {}]) {
  final lower = value.toLowerCase();
  for (final (suffix, multiplier) in [('k', 1024), ('m', 1024 * 1024)]) {
    if (lower.endsWith(suffix)) {
      return parseIntField(value.substring(0, value.length - 1), keywords) * multiplier;
    }
  }
  final parsed = tryParseIntLiteral(value);
  if (parsed != null) return parsed;
  if (keywords.isEmpty) {
    throw PartitionTableException('Invalid field value $value');
  }
  final keyword = keywords[lower];
  if (keyword == null) {
    throw PartitionTableException("Value '$value' is not valid. Known keywords: ${keywords.keys.join(', ')}");
  }
  return keyword;
}

/// One row of the partition table (`esp_partition_info_t`).
///
/// Immutable; [PartitionTable.fromCsv] resolves blank offsets and negative
/// sizes before constructing these, so [offset] and [size] are always final
/// absolute values.
class PartitionDefinition {
  const PartitionDefinition({
    required this.name,
    required this.type,
    required this.subtype,
    required this.offset,
    required this.size,
    this.encrypted = false,
    this.readonly = false,
    this.lineNumber,
  });

  /// The primary bootloader as a virtual partition, for tools that address it
  /// like any other partition (it is never stored in the table itself).
  const PartitionDefinition.bootloader({required this.offset, required this.size})
      : name = 'bootloader',
        type = 0x02,
        subtype = 0x00,
        encrypted = false,
        readonly = false,
        lineNumber = null;

  /// The partition table's own sector as a virtual partition.
  const PartitionDefinition.partitionTable({required this.offset, required this.size})
      : name = 'partition_table',
        type = 0x03,
        subtype = 0x00,
        encrypted = false,
        readonly = false,
        lineNumber = null;

  /// `ESP_PARTITION_MAGIC` as it appears in flash (`0xAA 0x50`).
  static const int magicByte0 = 0xAA;
  static const int magicByte1 = 0x50;

  /// `sizeof(esp_partition_info_t)`.
  static const int binarySize = 32;

  /// Bytes reserved for the (not necessarily NUL-terminated) label.
  static const int nameLength = 16;

  static const int _encryptedBit = 0;
  static const int _readonlyBit = 1;

  final String name;
  final int type;
  final int subtype;
  final int offset;
  final int size;

  /// `PART_FLAG_ENCRYPTED` — contents are flash-encrypted.
  final bool encrypted;

  /// `PART_FLAG_READONLY`.
  final bool readonly;

  /// 1-based CSV line this row came from, or `null` if not parsed from CSV.
  final int? lineNumber;

  int get end => offset + size;

  PartitionType? get knownType => PartitionType.fromValue(type);
  bool get isApp => type == PartitionType.app.value;
  bool get isData => type == PartitionType.data.value;
  bool get isPrimaryBootloader => type == PartitionType.bootloader.value && subtype == BootloaderSubtype.primary.value;
  bool get isPrimaryPartitionTable =>
      type == PartitionType.partitionTable.value && subtype == PartitionTableSubtype.primary.value;

  /// An `ota_N` app slot.
  bool get isOtaApp => isApp && AppSubtype.isOta(subtype);

  /// The `data/ota` partition holding the OTA selection entries.
  bool get isOtadata => isData && subtype == DataSubtype.ota.value;

  /// The type's CSV keyword, or the number for custom types.
  String get typeName => knownType?.keyword ?? '$type';

  /// The subtype's CSV keyword, or the number if it has none.
  String get subtypeName =>
      subtypeKeywords(type).entries.firstWhereOrNull((e) => e.value == subtype)?.key ?? '$subtype';

  /// Flag names in the colon-separated CSV order.
  List<String> get flagNames => [if (encrypted) 'encrypted', if (readonly) 'readonly'];

  PartitionDefinition copyWith({
    String? name,
    int? type,
    int? subtype,
    int? offset,
    int? size,
    bool? encrypted,
    bool? readonly,
    int? lineNumber,
  }) =>
      PartitionDefinition(
        name: name ?? this.name,
        type: type ?? this.type,
        subtype: subtype ?? this.subtype,
        offset: offset ?? this.offset,
        size: size ?? this.size,
        encrypted: encrypted ?? this.encrypted,
        readonly: readonly ?? this.readonly,
        lineNumber: lineNumber ?? this.lineNumber,
      );

  /// Decode one 32-byte entry from [bytes] starting at [start].
  factory PartitionDefinition.fromBinary(Uint8List bytes, [int start = 0]) {
    if (bytes.length - start < binarySize) {
      throw PartitionTableException(
          'Partition definition length must be exactly 32 bytes. Got ${bytes.length - start} bytes.');
    }
    final data = ByteData.sublistView(bytes, start, start + binarySize);
    if (data.getUint8(0) != magicByte0 || data.getUint8(1) != magicByte1) {
      throw PartitionTableException(
          "Invalid magic bytes (b'\\x${hex2(data.getUint8(0))}\\x${hex2(data.getUint8(1))}') for partition definition");
    }
    var nameBytes = Uint8List.sublistView(bytes, start + 12, start + 12 + nameLength);
    final nul = nameBytes.indexOf(0);
    if (nul >= 0) nameBytes = Uint8List.sublistView(nameBytes, 0, nul);
    final flags = data.getUint32(28, Endian.little);
    return PartitionDefinition(
      name: utf8.decode(nameBytes),
      type: data.getUint8(2),
      subtype: data.getUint8(3),
      offset: data.getUint32(4, Endian.little),
      size: data.getUint32(8, Endian.little),
      encrypted: flags & (1 << _encryptedBit) != 0,
      readonly: flags & (1 << _readonlyBit) != 0,
    );
  }

  /// Encode as a 32-byte `esp_partition_info_t`. Like the original tool the
  /// name is silently truncated to [nameLength] bytes.
  Uint8List toBinary() {
    final out = Uint8List(binarySize);
    final data = ByteData.sublistView(out);
    data.setUint8(0, magicByte0);
    data.setUint8(1, magicByte1);
    data.setUint8(2, type);
    data.setUint8(3, subtype);
    data.setUint32(4, offset, Endian.little);
    data.setUint32(8, size, Endian.little);
    final nameBytes = utf8.encode(name);
    out.setRange(12, 12 + nameBytes.length.clamp(0, nameLength), nameBytes);
    var flags = 0;
    if (encrypted) flags |= 1 << _encryptedBit;
    if (readonly) flags |= 1 << _readonlyBit;
    data.setUint32(28, flags, Endian.little);
    return out;
  }

  /// One CSV row. With [simple] the type/subtype are written numerically and
  /// sizes in hex instead of `K`/`M` shorthand.
  String toCsv({bool simple = false}) => [
        name,
        simple ? '$type' : typeName,
        simple ? '$subtype' : subtypeName,
        hex(offset),
        simple ? hex(size) : formatSize(size),
        flagNames.join(':'),
      ].join(',');

  /// Format [size] as `NM`/`NK` when it's a whole number of those, else hex.
  static String formatSize(int size) {
    for (final (unit, suffix) in [(0x100000, 'M'), (0x400, 'K')]) {
      if (size % unit == 0) return '${size ~/ unit}$suffix';
    }
    return hex(size);
  }

  /// Check alignment and flag rules for this partition in isolation. Table
  /// level rules (overlaps, uniqueness) live in [PartitionTable.verify].
  void verify({SecureBoot? secure}) {
    final offsetAlign = offsetAlignment(type);
    if (offset % offsetAlign != 0) {
      throw PartitionValidationException(this, 'Offset ${hex(offset)} is not aligned to ${hex(offsetAlign)}');
    }
    if (isApp) {
      final sizeAlign = sizeAlignment(type, secure);
      if (size % sizeAlign != 0) {
        throw PartitionValidationException(this, 'Size ${hex(size)} is not aligned to ${hex(sizeAlign)}');
      }
    }

    // otadata and coredump are written by the bootloader/panic handler, so a
    // read-only flag on them would just brick those features.
    const alwaysRwSubtypes = [0x00, 0x03];
    if (isData && alwaysRwSubtypes.contains(subtype) && readonly) {
      throw PartitionValidationException(
          this, "'$name' partition of type $type and subtype $subtype is always read-write and cannot be read-only");
    }

    if (isData && subtype == DataSubtype.nvs.value && size < PartitionTable.nvsRwMinSize && !readonly) {
      throw PartitionValidationException(
          this,
          "'$name' partition of type $type and subtype $subtype of this size (${hex(size)}) must be flagged as "
          "'readonly' (the size of read/write NVS has to be at least ${hex(PartitionTable.nvsRwMinSize)})");
    }
  }

  @override
  bool operator ==(Object other) =>
      other is PartitionDefinition &&
      other.name == name &&
      other.type == type &&
      other.subtype == subtype &&
      other.offset == offset &&
      other.size == size &&
      other.encrypted == encrypted &&
      other.readonly == readonly;

  @override
  int get hashCode => Object.hash(name, type, subtype, offset, size, encrypted, readonly);

  @override
  String toString() => "Part '$name' $type/$subtype @ ${hex(offset)} size ${hex(size)}";
}

/// A row as parsed from one CSV line, before the table pass that fills in
/// blank offsets and resolves negative ("up to this address") sizes.
typedef _CsvRow = ({
  String name,
  int type,
  int subtype,
  int? offset,
  int size,
  bool encrypted,
  bool readonly,
  int lineNumber,
});

/// The whole partition table: an unmodifiable list of [PartitionDefinition]s
/// in table order, plus the CSV/binary codecs and validation from ESP-IDF's
/// `gen_esp32part.py`.
///
/// @see [https://docs.espressif.com/projects/esp-idf/en/latest/api-guides/partition-tables.html]
class PartitionTable extends UnmodifiableListView<PartitionDefinition> {
  PartitionTable([Iterable<PartitionDefinition> entries = const []]) : super(List.of(entries));

  /// `MAX_PARTITION_LENGTH` — 3K for entries (96 rows), leaving 1K of the 4K
  /// sector for a signature.
  static const int maxBinaryLength = 0xC00;

  /// `PARTITION_TABLE_SIZE` — the table occupies one flash sector.
  static const int size = 0x1000;

  /// `PARTITION_TABLE_OFFSET` — default flash offset of the table.
  static const int defaultOffset = 0x8000;

  /// `NVS_RW_MIN_PARTITION_SIZE` — NVS needs at least 3 sectors to be writable.
  static const int nvsRwMinSize = 0x3000;

  /// First two bytes of the MD5 checksum row (`MD5_PARTITION_BEGIN`).
  static const int md5MagicByte = 0xEB;

  /// Whether [bytes] hold a binary table (starts with the entry magic) rather
  /// than CSV text.
  static bool isBinary(Uint8List bytes) =>
      bytes.length >= 2 && bytes[0] == PartitionDefinition.magicByte0 && bytes[1] == PartitionDefinition.magicByte1;

  /// Parse a table file of either format, auto-detected as in
  /// `PartitionTable.from_file`. The CSV parameters are ignored for binary
  /// input.
  static ({PartitionTable table, bool isBinary}) parse(
    Uint8List bytes, {
    int partitionTableOffset = defaultOffset,
    int? primaryBootloaderOffset,
    int? recoveryBootloaderOffset,
  }) {
    if (isBinary(bytes)) return (table: PartitionTable.fromBinary(bytes), isBinary: true);
    return (
      table: PartitionTable.fromCsv(
        decodeCsv(bytes),
        partitionTableOffset: partitionTableOffset,
        primaryBootloaderOffset: primaryBootloaderOffset,
        recoveryBootloaderOffset: recoveryBootloaderOffset,
      ),
      isBinary: false,
    );
  }

  /// Decode CSV text, honouring a UTF-8/UTF-16/UTF-32 byte order mark
  /// (`get_encoding` in the original); no BOM means UTF-8.
  static String decodeCsv(Uint8List bytes) {
    bool bom(List<int> marker) =>
        bytes.length >= marker.length && ListEquality<int>().equals(bytes.sublist(0, marker.length), marker);
    // UTF-32 LE shares its first two bytes with UTF-16 LE, so test it first.
    if (bom([0xFF, 0xFE, 0x00, 0x00])) return _decodeWide(bytes, 4, 4, Endian.little);
    if (bom([0x00, 0x00, 0xFE, 0xFF])) return _decodeWide(bytes, 4, 4, Endian.big);
    if (bom([0xFF, 0xFE])) return _decodeWide(bytes, 2, 2, Endian.little);
    if (bom([0xFE, 0xFF])) return _decodeWide(bytes, 2, 2, Endian.big);
    if (bom([0xEF, 0xBB, 0xBF])) return utf8.decode(bytes.sublist(3));
    return utf8.decode(bytes);
  }

  static String _decodeWide(Uint8List bytes, int skip, int width, Endian endian) {
    final data = ByteData.sublistView(bytes, skip);
    final units = <int>[];
    for (var i = 0; i + width <= data.lengthInBytes; i += width) {
      units.add(width == 2 ? data.getUint16(i, endian) : data.getUint32(i, endian));
    }
    return String.fromCharCodes(units);
  }

  /// Parse the CSV format documented by ESP-IDF.
  ///
  /// Rows with a blank offset are placed after the previous row (rounded up to
  /// the type's alignment); the first such row goes right after the table
  /// sector at [partitionTableOffset]. A negative size means "extend up to
  /// that absolute address". `bootloader`/`partition_table` rows take their
  /// offset and size from [primaryBootloaderOffset], [recoveryBootloaderOffset]
  /// and [partitionTableOffset] rather than the CSV, because those values are
  /// chip/config dependent.
  ///
  /// `$NAME`/`${NAME}` references are substituted from [variables] (the
  /// original expands environment variables, which don't exist in a browser);
  /// an unresolved reference is an error.
  factory PartitionTable.fromCsv(
    String csv, {
    int partitionTableOffset = defaultOffset,
    int? primaryBootloaderOffset,
    int? recoveryBootloaderOffset,
    Map<String, String> variables = const {},
  }) {
    final rows = <_CsvRow>[];
    final lines = const LineSplitter().convert(csv);
    for (var i = 0; i < lines.length; i++) {
      final lineNumber = i + 1;
      try {
        final line = _expandVariables(lines[i], variables).trim();
        if (line.isEmpty || line.startsWith('#')) continue;
        rows.add(
            _parseCsvRow(line, lineNumber, partitionTableOffset, primaryBootloaderOffset, recoveryBootloaderOffset));
      } on PartitionTableException catch (e) {
        throw PartitionTableException('Error at line $lineNumber: ${e.message}');
      }
    }

    // Fix up missing offsets and negative sizes.
    final entries = <PartitionDefinition>[];
    var lastEnd = partitionTableOffset + size; // first offset after the partition table
    for (final row in rows) {
      final isPrimaryBootloader =
          row.type == PartitionType.bootloader.value && row.subtype == BootloaderSubtype.primary.value;
      final isPrimaryPartitionTable =
          row.type == PartitionType.partitionTable.value && row.subtype == PartitionTableSubtype.primary.value;
      var offset = row.offset;
      var rowSize = row.size;
      if (!(isPrimaryBootloader || isPrimaryPartitionTable)) {
        // Those two live below the table by definition and don't take part in
        // the "next free offset" bookkeeping.
        if (offset != null && offset < lastEnd) {
          if (identical(row, rows.first)) {
            throw PartitionTableException(
                'CSV Error at line ${row.lineNumber}: Partitions overlap. Partition sets offset '
                '${hex(offset)}. But partition table occupies the whole sector ${hex(partitionTableOffset)}. '
                'Use a free offset ${hex(lastEnd)} or higher.');
          }
          throw PartitionTableException(
              'CSV Error at line ${row.lineNumber}: Partitions overlap. Partition sets offset '
              '${hex(offset)}. Previous partition ends ${hex(lastEnd)}');
        }
        if (offset == null) {
          final padTo = offsetAlignment(row.type);
          if (lastEnd % padTo != 0) lastEnd += padTo - (lastEnd % padTo);
          offset = lastEnd;
        }
        if (rowSize < 0) rowSize = -rowSize - offset;
        lastEnd = offset + rowSize;
      }
      entries.add(PartitionDefinition(
        name: row.name,
        type: row.type,
        subtype: row.subtype,
        // A primary bootloader/table row always has its offset resolved from
        // the parameters, so this is only reachable for the fixed-up rows.
        offset: offset!,
        size: rowSize,
        encrypted: row.encrypted,
        readonly: row.readonly,
        lineNumber: row.lineNumber,
      ));
    }
    return PartitionTable(entries);
  }

  static final _variableRef = RegExp(r'(?<!\\)\$(?:([A-Za-z_][A-Za-z0-9_]*)|\{([A-Za-z_][A-Za-z0-9_]*)\})');

  static String _expandVariables(String line, Map<String, String> variables) {
    if (!line.contains(r'$')) return line;
    return line.replaceAllMapped(_variableRef, (m) {
      final name = (m[1] ?? m[2])!;
      final value = variables[name];
      if (value == null) throw PartitionTableException("unknown variable '$name'");
      return value;
    });
  }

  static _CsvRow _parseCsvRow(
    String line,
    int lineNumber,
    int partitionTableOffset,
    int? primaryBootloaderOffset,
    int? recoveryBootloaderOffset,
  ) {
    // Pad so that trailing fields may be omitted entirely.
    final fields = '$line,,,,'.split(',').map((f) => f.trim()).toList();
    final name = fields[0];

    if (fields[1].isEmpty) throw PartitionTableException("Field 'type' can't be left empty.");
    final type = parseIntField(fields[1], PartitionType.keywords);

    final int subtype;
    if (fields[2].isEmpty) {
      if (type == PartitionType.app.value) throw PartitionTableException('App partition cannot have an empty subtype');
      subtype = DataSubtype.undefined.value;
    } else {
      subtype = parseIntField(fields[2], subtypeKeywords(type));
    }

    final int? offset;
    if (type == PartitionType.bootloader.value && subtype == BootloaderSubtype.primary.value) {
      offset = primaryBootloaderOffset ?? (throw PartitionTableException('Primary bootloader offset is not provided'));
    } else if (type == PartitionType.bootloader.value && subtype == BootloaderSubtype.recovery.value) {
      offset =
          recoveryBootloaderOffset ?? (throw PartitionTableException('Recovery bootloader offset is not provided'));
    } else if (type == PartitionType.partitionTable.value && subtype == PartitionTableSubtype.primary.value) {
      offset = partitionTableOffset;
    } else if (fields[3].isEmpty) {
      offset = null;
    } else {
      offset = parseIntField(fields[3]);
    }

    final int rowSize;
    if (type == PartitionType.bootloader.value) {
      // The bootloader region is everything between its offset and the table.
      if (primaryBootloaderOffset == null) throw PartitionTableException('Primary bootloader offset is not provided');
      rowSize = partitionTableOffset - primaryBootloaderOffset;
    } else if (type == PartitionType.partitionTable.value) {
      rowSize = size;
    } else if (fields[4].isEmpty) {
      throw PartitionTableException("Size field can't be empty");
    } else {
      rowSize = parseIntField(fields[4]);
    }

    var encrypted = false;
    var readonly = false;
    for (final flag in fields[5].split(':')) {
      switch (flag) {
        case 'encrypted':
          encrypted = true;
        case 'readonly':
          readonly = true;
        case '':
          break;
        default:
          throw PartitionTableException("CSV flag column contains unknown flag '$flag'");
      }
    }

    return (
      name: name,
      type: type,
      subtype: subtype,
      offset: offset,
      size: rowSize,
      encrypted: encrypted,
      readonly: readonly,
      lineNumber: lineNumber,
    );
  }

  /// Decode a binary table: 32-byte entries terminated by an all-`0xFF` entry,
  /// with an optional MD5 row (`0xEBEB`, 14×`0xFF`, digest of everything before
  /// it) that is checked unless [md5sum] is false.
  factory PartitionTable.fromBinary(Uint8List bytes, {bool md5sum = true}) {
    final entries = <PartitionDefinition>[];
    final hashed = BytesBuilder(copy: false);
    for (var o = 0; o < bytes.length; o += PartitionDefinition.binarySize) {
      if (bytes.length - o < PartitionDefinition.binarySize) {
        throw PartitionTableException('Partition table length must be a multiple of 32 bytes');
      }
      final entry = Uint8List.sublistView(bytes, o, o + PartitionDefinition.binarySize);
      if (entry.every((b) => b == 0xFF)) return PartitionTable(entries); // end marker
      if (md5sum && entry[0] == md5MagicByte && entry[1] == md5MagicByte) {
        final computed = md5.convert(hashed.toBytes()).bytes;
        final parsed = entry.sublist(16);
        if (ListEquality<int>().equals(computed, parsed)) continue; // next entry should be the end marker
        throw PartitionTableException(
            "MD5 checksums don't match! (computed: 0x${_hexString(computed)}, parsed: 0x${_hexString(parsed)})");
      }
      hashed.add(entry);
      entries.add(PartitionDefinition.fromBinary(entry));
    }
    throw PartitionTableException('Partition table is missing an end-of-table marker');
  }

  /// Encode as the [maxBinaryLength]-byte sector image ESP-IDF flashes: the
  /// entries, an MD5 row (unless [md5sum] is false), and `0xFF` padding, which
  /// doubles as the end marker.
  Uint8List toBinary({bool md5sum = true}) {
    final builder = BytesBuilder(copy: false);
    for (final entry in this) {
      builder.add(entry.toBinary());
    }
    if (md5sum) {
      final digest = md5.convert(builder.toBytes()).bytes;
      builder.add([md5MagicByte, md5MagicByte, ...List.filled(14, 0xFF)]);
      builder.add(digest);
    }
    if (builder.length >= maxBinaryLength) {
      throw PartitionTableException('Binary partition table length (${builder.length}) longer than max');
    }
    builder.add(Uint8List(maxBinaryLength - builder.length)..fillRange(0, maxBinaryLength - builder.length, 0xFF));
    return builder.takeBytes();
  }

  /// Serialise as CSV in the layout ESP-IDF's tools emit, including the two
  /// header comments. See [PartitionDefinition.toCsv] for [simple].
  String toCsv({bool simple = false}) => [
        '# ESP-IDF Partition Table',
        '# Name, Type, SubType, Offset, Size, Flags',
        for (final entry in this) entry.toCsv(simple: simple),
        '',
      ].join('\n');

  PartitionDefinition? findByName(String name) => firstWhereOrNull((p) => p.name == name);

  /// Match by type and subtype, given either as a number or a CSV keyword.
  Iterable<PartitionDefinition> findByType(Object type, Object subtype) {
    final typeValue = type is int ? type : parseIntField(type as String, PartitionType.keywords);
    final subtypeValue = subtype is int ? subtype : parseIntField(subtype as String, subtypeKeywords(typeValue));
    return where((p) => p.type == typeValue && p.subtype == subtypeValue);
  }

  /// The `data/ota` partition, or `null` if the table has none.
  PartitionDefinition? get otadataPartition => firstWhereOrNull((p) => p.isOtadata);

  /// Number of `ota_N` app slots, i.e. what `esp_ota_get_app_partition_count`
  /// reports and what the otadata sequence number is taken modulo.
  int get otaAppCount => where((p) => p.isOtaApp).length;

  /// Check every partition ([PartitionDefinition.verify]) plus the table-wide
  /// rules: unique names, no overlaps, nothing but the primary bootloader and
  /// table below the end of the table sector (when [partitionTableOffset] is
  /// given), and exactly one otadata / TEE otadata of size `0x2000`.
  void verify({int? partitionTableOffset, SecureBoot? secure}) {
    for (final p in this) {
      p.verify(secure: secure);
    }

    final names = map((p) => p.name).toList();
    if (names.toSet().length != names.length) {
      throw PartitionTableException('Partition names must be unique');
    }

    // Stable sort, so identical offsets are reported in table order like Python.
    final byOffset = toList();
    mergeSort(byOffset, compare: (a, b) => a.offset.compareTo(b.offset));
    PartitionDefinition? last;
    for (final p in byOffset) {
      if (partitionTableOffset != null &&
          p.offset < partitionTableOffset + size &&
          !(p.isPrimaryBootloader || p.isPrimaryPartitionTable)) {
        throw PartitionTableException('Partition offset ${hex(p.offset)} is below ${hex(partitionTableOffset + size)}');
      }
      if (last != null && p.offset < last.end) {
        throw PartitionTableException(
            'Partition at ${hex(p.offset)} overlaps ${hex(last.offset)}-${hex(last.end - 1)}');
      }
      last = p;
    }

    final otadata = where((p) => p.isOtadata).toList();
    if (otadata.length > 1) {
      throw PartitionTableException('Found multiple otadata partitions. Only one partition can be defined with '
          'type="data"(1) and subtype="ota"(0).');
    }
    if (otadata.length == 1 && otadata.single.size != 0x2000) {
      throw PartitionTableException('otadata partition must have size = 0x2000');
    }

    final teeOtadata = where((p) => p.isData && p.subtype == DataSubtype.teeOta.value).toList();
    if (teeOtadata.length > 1) {
      throw PartitionTableException('Found multiple TEE otadata partitions. Only one partition can be defined with '
          'type="data"(1) and subtype="tee_ota"(0x90).');
    }
    if (teeOtadata.length == 1 && teeOtadata.single.size != 0x2000) {
      throw PartitionTableException('TEE otadata partition must have size = 0x2000');
    }
  }

  /// End of the partition with the highest offset, i.e. how much flash the
  /// table lays claim to (0 for an empty table).
  int get flashSize {
    PartitionDefinition? last;
    for (final p in this) {
      if (last == null || p.offset > last.offset) last = p;
    }
    return last?.end ?? 0;
  }

  /// Throw unless [flashSize] fits in [flashSizeBytes].
  void verifySizeFits(int flashSizeBytes) {
    final tableSize = flashSize;
    if (flashSizeBytes < tableSize) {
      const mb = 1024 * 1024;
      throw PartitionTableException('Partitions tables occupies ${(tableSize / mb).toStringAsFixed(1)}MB of flash '
          '($tableSize bytes) which does not fit in available flash size ${flashSizeBytes ~/ mb}MB.');
    }
  }

  /// Throw if the table has no partitions; [source] names where it came from.
  PartitionTable requireNotEmpty(String source) {
    if (isEmpty) throw PartitionTableException('Partition table from $source is empty (no partitions defined)');
    return this;
  }

  /// Render as a Markdown-style table (`print_partition_table`).
  ///
  /// A `Flags` column appears only if some partition has flags. With
  /// [otadata], the otadata row shows which copy (`A`/`B`) is live, and — when
  /// [appDescription] is given, which adds an `App description` column filled
  /// from that callback for app partitions — the active OTA slot is marked
  /// with `*`.
  String format({OtaDataParameters? otadata, String Function(PartitionDefinition partition)? appDescription}) {
    final hasFlags = any((p) => p.flagNames.isNotEmpty);
    final activeSlot = otadata?.slot;
    final activeAppSubtype = activeSlot == null ? null : AppSubtype.otaMin + activeSlot;

    final rows = <List<String>>[
      [
        'Name',
        'Type',
        'Subtype',
        'Offset',
        'Size',
        if (hasFlags) 'Flags',
        if (appDescription != null) 'App description'
      ],
    ];
    for (final p in this) {
      var subtype = p.subtypeName;
      if (otadata != null && p.isOtadata) {
        subtype = '$subtype (${otadata.copy?.name.toUpperCase() ?? 'invalid'})';
      }
      final cells = [p.name, p.typeName, subtype, hex(p.offset), PartitionDefinition.formatSize(p.size)];
      if (hasFlags) cells.add(p.flagNames.join(':'));
      if (appDescription != null) {
        var description = p.isApp ? appDescription(p) : '';
        if (activeAppSubtype != null && p.isApp && p.subtype == activeAppSubtype) {
          description = description.isEmpty ? '*' : '$description *';
        }
        cells.add(description);
      }
      rows.add(cells);
    }

    final widths = List.generate(rows.first.length, (i) => rows.map((r) => r[i].length).max);
    String line(List<String> cells) =>
        '|${[for (var i = 0; i < cells.length; i++) ' ${cells[i].padRight(widths[i])} '].join('|')}|';
    return [
      line(rows.first),
      '|${widths.map((w) => '-' * (w + 2)).join('|')}|',
      for (final row in rows.skip(1)) line(row),
    ].join('\n');
  }

  static String _hexString(List<int> bytes) => bytes.map(hex2).join();
}

/// Two-digit lowercase hex of a byte.
String hex2(int byte) => byte.toRadixString(16).padLeft(2, '0');
