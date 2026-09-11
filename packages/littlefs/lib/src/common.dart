/// The littlefs v2 on-disk layout, and the types shared by the littlefs
/// modules.
///
/// A littlefs image is an array of equally sized blocks. Everything hangs off
/// *metadata pairs*: two blocks that hold the same directory, written
/// alternately so that one is always intact while the other is erased and
/// rewritten. Each block of a pair is an append-only log:
///
/// ```
/// +-------+------+---------------------------------------------------------+
/// | 0x00  |    4 | revision count, LE — the block with the newer one wins  |
/// | 0x04  |  ... | commit: tags with their data, ended by a CRC tag        |
/// |  ...  |  ... | commit                                                  |
/// |  ...  |  ... | erased space (0xFF) for further commits                 |
/// +-------+------+---------------------------------------------------------+
/// ```
///
/// A tag is a 32-bit word stored *big-endian* (the only big-endian value in
/// the format), XORed with the previous tag on disk so that the log can be
/// walked in either direction. The chain starts from `0xFFFFFFFF`, which also
/// makes erased flash decode as an invalid tag:
///
/// ```
/// [1|--  11  --|--  10  --|--  10  --]
///  ^      ^          ^          ^- length of the data that follows (0x3FF:
///  |      |          |             "deleted", no data)
///  |      |          '------------ id: which entry in the directory (0x3FF:
///  |      |                        none — directory-wide metadata)
///  |      '----------------------- type3: 3-bit type1 + 8-bit chunk
///  '------------------------------ valid bit, zero after the XOR
/// ```
///
/// The type1 classes and the concrete tags a reader needs:
///
/// ```
/// 0x0xx NAME      chunk is the file type: 0x01 REG, 0x02 DIR, 0xFF SUPERBLOCK
/// 0x2xx STRUCT    0x200 DIRSTRUCT {pair}, 0x201 INLINESTRUCT data,
///                 0x202 CTZSTRUCT {head, size}
/// 0x3xx USERATTR  user attribute, chunk is the attribute type
/// 0x4xx SPLICE    chunk is a signed shift: 0x401 CREATE (+1), 0x4FF DELETE (-1)
/// 0x5xx CRC       0x500/0x501 commit CRC (+padding), 0x5FF FCRC (v2.1)
/// 0x6xx TAIL      0x600 SOFTTAIL, 0x601 HARDTAIL {pair}
/// 0x7xx GSTATE    0x7FF MOVESTATE {tag, pair} delta of the global state
/// ```
///
/// A commit's CRC tag carries a CRC-32 (polynomial `0x04C11DB7`, reflected,
/// seeded `0xFFFFFFFF`, no final XOR) of everything since the previous CRC
/// tag — for the first commit that includes the revision count — up to and
/// including the CRC tag word itself. A commit whose CRC does not match is a
/// write that lost power, and it and everything after it is ignored.
///
/// Entries in a directory are addressed by *id*. Ids are dense and sorted by
/// name: CREATE shifts the ids at and above its own up by one before a new
/// entry is written, DELETE shifts them down. Replaying the log in order with
/// those shifts gives the live table of entries, where the newest NAME and
/// STRUCT tag for each id win.
///
/// Files are either inline (data in the INLINESTRUCT tag) or CTZ skip-lists:
/// blocks holding the data in reverse order, each block `n > 0` starting with
/// `ctz(n) + 1` little-endian block pointers — pointer `k` points `2^k`
/// blocks back — followed by the data. The CTZSTRUCT holds the head (the last
/// block) and the file size.
///
/// The superblock is entry id 0 of pair {0, 1}: a NAME tag of type 0xFF with
/// the magic `littlefs`, and an INLINESTRUCT with the format-time geometry:
///
/// ```
/// +-------+------+---------------------------------------------------------+
/// |   0   |    4 | disk version, major << 16 | minor (0x00020000, 0x00020001)|
/// |   4   |    4 | block size                                              |
/// |   8   |    4 | block count                                             |
/// |  12   |    4 | name max (0: littlefs default 255)                      |
/// |  16   |    4 | file max (0: 0x7FFFFFFF)                                |
/// |  20   |    4 | attr max (0: 1022)                                      |
/// +-------+------+---------------------------------------------------------+
/// ```
///
/// When the root directory is relocated the superblock entry is copied into
/// the new pair and the old one keeps only the superblock and a soft tail, so
/// the root is the *last* pair in the tail chain from {0, 1} that carries a
/// superblock. The tail chain threads every metadata pair; hard tails link the
/// pairs of one directory, soft tails link directories.
library;

import 'dart:typed_data';

/// Sizes and special values of the on-disk layout.
abstract final class LfsLayout {
  /// `LFS_BLOCK_NULL` — a null block pointer.
  static const int blockNull = 0xFFFFFFFF;

  /// The superblock NAME tag's data.
  static const String magic = 'littlefs';

  /// Offset of the magic within a block whose first tag is the superblock
  /// name: the revision count and the name tag precede it.
  static const int magicOffset = 8;

  /// Offset of the superblock struct in such a block: magic, then the
  /// INLINESTRUCT tag.
  static const int superblockOffset = 20;

  /// Size of the superblock INLINESTRUCT payload.
  static const int superblockSize = 24;

  static const int diskVersion20 = 0x00020000;
  static const int diskVersion21 = 0x00020001;

  /// Superblock limits are zero when the formatter left the littlefs default.
  static const int defaultNameMax = 255;
  static const int defaultFileMax = 0x7FFFFFFF;
  static const int defaultAttrMax = 1022;

  /// The smallest block that can hold a CTZ block's pointers and some data.
  static const int minBlockSize = 128;

  /// Block sizes worth probing when block 0 is the stale half of the
  /// superblock pair and only block 1 has a superblock. Ordered by how likely
  /// each is on an ESP partition, mirroring python idftool.
  static const List<int> candidateBlockSizes = [4096, 8192, 512, 256, 128, 1024, 2048, 16384, 32768, 65536];
}

/// Tag types, as `type3` values (type1 | chunk).
abstract final class LfsType {
  // type1 classes.
  static const int name = 0x000;
  static const int from = 0x100;
  static const int struct = 0x200;
  static const int userAttr = 0x300;
  static const int splice = 0x400;
  static const int crc = 0x500;
  static const int tail = 0x600;
  static const int globals = 0x700;

  // Concrete types.
  static const int reg = 0x001;
  static const int dir = 0x002;
  static const int superblock = 0x0FF;
  static const int dirStruct = 0x200;
  static const int inlineStruct = 0x201;
  static const int ctzStruct = 0x202;
  static const int create = 0x401;
  static const int delete = 0x4FF;
  static const int ccrc = 0x500;
  static const int fcrc = 0x5FF;
  static const int softTail = 0x600;
  static const int hardTail = 0x601;
  static const int moveState = 0x7FF;
}

/// Field accessors for a 32-bit tag, matching the `lfs_tag_*` inlines.
///
/// Tags are kept as non-negative ints below 2^32 and only ever combined with
/// 32-bit masks, so the same code runs under dart2js.
abstract final class LfsTag {
  static int make(int type, int id, int size) => ((type & 0x7FF) << 20) | ((id & 0x3FF) << 10) | (size & 0x3FF);

  static bool isValid(int tag) => tag & 0x80000000 == 0;

  /// The length field `0x3FF` flags a tag that removes its attribute; it
  /// carries no data.
  static bool isDelete(int tag) => tag & 0x3FF == 0x3FF;

  static int type1(int tag) => (tag >>> 20) & 0x700;

  /// type1 plus the top bit of the chunk: separates commit CRCs (`0x500`)
  /// from FCRCs (`0x5FF`).
  static int type2(int tag) => (tag >>> 20) & 0x780;

  static int type3(int tag) => (tag >>> 20) & 0x7FF;

  static int chunk(int tag) => (tag >>> 20) & 0xFF;

  /// The chunk of a SPLICE tag as a signed shift of the ids at and above
  /// [id].
  static int splice(int tag) {
    final c = chunk(tag);
    return c >= 0x80 ? c - 0x100 : c;
  }

  static int id(int tag) => (tag >>> 10) & 0x3FF;

  static int size(int tag) => tag & 0x3FF;

  /// Bytes the tag occupies on disk: the tag word plus its data.
  static int dsize(int tag) => 4 + (isDelete(tag) ? 0 : size(tag));
}

/// A metadata pair pointer: two block numbers. The order is the order the
/// pointer was written in; which block is current is decided by revision.
typedef LfsPair = (int, int);

/// `lfs_pair_isnull` — a pair with either block null ends a tail chain.
bool lfsPairIsNull(LfsPair pair) => pair.$1 == LfsLayout.blockNull || pair.$2 == LfsLayout.blockNull;

/// `lfs_pair_cmp` — pairs are the same pair if they share a block, since the
/// two blocks are listed in whichever order they were last written.
bool lfsPairSame(LfsPair a, LfsPair b) => a.$1 == b.$1 || a.$1 == b.$2 || a.$2 == b.$1 || a.$2 == b.$2;

String lfsPairString(LfsPair pair) => '{0x${pair.$1.toRadixString(16)}, 0x${pair.$2.toRadixString(16)}}';

/// `lfs_scmp` — compare revision counts as sequence numbers, so that a count
/// that wrapped past `0xFFFFFFFF` still compares as newer.
int lfsSeqCompare(int a, int b) {
  final diff = (a - b) & 0xFFFFFFFF;
  return diff >= 0x80000000 ? diff - 0x100000000 : diff;
}

/// `lfs_npw2` — the smallest `n` with `2^n >= a`.
int lfsNpw2(int a) {
  var r = 0;
  a -= 1;
  while (a > 0) {
    a >>>= 1;
    r++;
  }
  return r;
}

/// `lfs_ctz` — trailing zero bits of a non-zero value.
int lfsCtz(int a) {
  var r = 0;
  while (a & 1 == 0) {
    a >>>= 1;
    r++;
  }
  return r;
}

/// `lfs_popc` — set bits.
int lfsPopc(int a) {
  var r = 0;
  while (a != 0) {
    a &= a - 1;
    r++;
  }
  return r;
}

List<int>? _crcTable;

List<int> _buildCrcTable() {
  final table = List<int>.filled(256, 0);
  for (var i = 0; i < 256; i++) {
    var c = i;
    for (var k = 0; k < 8; k++) {
      c = c & 1 != 0 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
    }
    table[i] = c;
  }
  return table;
}

/// `lfs_crc` — continue a CRC-32 over `data[start:end]`.
///
/// Reflected `0x04C11DB7` with no final inversion, so the caller seeds it
/// with `0xFFFFFFFF` and the result is what littlefs stores on disk.
int lfsCrc(int crc, Uint8List data, [int start = 0, int? end]) {
  final table = _crcTable ??= _buildCrcTable();
  end ??= data.length;
  for (var i = start; i < end; i++) {
    crc = table[(crc ^ data[i]) & 0xFF] ^ (crc >>> 8);
  }
  return crc;
}

/// Base class for everything the littlefs reader throws.
class LittleFsException implements Exception {
  LittleFsException(this.message);
  final String message;

  @override
  String toString() => 'LittleFsException: $message';
}

/// The format-time geometry stored in the superblock.
class LittleFsGeometry {
  const LittleFsGeometry({
    required this.blockSize,
    required this.blockCount,
    required this.nameMax,
    required this.fileMax,
    required this.attrMax,
    required this.diskVersion,
  });

  final int blockSize;
  final int blockCount;

  /// Longest file name in bytes. Where the superblock stores zero this is the
  /// littlefs default, which is what the filesystem enforces.
  final int nameMax;

  /// Largest file in bytes (littlefs default where the superblock has zero).
  final int fileMax;

  /// Largest user attribute in bytes (littlefs default where the superblock
  /// has zero).
  final int attrMax;

  /// The on-disk version word: `major << 16 | minor`.
  final int diskVersion;

  int get versionMajor => (diskVersion >>> 16) & 0xFFFF;
  int get versionMinor => diskVersion & 0xFFFF;

  /// The version as littlefs prints it, e.g. `2.1`.
  String get versionString => '$versionMajor.$versionMinor';

  int get size => blockSize * blockCount;

  @override
  String toString() => 'littlefs $versionString, $blockCount blocks of 0x${blockSize.toRadixString(16)} bytes, '
      'name_max $nameMax, file_max $fileMax, attr_max $attrMax';
}

/// A file or directory in the volume.
class LittleFsEntry {
  const LittleFsEntry({required this.path, required this.isDir, required this.size});

  /// Path from the root, `/`-separated, without a leading `/`.
  final String path;
  final bool isDir;

  /// File size in bytes; zero for directories.
  final int size;

  String get name => path.substring(path.lastIndexOf('/') + 1);

  @override
  bool operator ==(Object other) =>
      other is LittleFsEntry && other.path == path && other.isDir == isDir && other.size == size;

  @override
  int get hashCode => Object.hash(path, isDir, size);

  @override
  String toString() => isDir ? '$path/' : '$path ($size bytes)';
}
