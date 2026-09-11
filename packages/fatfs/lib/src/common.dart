/// The FAT on-disk layout, and the types shared by the FAT modules.
///
/// A FAT volume (as ESP-IDF's `fatfsgen.py` and idftool lay it out) is:
///
/// ```
/// [boot sector][FAT 1][FAT 2][root directory][data clusters ...]
/// ```
///
/// The boot sector's BIOS Parameter Block describes the geometry:
///
/// ```
/// +-------+------+-------------------------------------------------------+
/// |   0   |    3 | jump instruction (0xEB xx 0x90 or 0xE9 xx xx)         |
/// |   3   |    8 | OEM name                                              |
/// |  11   |    2 | bytes per sector                                      |
/// |  13   |    1 | sectors per cluster                                   |
/// |  14   |    2 | reserved sectors (the boot sector itself)             |
/// |  16   |    1 | number of FATs                                        |
/// |  17   |    2 | root directory entries (0 on FAT32)                   |
/// |  19   |    2 | total sectors, if it fits in 16 bits                  |
/// |  21   |    1 | media descriptor (0xF8 = fixed disk)                  |
/// |  22   |    2 | sectors per FAT (0 on FAT32)                          |
/// |  24   |    2 | sectors per track      (geometry, unused)             |
/// |  26   |    2 | heads                  (geometry, unused)             |
/// |  28   |    4 | hidden sectors                                        |
/// |  32   |    4 | total sectors, if the 16-bit field is 0               |
/// | -- FAT12/16 extended BPB --                                          |
/// |  36   |    1 | drive number                                          |
/// |  37   |    1 | reserved (NT dirty flag)                              |
/// |  38   |    1 | extended boot signature, 0x29 when the rest is valid  |
/// |  39   |    4 | volume serial number                                  |
/// |  43   |   11 | volume label                                          |
/// |  54   |    8 | filesystem type string, informational only            |
/// | -- FAT32 extended BPB --                                             |
/// |  36   |    4 | sectors per FAT                                       |
/// |  40   |    2 | flags                                                 |
/// |  42   |    2 | version                                               |
/// |  44   |    4 | root directory cluster                                |
/// |  48   |    2 | FSInfo sector                                         |
/// |  50   |    2 | backup boot sector                                    |
/// |  52   |   12 | reserved                                              |
/// |  64   |    1 | drive number                                          |
/// |  65   |    1 | reserved                                              |
/// |  66   |    1 | extended boot signature                               |
/// |  67   |    4 | volume serial number                                  |
/// |  71   |   11 | volume label                                          |
/// |  82   |    8 | filesystem type string                                |
/// | 510   |    2 | 0x55 0xAA                                             |
/// +-------+------+-------------------------------------------------------+
/// ```
///
/// The FAT width is never declared — every implementation derives it from the
/// cluster count alone (FAT12 below 4085 clusters, FAT16 below 65525, FAT32
/// beyond), so the type string at offset 54 is decoration.
///
/// A directory is an array of 32-byte entries:
///
/// ```
/// +-------+------+-------------------------------------------------------+
/// |   0   |   11 | 8.3 name, space padded; first byte 0xE5 = deleted,    |
/// |       |      | 0x00 = end of directory, 0x05 stands for a real 0xE5  |
/// |  11   |    1 | attributes (see FatAttr)                              |
/// |  12   |    1 | NT reserved (case flags)                              |
/// |  13   |    1 | creation time, tenths of a second                     |
/// |  14   |    2 | creation time     (DOS time)                          |
/// |  16   |    2 | creation date     (DOS date)                          |
/// |  18   |    2 | last access date  (DOS date)                          |
/// |  20   |    2 | first cluster, high half (FAT32 only)                 |
/// |  22   |    2 | write time        (DOS time)                          |
/// |  24   |    2 | write date        (DOS date)                          |
/// |  26   |    2 | first cluster, low half                               |
/// |  28   |    4 | file size                                             |
/// +-------+------+-------------------------------------------------------+
/// ```
///
/// A long name is spelled out in the entries *preceding* its 8.3 entry, in
/// reverse order (the last part first), each with attributes 0x0F so DOS
/// skips them:
///
/// ```
/// +-------+------+-------------------------------------------------------+
/// |   0   |    1 | sequence number 1..20, 0x40 set on the last part      |
/// |   1   |   10 | characters 1–5   (UTF-16LE)                           |
/// |  11   |    1 | attributes = 0x0F                                     |
/// |  12   |    1 | type = 0                                              |
/// |  13   |    1 | checksum of the 8.3 name it belongs to                |
/// |  14   |   12 | characters 6–11  (UTF-16LE)                           |
/// |  26   |    2 | first cluster = 0                                     |
/// |  28   |    4 | characters 12–13 (UTF-16LE)                           |
/// +-------+------+-------------------------------------------------------+
/// ```
///
/// The name is NUL-terminated if it does not fill its last part exactly, and
/// the rest of that part is padded with 0xFFFF.
///
/// DOS timestamps are 16-bit words: a date is `(year - 1980) << 9 | month << 5
/// | day`, a time is `hour << 11 | minute << 5 | second / 2`. They carry no
/// time zone.
library;

import 'dart:typed_data';

/// A FAT image could not be parsed, built, or fitted to a partition.
class FatException implements Exception {
  FatException(this.message);
  final String message;
  @override
  String toString() => 'FatException: $message';
}

/// Sizes, offsets and marker values of the on-disk layout.
abstract final class FatLayout {
  static const int bootSignatureOffset = 510;
  static const int dirEntrySize = 32;

  /// The ESP-IDF geometry defaults (`fatfsgen.py`): 4 KiB sectors matching
  /// `CONFIG_WL_SECTOR_SIZE`, one sector per cluster, two FATs and a 512-entry
  /// root directory.
  static const int defaultSectorSize = 0x1000;
  static const int defaultSectorsPerCluster = 1;
  static const int reservedSectors = 1;
  static const int fatCount = 2;
  static const int rootEntries = 512;
  static const int mediaType = 0xF8;
  static const String oemName = 'MSDOS5.0';
  static const String defaultLabel = 'Espressif';

  /// Cluster counts at which FatFs (and every other implementation) switches
  /// FAT width.
  static const int fat12MaxClusters = 4084;
  static const int fat16MaxClusters = 65524;

  /// The first data cluster; entries 0 and 1 of the FAT are reserved markers.
  static const int firstCluster = 2;

  /// The first byte of a directory entry that has been deleted.
  static const int deletedEntry = 0xE5;

  /// The first byte of a directory entry past the last one in use.
  static const int endOfDirectory = 0x00;

  /// Stands for a real 0xE5 as the first byte of an 8.3 name.
  static const int escapedE5 = 0x05;

  /// Flag on the sequence number of the last (first on disk) long name part.
  static const int lastLongEntry = 0x40;

  /// UTF-16 code units of a long name carried by one entry.
  static const int lfnCharsPerEntry = 13;

  /// The longest long file name.
  static const int maxLongName = 255;

  static const int erased = 0xFF;
}

/// Directory entry attribute bits.
abstract final class FatAttr {
  static const int readOnly = 0x01;
  static const int hidden = 0x02;
  static const int system = 0x04;
  static const int volumeId = 0x08;
  static const int directory = 0x10;
  static const int archive = 0x20;

  /// A long name part has all four low bits set.
  static const int longName = readOnly | hidden | system | volumeId;

  /// Bits compared when recognising a long name part.
  static const int longNameMask = longName | directory | archive;

  static bool isLongName(int attr) => (attr & longNameMask) == longName;
}

/// The special FAT entry values for a FAT width.
///
/// A FAT entry is either free (0), the next cluster in the chain, the bad
/// cluster marker, or an end-of-chain marker (anything at or above [eocMin]).
/// [maxDataCluster] is the highest cluster number pyfatfs will hand out —
/// slightly below the marker range — and is what caps allocation in
/// `fatCreate` so it matches byte for byte.
enum FatBits {
  fat12(12, maxDataCluster: 0xFEF, badCluster: 0xFF7, eocMin: 0xFF8, eoc: 0xFFF),
  fat16(16, maxDataCluster: 0xFFEF, badCluster: 0xFFF7, eocMin: 0xFFF8, eoc: 0xFFFF),
  fat32(32, maxDataCluster: 0x0FFFFFEF, badCluster: 0x0FFFFFF7, eocMin: 0x0FFFFFF8, eoc: 0x0FFFFFFF);

  const FatBits(this.bits,
      {required this.maxDataCluster, required this.badCluster, required this.eocMin, required this.eoc});

  final int bits;
  final int maxDataCluster;
  final int badCluster;
  final int eocMin;

  /// The end-of-chain marker written by pyfatfs (`END_OF_CLUSTER_MAX`).
  final int eoc;

  /// The width a volume of [clusterCount] clusters is read as.
  static FatBits forClusterCount(int clusterCount) {
    if (clusterCount <= FatLayout.fat12MaxClusters) return fat12;
    if (clusterCount <= FatLayout.fat16MaxClusters) return fat16;
    return fat32;
  }

  static FatBits? fromBits(int bits) => switch (bits) { 12 => fat12, 16 => fat16, 32 => fat32, _ => null };

  /// pyfatfs treats FAT12's 0xFF0 as an end-of-chain marker too, and skips it
  /// when allocating.
  bool isEndOfChain(int value) => value >= eocMin || (this == fat12 && value == 0xFF0);

  /// The FAT entry for cluster [i] out of a whole FAT region.
  int read(Uint8List fat, int i) {
    switch (this) {
      case fat12:
        final offset = i + (i >> 1); // i * 1.5
        if (offset + 1 >= fat.length) return 0;
        final word = fat[offset] | (fat[offset + 1] << 8);
        return i.isEven ? word & 0xFFF : word >> 4;
      case fat16:
        final offset = i * 2;
        if (offset + 1 >= fat.length) return 0;
        return fat[offset] | (fat[offset + 1] << 8);
      case fat32:
        final offset = i * 4;
        if (offset + 3 >= fat.length) return 0;
        // The top four bits are reserved: a FAT32 entry is really 28 bits wide.
        return ByteData.sublistView(fat).getUint32(offset, Endian.little) & 0x0FFFFFFF;
    }
  }

  /// Store [value] as the FAT entry for cluster [i].
  void write(Uint8List fat, int i, int value) {
    switch (this) {
      case fat12:
        final offset = i + (i >> 1);
        if (i.isEven) {
          fat[offset] = value & 0xFF;
          fat[offset + 1] = (fat[offset + 1] & 0xF0) | ((value >> 8) & 0x0F);
        } else {
          fat[offset] = (fat[offset] & 0x0F) | ((value & 0x0F) << 4);
          fat[offset + 1] = (value >> 4) & 0xFF;
        }
      case fat16:
        fat[i * 2] = value & 0xFF;
        fat[i * 2 + 1] = (value >> 8) & 0xFF;
      case fat32:
        ByteData.sublistView(fat).setUint32(i * 4, value & 0x0FFFFFFF, Endian.little);
    }
  }

  /// Bytes a FAT holding [entries] entries takes.
  int fatBytes(int entries) => this == fat12 ? (entries * 3 + 1) ~/ 2 : entries * (bits ~/ 8);
}

// --------------------------------------------------------------------------
// Code page 437
// --------------------------------------------------------------------------

/// Code page 437, the "OEM" character set 8.3 names are stored in. The low
/// half is ASCII; this is the high half, indexed by `byte - 0x80`.
const List<int> _cp437High = [
  0x00C7, 0x00FC, 0x00E9, 0x00E2, 0x00E4, 0x00E0, 0x00E5, 0x00E7, //
  0x00EA, 0x00EB, 0x00E8, 0x00EF, 0x00EE, 0x00EC, 0x00C4, 0x00C5,
  0x00C9, 0x00E6, 0x00C6, 0x00F4, 0x00F6, 0x00F2, 0x00FB, 0x00F9,
  0x00FF, 0x00D6, 0x00DC, 0x00A2, 0x00A3, 0x00A5, 0x20A7, 0x0192,
  0x00E1, 0x00ED, 0x00F3, 0x00FA, 0x00F1, 0x00D1, 0x00AA, 0x00BA,
  0x00BF, 0x2310, 0x00AC, 0x00BD, 0x00BC, 0x00A1, 0x00AB, 0x00BB,
  0x2591, 0x2592, 0x2593, 0x2502, 0x2524, 0x2561, 0x2562, 0x2556,
  0x2555, 0x2563, 0x2551, 0x2557, 0x255D, 0x255C, 0x255B, 0x2510,
  0x2514, 0x2534, 0x252C, 0x251C, 0x2500, 0x253C, 0x255E, 0x255F,
  0x255A, 0x2554, 0x2569, 0x2566, 0x2560, 0x2550, 0x256C, 0x2567,
  0x2568, 0x2564, 0x2565, 0x2559, 0x2558, 0x2552, 0x2553, 0x256B,
  0x256A, 0x2518, 0x250C, 0x2588, 0x2584, 0x258C, 0x2590, 0x2580,
  0x03B1, 0x00DF, 0x0393, 0x03C0, 0x03A3, 0x03C3, 0x00B5, 0x03C4,
  0x03A6, 0x0398, 0x03A9, 0x03B4, 0x221E, 0x03C6, 0x03B5, 0x2229,
  0x2261, 0x00B1, 0x2265, 0x2264, 0x2320, 0x2321, 0x00F7, 0x2248,
  0x00B0, 0x2219, 0x00B7, 0x221A, 0x207F, 0x00B2, 0x25A0, 0x00A0,
];

final Map<int, int> _cp437Encode = {
  for (var i = 0; i < _cp437High.length; i++) _cp437High[i]: 0x80 + i,
};

/// Decode code page 437 bytes.
String cp437Decode(List<int> bytes) =>
    String.fromCharCodes([for (final b in bytes) b < 0x80 ? b : _cp437High[b - 0x80]]);

/// Encode a code point in code page 437, or `null` if it has no encoding.
int? cp437EncodeRune(int rune) => rune < 0x80 ? rune : _cp437Encode[rune];

// --------------------------------------------------------------------------
// Timestamps
// --------------------------------------------------------------------------

/// A DOS date word for [dt]'s wall-clock fields (its time zone is ignored).
int dosDate(DateTime dt) {
  if (dt.year < 1980 || dt.year > 2107) throw FatException('Year ${dt.year} is outside the DOS range 1980..2107');
  return ((dt.year - 1980) << 9) | (dt.month << 5) | dt.day;
}

/// A DOS time word for [dt]'s wall-clock fields; seconds round down to even.
int dosTime(DateTime dt) => (dt.hour << 11) | (dt.minute << 5) | (dt.second >> 1);

/// Decode a DOS date/time pair, or `null` if the fields are not a real date.
///
/// DOS timestamps carry no time zone, so the result is a UTC `DateTime`
/// holding exactly the fields that were on disk.
DateTime? dosDateTime(int date, int time) {
  final year = 1980 + (date >> 9), month = (date >> 5) & 0xF, day = date & 0x1F;
  final hour = time >> 11, minute = (time >> 5) & 0x3F, second = (time & 0x1F) * 2;
  if (month < 1 || month > 12 || day < 1 || hour > 23 || minute > 59 || second > 59) return null;
  final dt = DateTime.utc(year, month, day, hour, minute, second);
  // DateTime normalises an out-of-range day (Feb 30 → Mar 1); refuse those.
  if (dt.day != day || dt.month != month) return null;
  return dt;
}

// --------------------------------------------------------------------------
// Names
// --------------------------------------------------------------------------

/// The checksum of an 11-byte 8.3 name that its long name parts carry.
int shortNameChecksum(List<int> name) {
  var sum = 0;
  for (var i = 0; i < 11; i++) {
    sum = (((sum & 1) << 7) | (sum >> 1)) + name[i];
    sum &= 0xFF;
  }
  return sum;
}

/// The human form of a stored 11-byte 8.3 name: `BASE.EXT`, trailing spaces
/// dropped and the 0x05 escape restored.
String shortNameToString(List<int> name) {
  final bytes = List<int>.of(name);
  if (bytes[0] == FatLayout.escapedE5) bytes[0] = FatLayout.deletedEntry;
  final base = cp437Decode(bytes.sublist(0, 8)).trimRight();
  final ext = cp437Decode(bytes.sublist(8, 11)).trimRight();
  return ext.isEmpty ? base : '$base.$ext';
}

/// Order strings by code point, like python does, rather than by UTF-16 unit.
int compareCodePoints(String a, String b) {
  final ai = a.runes.iterator, bi = b.runes.iterator;
  while (true) {
    final an = ai.moveNext(), bn = bi.moveNext();
    if (!an || !bn) return an == bn ? 0 : (an ? 1 : -1);
    if (ai.current != bi.current) return ai.current.compareTo(bi.current);
  }
}

String hex(int value) => '0x${value.toRadixString(16)}';
