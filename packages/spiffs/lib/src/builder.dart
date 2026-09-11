/// Building a SPIFFS image, byte for byte what ESP-IDF's `spiffsgen.py` (and
/// so `spiffs_create_partition_image()`) produces.
///
/// The generator's allocation is simpler than its class structure suggests:
/// usable pages are handed out strictly in order — block by block, skipping
/// each block's lookup pages — and every file takes its head index page, then
/// its data pages, with a further index page slipped in whenever the current
/// one's table fills up. Object ids count up from 1 in the order files are
/// added. That is what [spiffsCreate] does directly, without modelling blocks
/// and pages as objects.
///
/// Blocks past the last used one are erased flash (`0xFF`) apart from their
/// magic; with magic disabled the whole tail is `0xFF`.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'layout.dart';

/// A file to put in an image: [path] without a leading `/` (one is added, as
/// ESP-IDF does) and its [bytes].
typedef SpiffsSource = ({String path, Uint8List bytes});

/// Build a SPIFFS image of exactly [size] bytes holding [sources], in order.
///
/// ESP-IDF's tooling adds files in directory-walk order (parents first, names
/// sorted within a level); pass them that way for an identical image. SPIFFS
/// is flat, so a directory is nothing but the `/` inside a name.
///
/// Throws [SpiffsException] if [size] is not a multiple of the block size, a
/// name does not fit `objNameLen`, or the files do not fit.
Uint8List spiffsCreate(List<SpiffsSource> sources, int size, {SpiffsConfig config = SpiffsConfig.defaults}) {
  config.validate();
  if (size <= 0 || size % config.blockSize != 0) {
    throw SpiffsException('Filesystem size 0x${size.toRadixString(16)} is not a multiple of the block size '
        '0x${config.blockSize.toRadixString(16)}');
  }
  if (size ~/ config.pageSize > SpiffsConfig.pageIxFree) {
    throw SpiffsException('A 0x${size.toRadixString(16)}-byte image has more pages than a 16-bit page index can '
        'address');
  }

  final builder = _ImageBuilder(size, config);
  for (final source in sources) {
    final name = '/${source.path}';
    final nameBytes = utf8.encode(name);
    if (nameBytes.length > config.objNameLen) {
      throw SpiffsException("Name '$name' is ${nameBytes.length} bytes, over the SPIFFS limit of "
          '${config.objNameLen} (SPIFFS is flat, so the whole path counts); raise objNameLen to match '
          'CONFIG_SPIFFS_OBJ_NAME_LEN on the device');
    }
    if (!builder.addFile(nameBytes, source.bytes)) {
      throw SpiffsException('Sources do not fit in a 0x${size.toRadixString(16)}-byte SPIFFS image');
    }
  }
  return builder.finish();
}

class _ImageBuilder {
  _ImageBuilder(int size, this.config)
      : image = Uint8List(size)..fillRange(0, size, 0xFF),
        blockCount = size ~/ config.blockSize {
    view = ByteData.sublistView(image);
  }

  final SpiffsConfig config;
  final Uint8List image;
  late final ByteData view;
  final int blockCount;

  /// Pages handed out so far, counting only usable (non-lookup) pages.
  int _allocated = 0;
  int _nextObjId = 1;

  /// Claim the next usable page, or `null` when the image is full. Returns its
  /// absolute page index, having recorded [luObjId] in the block's lookup table.
  int? _allocate(int luObjId) {
    final block = _allocated ~/ config.usablePagesPerBlock;
    if (block >= blockCount) return null;
    final slot = _allocated % config.usablePagesPerBlock;
    _allocated++;
    view.setUint16(block * config.blockSize + slot * SpiffsConfig.objIdLen, luObjId, Endian.little);
    return block * config.pagesPerBlock + config.lookupPagesPerBlock + slot;
  }

  /// Lay out one file. Returns false if the image ran out of pages.
  bool addFile(List<int> name, Uint8List contents) {
    final objId = _nextObjId;
    if (objId > SpiffsConfig.maxObjId) {
      throw SpiffsException('Too many files: SPIFFS object ids run out at ${SpiffsConfig.maxObjId}');
    }

    var indexSpan = 0;
    var indexPage = _allocate(objId | SpiffsConfig.objIdIndexFlag);
    if (indexPage == null) return false;
    _writeIndexHeader(indexPage, objId, 0, name, contents.length);
    var tableOffset = indexPage * config.pageSize + config.headTableOffset;
    var tableLeft = config.headTableEntries;

    final contentLen = config.dataContentLen;
    var dataSpan = 0;
    for (var offset = 0; offset < contents.length; offset += contentLen) {
      if (tableLeft == 0) {
        // The index page's table is full: continue it on a fresh index page.
        indexSpan++;
        indexPage = _allocate(objId | SpiffsConfig.objIdIndexFlag);
        if (indexPage == null) return false;
        _writeIndexHeader(indexPage, objId, indexSpan, name, contents.length);
        tableOffset = indexPage * config.pageSize + SpiffsConfig.dataHeaderLenAligned;
        tableLeft = config.tableEntries;
      }

      final page = _allocate(objId);
      if (page == null) return false;
      final base = page * config.pageSize;
      view.setUint16(base, objId, Endian.little);
      view.setUint16(base + 2, dataSpan, Endian.little);
      image[base + 4] = SpiffsFlags.liveData;
      final end = (offset + contentLen).clamp(0, contents.length);
      image.setRange(base + SpiffsConfig.dataHeaderLen, base + SpiffsConfig.dataHeaderLen + end - offset, contents,
          offset);

      view.setUint16(tableOffset, page, Endian.little);
      tableOffset += SpiffsConfig.pageIxLen;
      tableLeft--;
      dataSpan++;
    }

    _nextObjId++;
    return true;
  }

  void _writeIndexHeader(int page, int objId, int span, List<int> name, int size) {
    final base = page * config.pageSize;
    view.setUint16(base, objId | SpiffsConfig.objIdIndexFlag, Endian.little);
    view.setUint16(base + 2, span, Endian.little);
    image[base + 4] = SpiffsFlags.liveIndex;
    // Bytes 5..8 stay 0xFF: the header is padded to 4 bytes with erased flash.
    if (span != 0) return;

    final header = base + SpiffsConfig.dataHeaderLenAligned;
    view.setUint32(header, size, Endian.little);
    image[header + 4] = SpiffsObjType.file.value;
    // Name, metadata and any alignment padding are all zero-filled by the generator.
    image.fillRange(header + 5, base + config.headTableOffset, 0);
    image.setRange(header + 5, header + 5 + name.length, name);
  }

  /// Stamp the magic into every block and return the image.
  Uint8List finish() {
    if (config.useMagic) {
      for (var block = 0; block < blockCount; block++) {
        view.setUint16(block * config.blockSize + config.magicOffset, config.magic(blockCount, block), Endian.little);
      }
    }
    return image;
  }
}
