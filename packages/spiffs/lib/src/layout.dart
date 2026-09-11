/// The SPIFFS on-flash layout, and the types shared by the reader and the
/// image builder.
///
/// A SPIFFS volume is a run of equally sized *blocks* (the flash erase unit,
/// 4 KiB on ESP chips), each divided into *pages* (256 bytes by default). The
/// first page(s) of every block form its *object lookup table*: one 16-bit
/// object id per remaining page of the block, so the filesystem can find every
/// page belonging to an object without reading the pages themselves.
///
/// ```
/// block (4096 bytes, 16 pages)
/// +--------+----------------------------------------------------------------+
/// | page 0 | object lookup: obj id of page 1, of page 2, ... 0xFFFF = free   |
/// |        | (second-to-last slot of the last lookup page holds the magic)  |
/// | page 1 | index or data page                                             |
/// |  ...   |                                                                |
/// | page 15| index or data page                                             |
/// +--------+----------------------------------------------------------------+
/// ```
///
/// Every non-lookup page starts with the same 5-byte header. An id with its
/// top bit set (`0x8000`) marks an *object index* page; a data page carries
/// the plain id.
///
/// ```
/// +-------+------+---------------------------------------------------------+
/// |   0   |    2 | object id (| 0x8000 for an index page)                  |
/// |   2   |    2 | span index — position of this page within the object    |
/// |   4   |    1 | flags, active low: bit 0 used, bit 1 final, bit 2 index,|
/// |       |      | bit 7 deleted. A live data page reads 0xFC, index 0xF8  |
/// +-------+------+---------------------------------------------------------+
/// ```
///
/// A data page is followed straight away by content (251 bytes with 256-byte
/// pages). An index page pads the header to 4 bytes, then — on span 0 only —
/// carries the object header, and finally a table of the absolute page
/// indexes of the object's data pages, in span order, `0xFFFF` where unused:
///
/// ```
/// +-------+------+---------------------------------------------------------+
/// |   0   |    5 | page header                                             |
/// |   5   |    3 | padding (0xFF)                                          |
/// |   8   |    4 | size in bytes (0xFFFFFFFF while a file is being written)|  span 0 only
/// |  12   |    1 | type: 1 file, 2 dir, 3 hard link, 4 soft link           |  span 0 only
/// |  13   |   32 | name, NUL-padded (objNameLen)                           |  span 0 only
/// |  45   |    4 | metadata (metaLen)                                      |  span 0 only
/// |  49   |    - | data page indexes, uint16 each: 103 fit on span 0, 124  |
/// |       |      | on every later index page                               |
/// +-------+------+---------------------------------------------------------+
/// ```
///
/// Flash bits only go 1→0, so nothing is ever rewritten in place: a changed
/// page is written anew and the old one has its *deleted* flag cleared (and
/// its lookup slot zeroed). Reading therefore means walking the lookup tables
/// and keeping only pages whose flags say used, final and not deleted.
///
/// With `CONFIG_SPIFFS_USE_MAGIC` (the ESP-IDF default) each block also gets a
/// magic value, derived from the page size and — with
/// `CONFIG_SPIFFS_USE_MAGIC_LENGTH` — the block's distance from the end of the
/// volume, stored in the second-to-last slot of its last lookup page. That is
/// what lets an image be recognised as SPIFFS at all.
library;

/// Page header flags. They are active low: a cleared bit means the property
/// holds.
abstract final class SpiffsFlags {
  static const int used = 0x01;
  static const int finalized = 0x02;
  static const int index = 0x04;
  static const int deleted = 0x80;

  /// The flags a live index page carries: used, final and index cleared.
  static const int liveIndex = 0xF8;

  /// The flags a live data page carries: used and final cleared.
  static const int liveData = 0xFC;

  /// Whether the flags describe a page the filesystem still considers valid.
  static bool isLive(int flags) =>
      flags & used == 0 && flags & finalized == 0 && flags & deleted != 0;
}

/// Object type stored in an index header. Only [file] is ever produced by
/// ESP-IDF; the others exist in the SPIFFS format but are unused.
enum SpiffsObjType {
  file(1),
  dir(2),
  hardLink(3),
  softLink(4);

  const SpiffsObjType(this.value);
  final int value;
}

/// The geometry and compile-time options of a SPIFFS volume — the `CONFIG_SPIFFS_*`
/// settings of the firmware the image is meant for. The defaults are ESP-IDF's.
///
/// Reading and writing both need the same values: nothing in an image records
/// its page size or name length, so a mismatch shows up as garbage rather than
/// an error.
class SpiffsConfig {
  const SpiffsConfig({
    this.pageSize = 256,
    this.blockSize = 4096,
    this.objNameLen = 32,
    this.metaLen = 4,
    this.useMagic = true,
    this.useMagicLen = true,
    this.alignedObjIxTables = false,
  });

  /// ESP-IDF's defaults.
  static const SpiffsConfig defaults = SpiffsConfig();

  /// `CONFIG_SPIFFS_PAGE_SIZE`; must be a power of two.
  final int pageSize;

  /// The flash sector size, always 4 KiB on ESP chips.
  final int blockSize;

  /// `CONFIG_SPIFFS_OBJ_NAME_LEN` — the name field width, including the
  /// leading `/` and (if there's room) the NUL terminator.
  final int objNameLen;

  /// `CONFIG_SPIFFS_META_LENGTH` — bytes of per-object metadata after the name.
  final int metaLen;

  /// `CONFIG_SPIFFS_USE_MAGIC` — stamp each block with a magic value.
  final bool useMagic;

  /// `CONFIG_SPIFFS_USE_MAGIC_LENGTH` — fold the block's position into the magic.
  final bool useMagicLen;

  /// `CONFIG_SPIFFS_ALIGNED_OBJECT_INDEX_TABLES` — pad the head index page's
  /// header so the page table starts 2-byte aligned.
  final bool alignedObjIxTables;

  /// Page sizes worth probing when identifying an image of unknown configuration.
  static const List<int> candidatePageSizes = [256, 128, 512, 1024, 2048];

  /// Width of an object id, span index and page index (`spiffs_obj_id`,
  /// `spiffs_span_ix`, `spiffs_page_ix`): all 16 bits in ESP-IDF's build.
  static const int objIdLen = 2;
  static const int spanIxLen = 2;
  static const int pageIxLen = 2;

  /// Object ids `0` (deleted) and `0xFFFF` (free) are reserved, and the top bit
  /// flags index pages, so files get ids in `1..0x7FFF`.
  static const int objIdFree = 0xFFFF;
  static const int objIdDeleted = 0x0000;
  static const int objIdIndexFlag = 0x8000;
  static const int maxObjId = 0x7FFF;

  /// An unused page-table entry.
  static const int pageIxFree = 0xFFFF;

  /// The size an index header carries until the file is closed.
  static const int undefinedSize = 0xFFFFFFFF;

  /// The 5-byte page header, and its 4-byte-aligned length as an index page pads it.
  static const int dataHeaderLen = objIdLen + spanIxLen + 1;
  static const int dataHeaderLenAligned = 8;

  int get pagesPerBlock => blockSize ~/ pageSize;

  /// Lookup pages per block: enough to hold one object id per page.
  int get lookupPagesPerBlock => (pagesPerBlock * objIdLen + pageSize - 1) ~/ pageSize;

  int get usablePagesPerBlock => pagesPerBlock - lookupPagesPerBlock;

  /// Bytes of file content a data page holds.
  int get dataContentLen => pageSize - dataHeaderLen;

  /// Object header on a span-0 index page: size, type, name, metadata.
  int get indexHeaderLen => dataHeaderLenAligned + 4 + 1 + objNameLen + metaLen;

  /// Where the page table starts on a span-0 index page.
  int get headTableOffset => alignedObjIxTables ? (indexHeaderLen + pageIxLen - 1) & ~(pageIxLen - 1) : indexHeaderLen;

  /// Page-table entries on a span-0 index page, and on every later one.
  int get headTableEntries => (pageSize - headTableOffset) ~/ pageIxLen;
  int get tableEntries => (pageSize - dataHeaderLenAligned) ~/ pageIxLen;

  /// Byte offset, within a block, of the magic slot: the second-to-last object
  /// id of the last lookup page.
  int get magicOffset => lookupPagesPerBlock * pageSize - 2 * objIdLen;

  /// The magic value block [block] of a [blockCount]-block volume carries,
  /// mirroring the `SPIFFS_MAGIC` macro in `spiffs_nucleus.h`. Truncated to an
  /// object id's 16 bits.
  int magic(int blockCount, int block) {
    var magic = 0x20140529 ^ pageSize;
    if (useMagicLen) magic ^= blockCount - block;
    return magic & 0xFFFF;
  }

  /// Which index page (by span) and which slot within it holds the page table
  /// entry for data span [dataSpan].
  (int indexSpan, int slot) tableSlot(int dataSpan) {
    if (dataSpan < headTableEntries) return (0, dataSpan);
    final rest = dataSpan - headTableEntries;
    return (1 + rest ~/ tableEntries, rest % tableEntries);
  }

  /// Throws [SpiffsException] if the geometry cannot describe a volume.
  void validate() {
    if (pageSize <= 0 || pageSize & (pageSize - 1) != 0) {
      throw SpiffsException('SPIFFS page size $pageSize is not a power of two');
    }
    if (blockSize <= 0 || blockSize % pageSize != 0) {
      throw SpiffsException('SPIFFS block size $blockSize is not a multiple of the page size $pageSize');
    }
    if (objNameLen <= 1 || metaLen < 0) {
      throw SpiffsException('SPIFFS name length $objNameLen / metadata length $metaLen is out of range');
    }
    if (usablePagesPerBlock < 1 || headTableEntries < 1) {
      throw SpiffsException('SPIFFS pages of $pageSize bytes are too small for this configuration');
    }
  }

  SpiffsConfig copyWith({
    int? pageSize,
    int? blockSize,
    int? objNameLen,
    int? metaLen,
    bool? useMagic,
    bool? useMagicLen,
    bool? alignedObjIxTables,
  }) =>
      SpiffsConfig(
        pageSize: pageSize ?? this.pageSize,
        blockSize: blockSize ?? this.blockSize,
        objNameLen: objNameLen ?? this.objNameLen,
        metaLen: metaLen ?? this.metaLen,
        useMagic: useMagic ?? this.useMagic,
        useMagicLen: useMagicLen ?? this.useMagicLen,
        alignedObjIxTables: alignedObjIxTables ?? this.alignedObjIxTables,
      );

  /// A one-line summary in the style of the python CLI's `describe`.
  String describe(int size) =>
      'SPIFFS, ${size ~/ blockSize} blocks of 0x${blockSize.toRadixString(16)} bytes, '
      '0x${pageSize.toRadixString(16)}-byte pages, name limit $objNameLen';

  @override
  String toString() => 'SpiffsConfig(pageSize: $pageSize, blockSize: $blockSize, objNameLen: $objNameLen, '
      'metaLen: $metaLen, useMagic: $useMagic, useMagicLen: $useMagicLen, alignedObjIxTables: $alignedObjIxTables)';
}

/// A SPIFFS image could not be parsed, read, or built.
class SpiffsException implements Exception {
  SpiffsException(this.message);
  final String message;
  @override
  String toString() => 'SpiffsException: $message';
}
