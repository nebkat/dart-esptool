/// The geometry of a FAT volume: reading it out of a boot sector, and
/// choosing it for a new image the way idftool's `_geometry` does.
library;

import 'dart:typed_data';

import 'common.dart';

/// The layout of a volume as its boot sector describes it.
class FatGeometry {
  FatGeometry({
    required this.bits,
    required this.sectorSize,
    required this.sectorsPerCluster,
    required this.reservedSectors,
    required this.fatCount,
    required this.fatSectors,
    required this.rootEntries,
    required this.totalSectors,
    required this.clusterCount,
    this.rootCluster,
    this.volumeId = 0,
    this.label = '',
    this.oemName = '',
  });

  /// The FAT width: 12, 16 or 32.
  final FatBits bits;
  final int sectorSize;
  final int sectorsPerCluster;
  final int reservedSectors;
  final int fatCount;

  /// Sectors per FAT copy.
  final int fatSectors;

  /// Entries in the fixed root directory (0 on FAT32).
  final int rootEntries;
  final int totalSectors;

  /// Data clusters, numbered from 2.
  final int clusterCount;

  /// The root directory's first cluster on FAT32; `null` on FAT12/16, whose
  /// root directory is a fixed area before the data clusters.
  final int? rootCluster;
  final int volumeId;
  final String label;
  final String oemName;

  int get bytesPerCluster => sectorSize * sectorsPerCluster;
  int get rootDirSectors => (rootEntries * FatLayout.dirEntrySize + sectorSize - 1) ~/ sectorSize;
  int get rootDirSector => reservedSectors + fatCount * fatSectors;
  int get firstDataSector => rootDirSector + rootDirSectors;
  int get size => totalSectors * sectorSize;

  /// Byte offset of FAT copy [index].
  int fatOffset(int index) => (reservedSectors + index * fatSectors) * sectorSize;
  int get fatBytes => fatSectors * sectorSize;
  int get rootDirOffset => rootDirSector * sectorSize;
  int get rootDirBytes => rootDirSectors * sectorSize;

  /// Byte offset of a data [cluster].
  int clusterOffset(int cluster) =>
      ((cluster - FatLayout.firstCluster) * sectorsPerCluster + firstDataSector) * sectorSize;

  /// Whether [cluster] numbers a data cluster of this volume.
  bool isValidCluster(int cluster) =>
      cluster >= FatLayout.firstCluster && cluster < clusterCount + FatLayout.firstCluster;

  /// One-line summary in the style of idftool's `describe`.
  @override
  String toString() => 'FAT${bits.bits}, $clusterCount clusters of ${hex(bytesPerCluster)} bytes';
}

/// Whether [image] starts with a plausible FAT boot sector (signature word
/// plus a sane BPB). Does not look through wear levelling — see
/// `FatVolume.detect` for that.
bool looksLikeFatBootSector(Uint8List image) {
  if (image.length < 512 || image[510] != 0x55 || image[511] != 0xAA) return false;
  final view = ByteData.sublistView(image);
  final bytesPerSector = view.getUint16(11, Endian.little);
  final sectorsPerCluster = image[13];
  if (!const [512, 1024, 2048, 4096].contains(bytesPerSector) || sectorsPerCluster == 0) return false;
  if (sectorsPerCluster & (sectorsPerCluster - 1) != 0) return false; // must be a power of two
  final reserved = view.getUint16(14, Endian.little);
  final fatCount = image[16];
  return reserved > 0 && (fatCount == 1 || fatCount == 2) && image[21] >= 0xF0;
}

/// Read the geometry out of [image]'s boot sector.
///
/// Throws [FatException] if it is not one. The checks mirror pyfatfs's
/// `parse_header`, so an image that mounts there mounts here.
FatGeometry parseBootSector(Uint8List image) {
  if (image.length < 512) throw FatException('Image is ${image.length} bytes, too short for a boot sector');
  final view = ByteData.sublistView(image);
  if (image[510] != 0x55 || image[511] != 0xAA) {
    throw FatException('Invalid boot sector signature ${hex(view.getUint16(510, Endian.little))}');
  }
  if (image[0] == 0xEB) {
    if (image[2] != 0x90) throw FatException('Boot code must end with 0x90');
  } else if (image[0] != 0xE9) {
    throw FatException('Boot code must start with 0xEB or 0xE9. Is this a FAT partition?');
  }

  final sectorSize = view.getUint16(11, Endian.little);
  if (!const [512, 1024, 2048, 4096].contains(sectorSize)) throw FatException('Unsupported sector size $sectorSize');
  final sectorsPerCluster = image[13];
  if (sectorsPerCluster == 0 || sectorsPerCluster > 128 || sectorsPerCluster & (sectorsPerCluster - 1) != 0) {
    throw FatException('Unsupported sectors per cluster $sectorsPerCluster');
  }
  final reservedSectors = view.getUint16(14, Endian.little);
  if (reservedSectors == 0) throw FatException('Number of reserved sectors must not be 0');
  final fatCount = image[16];
  if (fatCount < 1) throw FatException('At least one FAT expected, none found');
  final rootEntries = view.getUint16(17, Endian.little);
  if (rootEntries * FatLayout.dirEntrySize % sectorSize != 0) {
    throw FatException('Root entry count $rootEntries does not cleanly align with bytes per sector');
  }
  if (image[21] < 0xF0) throw FatException('Invalid media type ${hex(image[21])}');
  final totalSectors16 = view.getUint16(19, Endian.little);
  final totalSectors = totalSectors16 != 0 ? totalSectors16 : view.getUint32(32, Endian.little);
  if (totalSectors == 0) throw FatException('16-bit and 32-bit total sector count both empty');
  final fatSectors16 = view.getUint16(22, Endian.little);
  final isFat32Bpb = fatSectors16 == 0;
  final fatSectors = isFat32Bpb ? view.getUint32(36, Endian.little) : fatSectors16;
  if (fatSectors == 0) throw FatException('Invalid FAT size of 0 in header');

  final rootDirSectors = (rootEntries * FatLayout.dirEntrySize + sectorSize - 1) ~/ sectorSize;
  final dataSectors = totalSectors - (reservedSectors + fatCount * fatSectors + rootDirSectors);
  if (dataSectors <= 0) throw FatException('Boot sector leaves no room for data clusters');
  final clusterCount = dataSectors ~/ sectorsPerCluster;

  // Like pyfatfs (and Linux): a FAT32-style BPB is FAT32, otherwise the cluster
  // count decides between 12 and 16.
  final bits = isFat32Bpb ? FatBits.fat32 : FatBits.forClusterCount(clusterCount);
  if (bits == FatBits.fat32 && !isFat32Bpb) {
    throw FatException('$clusterCount clusters need FAT32 but the boot sector has a FAT12/16 BPB');
  }

  final ext = bits == FatBits.fat32 ? 64 : 36;
  final hasExtended = image[ext + 2] == 0x29;
  return FatGeometry(
    bits: bits,
    sectorSize: sectorSize,
    sectorsPerCluster: sectorsPerCluster,
    reservedSectors: reservedSectors,
    fatCount: fatCount,
    fatSectors: fatSectors,
    rootEntries: rootEntries,
    totalSectors: totalSectors,
    clusterCount: clusterCount,
    rootCluster: bits == FatBits.fat32 ? view.getUint32(44, Endian.little) : null,
    volumeId: hasExtended ? view.getUint32(ext + 3, Endian.little) : 0,
    label: hasExtended ? cp437Decode(image.sublist(ext + 7, ext + 18)).trimRight() : '',
    oemName: cp437Decode(image.sublist(3, 11)).trimRight(),
  );
}

// --------------------------------------------------------------------------
// Choosing a geometry for a new image
// --------------------------------------------------------------------------

/// Work out the BPB geometry for a [size]-byte volume, picking the FAT width
/// the cluster count implies (or [fatBits] when forced).
///
/// A straight port of idftool's `_geometry`, so the same inputs produce the
/// same volume.
FatGeometry solveGeometry(
  int size, {
  int sectorSize = FatLayout.defaultSectorSize,
  int sectorsPerCluster = FatLayout.defaultSectorsPerCluster,
  int fatCount = FatLayout.fatCount,
  int rootEntries = FatLayout.rootEntries,
  int? fatBits,
}) {
  if (!const [512, 1024, 2048, 4096].contains(sectorSize)) {
    throw FatException('Sector size $sectorSize is not one of 512, 1024, 2048, 4096');
  }
  if (sectorsPerCluster < 1 || sectorsPerCluster > 128 || sectorsPerCluster & (sectorsPerCluster - 1) != 0) {
    throw FatException('Sectors per cluster must be a power of two up to 128, not $sectorsPerCluster');
  }
  if (size % sectorSize != 0) {
    throw FatException('Filesystem size ${hex(size)} is not a multiple of the sector size ${hex(sectorSize)}');
  }
  final totalSectors = size ~/ sectorSize;
  final rootDirSectors = (rootEntries * FatLayout.dirEntrySize + sectorSize - 1) ~/ sectorSize;

  int clustersFor(int fatSize) {
    final dataSectors = totalSectors - (FatLayout.reservedSectors + fatCount * fatSize + rootDirSectors);
    if (dataSectors <= 0) throw FatException('Partition of ${hex(size)} bytes is too small for a FAT filesystem');
    return dataSectors ~/ sectorsPerCluster;
  }

  /// Smallest FAT that can index the data area left over once the FAT is
  /// accounted for. Growing the FAT shrinks the data area, which shrinks the
  /// FAT needed again, so this walks up to a fixed point.
  (int, int) solve(FatBits bits) {
    var fatSize = 1;
    while (true) {
      final clusters = clustersFor(fatSize);
      final needed = (bits.fatBytes(clusters + 2) + sectorSize - 1) ~/ sectorSize; // entries 0 and 1 are reserved
      if (needed <= fatSize) return (fatSize, clusters);
      fatSize = needed;
    }
  }

  /// As [solve], then pad the FAT until the cluster count is inside the
  /// width's range.
  (int, int) fit(FatBits bits) {
    var (fatSize, clusters) = solve(bits);
    final limit = bits == FatBits.fat12 ? FatLayout.fat12MaxClusters : FatLayout.fat16MaxClusters;
    while (clusters > limit) {
      fatSize += 1;
      clusters = clustersFor(fatSize);
    }
    return (fatSize, clusters);
  }

  const ranges = {
    FatBits.fat12: (1, FatLayout.fat12MaxClusters),
    FatBits.fat16: (FatLayout.fat12MaxClusters + 1, FatLayout.fat16MaxClusters),
  };

  FatBits bits;
  int fatSize, clusters;
  if (fatBits != null) {
    final forced = FatBits.fromBits(fatBits);
    if (forced == null || forced == FatBits.fat32) {
      throw FatException('Unsupported FAT type $fatBits (only FAT12 or FAT16 images are created)');
    }
    bits = forced;
    (fatSize, clusters) = fit(bits);
    if (clusters < ranges[bits]!.$1) {
      throw FatException('A ${hex(size)}-byte volume only holds $clusters clusters, which every FAT implementation '
          'reads as FAT12, not the requested FAT${bits.bits} — use fewer sectors per cluster to get more clusters');
    }
  } else {
    // The FAT width is derived from the cluster count, never declared, so pick the width
    // whose range the natural count already falls in rather than padding the FAT to force it.
    FatBits? found;
    (fatSize, clusters) = (0, 0);
    for (final entry in ranges.entries) {
      (fatSize, clusters) = solve(entry.key);
      if (clusters >= entry.value.$1 && clusters <= entry.value.$2) {
        found = entry.key;
        break;
      }
    }
    if (found != null) {
      bits = found;
    } else {
      if (clusters > FatLayout.fat16MaxClusters) {
        final largest = FatLayout.fat16MaxClusters * sectorsPerCluster * sectorSize;
        throw FatException('A ${hex(size)}-byte volume needs $clusters clusters of '
            '${hex(sectorsPerCluster * sectorSize)} bytes, more than the ${FatLayout.fat16MaxClusters} FAT16 allows '
            '(FAT32 images are not created) — raise the sectors per cluster; at this cluster size the limit is '
            '${hex(largest)} bytes');
      }
      // The count sits in the gap between the widths: FAT12 overflows, and FAT16's larger
      // table pushes it back under the FAT16 minimum. Settle for FAT12 a few clusters short.
      bits = FatBits.fat12;
      (fatSize, clusters) = fit(bits);
    }
  }

  return FatGeometry(
    bits: bits,
    sectorSize: sectorSize,
    sectorsPerCluster: sectorsPerCluster,
    reservedSectors: FatLayout.reservedSectors,
    fatCount: fatCount,
    fatSectors: fatSize,
    rootEntries: rootEntries,
    totalSectors: totalSectors,
    clusterCount: clusters,
  );
}

/// Lay down a boot sector, empty FATs and an empty root directory for
/// [geometry] in a fresh (erased, all `0xFF`) image.
///
/// Matches idftool's `_format` byte for byte: the boot sector is zero outside
/// the fields written, the FAT regions are zeroed with the two reserved
/// entries set, and the root directory is zeroed.
Uint8List formatVolume(FatGeometry geometry, {required int volumeId, required String label}) {
  final sectorSize = geometry.sectorSize;
  final image = Uint8List(geometry.size)..fillRange(0, geometry.size, FatLayout.erased);

  final boot = Uint8List(sectorSize);
  final view = ByteData.sublistView(boot);
  boot.setAll(0, const [0xEB, 0xFE, 0x90]); // jump instruction; ESP-IDF writes an endless loop
  boot.setAll(3, FatLayout.oemName.codeUnits);
  view.setUint16(11, sectorSize, Endian.little);
  boot[13] = geometry.sectorsPerCluster;
  view.setUint16(14, geometry.reservedSectors, Endian.little);
  boot[16] = geometry.fatCount;
  view.setUint16(17, geometry.rootEntries, Endian.little);
  final fits16 = geometry.totalSectors < 0x10000;
  view.setUint16(19, fits16 ? geometry.totalSectors : 0, Endian.little);
  boot[21] = FatLayout.mediaType;
  view.setUint16(22, geometry.fatSectors, Endian.little);
  view.setUint16(24, 0x3F, Endian.little); // sectors per track
  view.setUint16(26, 0xFF, Endian.little); // heads
  view.setUint32(28, 0, Endian.little); // hidden sectors
  view.setUint32(32, fits16 ? 0 : geometry.totalSectors, Endian.little);
  boot[36] = 0x80; // drive number
  boot[38] = 0x29; // extended boot signature — volume id/label/type fields follow
  view.setUint32(39, volumeId, Endian.little);
  boot.setAll(43, _encodeLabel(label));
  boot.setAll(54, 'FAT     '.codeUnits); // informational only
  boot[510] = 0x55;
  boot[511] = 0xAA;
  image.setAll(0, boot);

  // Entry 0 carries the media byte, entry 1 is the end-of-chain marker; both FATs start
  // zeroed, which marks every data cluster free.
  final fat = Uint8List(geometry.fatBytes);
  final head = geometry.bits == FatBits.fat12 ? const [0xF8, 0xFF, 0xFF] : const [0xF8, 0xFF, 0xFF, 0xFF];
  fat.setAll(0, head);
  for (var i = 0; i < geometry.fatCount; i++) {
    image.setAll(geometry.fatOffset(i), fat);
  }

  image.fillRange(geometry.rootDirOffset, geometry.rootDirOffset + geometry.rootDirBytes, 0);
  return image;
}

/// The 11-byte volume label field: ASCII, truncated and space padded.
List<int> _encodeLabel(String label) {
  final bytes = <int>[];
  for (final rune in label.runes) {
    if (rune > 0x7F) throw FatException("Volume label '$label' is not ASCII");
    bytes.add(rune);
  }
  return (bytes.length > 11 ? bytes.sublist(0, 11) : bytes) + List.filled(11 - bytes.length.clamp(0, 11), 0x20);
}
