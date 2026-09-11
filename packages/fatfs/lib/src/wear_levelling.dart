/// ESP-IDF's wear levelling container (the `wear_levelling` component).
///
/// A FAT partition in SPI flash is almost always mounted through the wear
/// levelling layer (`esp_vfs_fat_spiflash_mount_rw_wl`), which spends a few
/// sectors of the partition on its own bookkeeping and shifts the filesystem
/// by one "dummy" sector. The filesystem therefore does not start at offset 0
/// of the partition, and on a device that has been written to it is not even
/// contiguous: the dummy sector migrates through the partition and, once it
/// wraps, the whole filesystem is rotated by a whole number of sectors.
///
/// The layout mirrors ESP-IDF's `wl_fatfsgen.py`:
///
/// ```
/// [dummy][filesystem ...][state copy 1][state copy 2][config]
/// ```
///
/// Every sector is 4 KiB regardless of the sector size the filesystem inside
/// is formatted with. A state copy is [WlLayout.stateSectorsFor] sectors long:
///
/// ```
/// +-------+------+-------------------------------------------------------+
/// | 0x00  |    4 | pos — dummy sector position, rewritten on wrap-around |
/// | 0x04  |    4 | max_pos — sectors the dummy can move through          |
/// | 0x08  |    4 | move_count — full rotations of the filesystem         |
/// | 0x0C  |    4 | access_count                                          |
/// | 0x10  |    4 | max_count (the update rate)                           |
/// | 0x14  |    4 | block_size                                            |
/// | 0x18  |    4 | version                                               |
/// | 0x1C  |    4 | device_id                                             |
/// | 0x20  |   28 | reserved                                              |
/// | 0x3C  |    4 | CRC32 of bytes [0:60]                                 |
/// | 0x40  | 16×N | one record per sector, written as the dummy advances  |
/// +-------+------+-------------------------------------------------------+
/// ```
///
/// The driver recovers the dummy sector's position after a power loss from
/// the records rather than from `pos`, which is only rewritten when the dummy
/// wraps: the number of non-erased records *is* the position. The record
/// area scales with the partition, so the overhead is not a fixed 4 sectors —
/// a 1 MiB partition already needs two sectors per state copy, six in total.
///
/// The config sector, last in the partition, is what identifies a container:
///
/// ```
/// +-------+------+-------------------------------------------------------+
/// | 0x00  |    4 | start_addr — 0, relative to the partition             |
/// | 0x04  |    4 | full_mem_size — the partition size                    |
/// | 0x08  |    4 | page_size (4096)                                      |
/// | 0x0C  |    4 | sector_size (4096)                                    |
/// | 0x10  |    4 | updaterate                                            |
/// | 0x14  |    4 | wr_size                                               |
/// | 0x18  |    4 | version                                               |
/// | 0x1C  |    4 | temp_buff_size                                        |
/// | 0x20  |    4 | CRC32 of bytes [0:32]                                 |
/// | 0x24  |   12 | padding                                               |
/// +-------+------+-------------------------------------------------------+
/// ```
library;

import 'dart:math';
import 'dart:typed_data';

import 'crc32.dart';

/// Sizes and offsets of the wear levelling layout.
abstract final class WlLayout {
  /// The driver's page/sector size is fixed at 4 KiB for every NOR flash
  /// ESP-IDF supports, independent of the filesystem's sector size.
  static const int sectorSize = 0x1000;

  static const int stateHeaderSize = 64;
  static const int stateRecordSize = 16;

  /// Two copies of the state, for power-failure safety.
  static const int stateCopyCount = 2;
  static const int configHeaderSize = 48;
  static const int dummySectors = 1;
  static const int configSectors = 1;

  /// Defaults from ESP-IDF's `FATDefaults`; [version] is the `wl_state_t` /
  /// `wl_config_t` layout version.
  static const int version = 2;
  static const int updateRate = 16;
  static const int wrSize = 16;
  static const int tempBufferSize = 32;

  /// Bytes of a state header covered by its CRC (everything before it).
  static const int stateCrcOffset = 60;

  /// Bytes of the config header covered by its CRC (the eight words).
  static const int configCrcOffset = 32;

  static const int erased = 0xFF;

  /// Sectors taken by one copy of the wear levelling state.
  static int stateSectorsFor(int partitionSize) {
    final totalSectors = partitionSize ~/ sectorSize;
    final stateSize = stateHeaderSize + stateRecordSize * totalSectors;
    return (stateSize + sectorSize - 1) ~/ sectorSize;
  }

  /// Sectors of a partition that wear levelling keeps for itself.
  static int overheadSectorsFor(int partitionSize) =>
      dummySectors + configSectors + stateCopyCount * stateSectorsFor(partitionSize);
}

/// A wear levelling container could not be built or unwrapped.
class WearLevellingException implements Exception {
  WearLevellingException(this.message);
  final String message;
  @override
  String toString() => 'WearLevellingException: $message';
}

String _hex(int value) => '0x${value.toRadixString(16)}';

/// Bytes left for the filesystem inside a wear-levelled partition of
/// [partitionSize] bytes.
int wlFilesystemSize(int partitionSize) {
  if (partitionSize % WlLayout.sectorSize != 0) {
    throw WearLevellingException('Partition size ${_hex(partitionSize)} is not a multiple of the wear levelling '
        'sector size ${_hex(WlLayout.sectorSize)}');
  }
  final overhead = WlLayout.overheadSectorsFor(partitionSize) * WlLayout.sectorSize;
  final size = partitionSize - overhead;
  if (size <= 0) {
    throw WearLevellingException('Partition size ${_hex(partitionSize)} is too small for wear levelling '
        '(needs more than ${_hex(overhead)} bytes of overhead)');
  }
  return size;
}

/// Wrap a filesystem image in a freshly-initialised wear levelling container
/// that fills a [partitionSize]-byte partition.
///
/// [deviceId] is stored as-is and lets the driver notice that it is looking at
/// a different chip; ESP-IDF randomises it, so pass a fixed value for
/// reproducible builds.
Uint8List wlWrap(Uint8List filesystem, int partitionSize, {int? deviceId}) {
  final fsSize = wlFilesystemSize(partitionSize);
  if (filesystem.length > fsSize) {
    throw WearLevellingException('Filesystem image size ${_hex(filesystem.length)} exceeds the ${_hex(fsSize)} bytes '
        'available inside a wear-levelled partition of ${_hex(partitionSize)} bytes');
  }
  deviceId ??= Random.secure().nextInt(0x100000000);

  final image = Uint8List(partitionSize)..fillRange(0, partitionSize, WlLayout.erased);
  // The dummy sector is still at the front, so the filesystem starts one sector in.
  image.setRange(WlLayout.sectorSize, WlLayout.sectorSize + filesystem.length, filesystem);

  final state = Uint8List(WlLayout.stateHeaderSize);
  ByteData.sublistView(state)
    ..setUint32(0, 0, Endian.little) // pos — the dummy sector is still at the front
    ..setUint32(4, fsSize ~/ WlLayout.sectorSize + WlLayout.dummySectors, Endian.little) // max_pos
    ..setUint32(8, 0, Endian.little) // move_count
    ..setUint32(12, 0, Endian.little) // access_count
    ..setUint32(16, WlLayout.updateRate, Endian.little) // max_count
    ..setUint32(20, WlLayout.sectorSize, Endian.little) // block_size
    ..setUint32(24, WlLayout.version, Endian.little)
    ..setUint32(28, deviceId, Endian.little)
    ..setUint32(
        WlLayout.stateCrcOffset, wlCrc32(Uint8List.sublistView(state, 0, WlLayout.stateCrcOffset)), Endian.little);
  // Records stay erased: no sector has been moved yet, so the recovered position is 0.
  final copySize = WlLayout.stateSectorsFor(partitionSize) * WlLayout.sectorSize;
  final statesStart = partitionSize - WlLayout.configSectors * WlLayout.sectorSize - WlLayout.stateCopyCount * copySize;
  for (var copy = 0; copy < WlLayout.stateCopyCount; copy++) {
    image.setAll(statesStart + copy * copySize, state);
  }

  final config = Uint8List(WlLayout.configHeaderSize);
  ByteData.sublistView(config)
    ..setUint32(0, 0, Endian.little) // start_addr, relative to the partition
    ..setUint32(4, partitionSize, Endian.little) // full_mem_size
    ..setUint32(8, WlLayout.sectorSize, Endian.little) // page_size
    ..setUint32(12, WlLayout.sectorSize, Endian.little) // sector_size
    ..setUint32(16, WlLayout.updateRate, Endian.little)
    ..setUint32(20, WlLayout.wrSize, Endian.little)
    ..setUint32(24, WlLayout.version, Endian.little)
    ..setUint32(28, WlLayout.tempBufferSize, Endian.little)
    ..setUint32(
        WlLayout.configCrcOffset, wlCrc32(Uint8List.sublistView(config, 0, WlLayout.configCrcOffset)), Endian.little);
  // The CRC is followed by three zero padding words that align wl_config_t to 48 bytes.
  image.setAll(partitionSize - WlLayout.sectorSize, config);
  return image;
}

/// `(pos, moveCount)` from whichever state copy is valid.
(int, int) _parseState(Uint8List image, int partitionSize) {
  final copySize = WlLayout.stateSectorsFor(partitionSize) * WlLayout.sectorSize;
  final statesStart = partitionSize - WlLayout.configSectors * WlLayout.sectorSize - WlLayout.stateCopyCount * copySize;

  for (var copy = 0; copy < WlLayout.stateCopyCount; copy++) {
    final start = statesStart + copy * copySize;
    if (start < 0 || start + WlLayout.stateHeaderSize > image.length) continue;
    final header = Uint8List.sublistView(image, start, start + WlLayout.stateHeaderSize);
    final view = ByteData.sublistView(header);
    final storedCrc = view.getUint32(WlLayout.stateCrcOffset, Endian.little);
    if (storedCrc != wlCrc32(Uint8List.sublistView(header, 0, WlLayout.stateCrcOffset))) continue;
    final moveCount = view.getUint32(8, Endian.little);

    // The header's `pos` is only rewritten when the dummy sector wraps around; between
    // wraps the driver appends one record per move, so the record count is authoritative.
    var pos = 0;
    for (var offset = start + WlLayout.stateHeaderSize; offset < start + copySize; offset += WlLayout.stateRecordSize) {
      var blank = true;
      for (var i = 0; i < WlLayout.stateRecordSize; i++) {
        if (image[offset + i] != WlLayout.erased) {
          blank = false;
          break;
        }
      }
      if (blank) break;
      pos++;
    }
    return (pos, moveCount);
  }

  throw WearLevellingException('No valid wear levelling state sector found (both copies failed CRC)');
}

/// Recover the filesystem image from a wear levelling container.
///
/// Undoes both transformations the driver applies: the dummy sector is cut out
/// of wherever it has migrated to, and the remainder is rotated back by
/// `move_count` sectors so the filesystem starts where the filesystem thinks
/// it does.
Uint8List wlUnwrap(Uint8List partitionImage) {
  final partitionSize = partitionImage.length;
  final fsSize = wlFilesystemSize(partitionSize);
  final (pos, moveCount) = _parseState(partitionImage, partitionSize);

  final dummy = pos * WlLayout.sectorSize;
  final withoutDummy = Uint8List(partitionSize - WlLayout.sectorSize);
  if (dummy > withoutDummy.length) {
    throw WearLevellingException('Wear levelling state places the dummy sector at $pos, past the end of the partition');
  }
  withoutDummy.setRange(0, dummy, partitionImage);
  withoutDummy.setRange(dummy, withoutDummy.length, partitionImage, dummy + WlLayout.sectorSize);

  final rotation = (moveCount * WlLayout.sectorSize) % fsSize;
  final filesystem = Uint8List(fsSize);
  // The last `rotation` bytes move to the front.
  filesystem.setRange(0, rotation, withoutDummy, fsSize - rotation);
  filesystem.setRange(rotation, fsSize, withoutDummy);
  return filesystem;
}

/// Whether [image] is a wear levelling container.
///
/// Identified by the config sector at the very end of the partition: its CRC
/// has to check out *and* its recorded size has to match the image we were
/// handed, which no bare filesystem image would manage by accident.
bool looksLikeWl(Uint8List image) {
  if (image.length < 2 * WlLayout.sectorSize || image.length % WlLayout.sectorSize != 0) return false;
  final start = image.length - WlLayout.sectorSize;
  final config = Uint8List.sublistView(image, start, start + WlLayout.configHeaderSize);
  final view = ByteData.sublistView(config);
  final storedCrc = view.getUint32(WlLayout.configCrcOffset, Endian.little);
  if (storedCrc != wlCrc32(Uint8List.sublistView(config, 0, WlLayout.configCrcOffset))) return false;
  final fullMemSize = view.getUint32(4, Endian.little);
  final pageSize = view.getUint32(8, Endian.little);
  final sectorSize = view.getUint32(12, Endian.little);
  return fullMemSize == image.length && pageSize == WlLayout.sectorSize && sectorSize == WlLayout.sectorSize;
}
