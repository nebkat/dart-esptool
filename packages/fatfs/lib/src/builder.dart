/// Building a FAT image from scratch.
///
/// The output matches what idftool's `create-fs` produces through pyfatfs,
/// byte for byte, given the same sources, timestamps and volume id. That
/// means following pyfatfs's habits rather than doing the obvious thing in a
/// few places, each of which is noted where it happens: the order entries are
/// created in, first-fit sequential cluster allocation with the parent
/// directory extended *after* a file's data is allocated, directory clusters
/// zero-filled while file clusters keep their erased `0xFF` tails, the way
/// 8.3 names are derived, and which cluster numbers are never handed out.
library;

import 'dart:math';
import 'dart:typed_data';

import 'common.dart';
import 'geometry.dart';
import 'wear_levelling.dart';

/// One file (or, with a trailing slash on [path], an empty directory) to put
/// in an image. [path] is slash separated, without a leading slash; parent
/// directories are created as needed.
typedef FatSource = ({String path, Uint8List bytes, DateTime? modified});

/// Build a FAT image that fills a [size]-byte partition.
///
/// With [wearLevelling] (the default, and how ESP-IDF mounts a `fat`
/// partition in SPI flash) the filesystem is built to fit inside the
/// container and then wrapped, so the result is still exactly [size] bytes.
///
/// Entries are created in the order idftool's `collect` yields them — by
/// depth, then by path — regardless of the order of [sources]. A source's
/// wall-clock [FatSource.modified] fields become its DOS timestamp (the zone
/// is ignored); sources without one, and directories created implicitly, use
/// [timestamp], or the current time. [volumeId] and [deviceId] are random
/// unless given, so pass them for a reproducible image. [fatBits] forces
/// FAT12 or FAT16 instead of deriving the width from the cluster count.
Uint8List fatCreate(
  List<FatSource> sources,
  int size, {
  bool wearLevelling = true,
  int sectorSize = FatLayout.defaultSectorSize,
  int? sectorsPerCluster,
  String? label,
  DateTime? timestamp,
  int? fatBits,
  int? volumeId,
  int? deviceId,
}) {
  final fsSize = wearLevelling ? wlFilesystemSize(size) : size;
  final filesystem = _build(
    sources,
    fsSize,
    sectorSize: sectorSize,
    sectorsPerCluster: sectorsPerCluster ?? FatLayout.defaultSectorsPerCluster,
    label: label ?? FatLayout.defaultLabel,
    timestamp: timestamp ?? DateTime.now(),
    fatBits: fatBits,
    volumeId: volumeId ?? Random.secure().nextInt(0x100000000),
  );
  return wearLevelling ? wlWrap(filesystem, size, deviceId: deviceId) : filesystem;
}

/// A file or directory to create, with its parent already in place.
class _Item {
  _Item(this.path, this.isDir, this.bytes, this.modified);
  final String path;
  final bool isDir;
  final Uint8List bytes;
  final DateTime modified;

  int get depth => '/'.allMatches(path).length;
  String get parent => path.substring(0, max(0, path.lastIndexOf('/')));
  String get name => path.substring(path.lastIndexOf('/') + 1);
}

/// Validate the sources and expand them into the directories and files to
/// create, in creation order.
List<_Item> _plan(List<FatSource> sources, DateTime timestamp) {
  final items = <String, _Item>{};
  for (final source in sources) {
    var path = source.path;
    while (path.startsWith('/')) {
      path = path.substring(1);
    }
    final isDir = path.endsWith('/');
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    if (path.isEmpty) throw FatException("Source path '${source.path}' is empty");
    final segments = path.split('/');
    for (final segment in segments) {
      if (segment.isEmpty || segment == '.' || segment == '..') {
        throw FatException("Source path '${source.path}' is not a plain relative path");
      }
    }
    if (isDir && source.bytes.isNotEmpty) throw FatException("Directory '${source.path}' cannot have contents");

    // Every ancestor is a directory; make them implicitly unless a source names them.
    for (var i = 1; i < segments.length; i++) {
      final ancestor = segments.sublist(0, i).join('/');
      final existing = items[ancestor];
      if (existing == null) {
        items[ancestor] = _Item(ancestor, true, Uint8List(0), timestamp);
      } else if (!existing.isDir) {
        throw FatException("'$ancestor' is both a file and a parent directory");
      }
    }
    final existing = items[path];
    if (existing != null && !(existing.isDir && isDir)) {
      throw FatException("'$path' is listed twice");
    }
    items[path] = _Item(path, isDir, source.bytes, source.modified ?? timestamp);
  }
  // idftool creates entries by depth, then by path, and the allocation order
  // (so the image) depends on it.
  return items.values.toList()
    ..sort((a, b) => a.depth != b.depth ? a.depth.compareTo(b.depth) : compareCodePoints(a.path, b.path));
}

Uint8List _build(
  List<FatSource> sources,
  int size, {
  required int sectorSize,
  required int sectorsPerCluster,
  required String label,
  required DateTime timestamp,
  required int? fatBits,
  required int volumeId,
}) {
  final geometry = solveGeometry(size, sectorSize: sectorSize, sectorsPerCluster: sectorsPerCluster, fatBits: fatBits);
  final items = _plan(sources, timestamp);
  final writer = _Writer(geometry, formatVolume(geometry, volumeId: volumeId, label: label));

  final directories = <String, _Directory>{'': writer.root};
  for (final item in items) {
    final parent = directories[item.parent]!;
    if (item.isDir) {
      directories[item.path] = writer.mkdir(parent, item.name, item.modified);
    } else {
      writer.mkfile(parent, item.name, item.bytes, item.modified);
    }
  }
  writer.flushFat();
  return writer.image;
}

/// A directory being built: its serialised entries and where they live.
class _Directory {
  _Directory(this.cluster, this.header);

  /// First cluster; `null` for the fixed FAT12/16 root directory.
  final int? cluster;

  /// The directory's own 32-byte entry in its parent (zeroes for the root),
  /// which is what its children's `..` entries are copied from.
  final Uint8List header;

  /// The chain the directory occupies, grown as it fills.
  final List<int> chain = [];

  /// Every entry in order, long name parts included.
  final List<Uint8List> entries = [];

  /// The 8.3 names in use, for collision avoidance.
  final Set<String> shortNames = {};
}

class _Writer {
  _Writer(this.geometry, this.image)
      : fat = List.filled(geometry.clusterCount + FatLayout.firstCluster, 0),
        root = _Directory(null, Uint8List(FatLayout.dirEntrySize)) {
    // Entry 0 carries the media byte below all-ones, entry 1 is an end-of-chain marker.
    fat[0] = (geometry.bits.eoc & 0x0FFFFF00) | FatLayout.mediaType;
    fat[1] = geometry.bits.eoc;
    // pyfatfs never allocates past MAX_DATA_CLUSTER (0xFEF on FAT12, 0xFFEF on
    // FAT16), a few clusters short of the marker range, even when the volume
    // has them. Matching it keeps a nearly-full image byte-identical.
    lastCluster = min(geometry.clusterCount + FatLayout.firstCluster - 1, geometry.bits.maxDataCluster);
  }

  final FatGeometry geometry;
  final Uint8List image;
  final List<int> fat;
  final _Directory root;

  /// The highest cluster number that may be allocated.
  late final int lastCluster;

  /// Where the next allocation starts looking. Nothing is ever freed, so this
  /// only moves forward and allocation is sequential.
  int nextFree = FatLayout.firstCluster;

  int get bytesPerCluster => geometry.bytesPerCluster;

  /// Allocate a chain of [count] clusters, first fit from [nextFree], linked
  /// and terminated in the FAT. With [erase] the clusters are zero-filled;
  /// otherwise they keep the erased `0xFF` the image started with.
  List<int> allocate(int count, {required bool erase}) {
    final clusters = <int>[];
    var c = nextFree;
    while (clusters.length < count && c <= lastCluster) {
      if (fat[c] == 0) clusters.add(c);
      c++;
    }
    if (clusters.length < count) {
      final capacity = geometry.clusterCount * bytesPerCluster;
      throw FatException(
          'Sources do not fit in a ${hex(geometry.size)}-byte FAT image (${hex(capacity)} bytes usable): '
          'not enough free space to allocate ${count * bytesPerCluster} bytes (${clusters.length * bytesPerCluster} bytes free)');
    }
    nextFree = c;
    for (var i = 0; i < clusters.length; i++) {
      fat[clusters[i]] = i + 1 < clusters.length ? clusters[i + 1] : geometry.bits.eoc;
      if (erase) {
        final offset = geometry.clusterOffset(clusters[i]);
        image.fillRange(offset, offset + bytesPerCluster, 0);
      }
    }
    return clusters;
  }

  /// Write [data] across the clusters of [chain], starting from its first.
  void writeChain(List<int> chain, Uint8List data) {
    var written = 0;
    for (final cluster in chain) {
      if (written >= data.length) break;
      final end = min(written + bytesPerCluster, data.length);
      image.setRange(geometry.clusterOffset(cluster), geometry.clusterOffset(cluster) + (end - written), data, written);
      written = end;
    }
  }

  /// Write a directory's entries back to disk, growing its chain if they no
  /// longer fit. The root directory is a fixed area and cannot grow.
  void flushDirectory(_Directory dir) {
    final builder = BytesBuilder(copy: false);
    for (final entry in dir.entries) {
      builder.add(entry);
    }
    final data = builder.toBytes();

    if (dir.cluster == null) {
      if (data.length > geometry.rootDirBytes) {
        throw FatException('The root directory is full: it holds ${geometry.rootEntries} entries, and long names take '
            'several each — put files in a subdirectory instead');
      }
      // Overwrite the empty space as well.
      image.fillRange(geometry.rootDirOffset, geometry.rootDirOffset + geometry.rootDirBytes, 0);
      image.setAll(geometry.rootDirOffset, data);
      return;
    }

    final have = dir.chain.length * bytesPerCluster;
    if (data.length > have) {
      final extra = allocate((data.length - have + bytesPerCluster - 1) ~/ bytesPerCluster, erase: true);
      fat[dir.chain.last] = extra.first;
      dir.chain.addAll(extra);
    }
    // Pad to whole clusters with zeroes so a stale tail never reads as entries.
    final padded = Uint8List(max(1, (data.length + bytesPerCluster - 1) ~/ bytesPerCluster) * bytesPerCluster)
      ..setAll(0, data);
    writeChain(dir.chain, padded);
  }

  /// A directory entry (long name parts first, then the 8.3 entry) for
  /// [name] in [parent]. The 8.3 name is registered with [parent].
  (Uint8List, Uint8List) newEntry(_Directory parent, String name, int attr, DateTime dt) {
    final short = make8dot3Name(name, parent.shortNames);
    parent.shortNames.add(shortNameToString(short));

    final entry = Uint8List(FatLayout.dirEntrySize);
    final view = ByteData.sublistView(entry);
    entry.setAll(0, short);
    entry[11] = attr;
    view.setUint16(14, dosTime(dt), Endian.little); // creation time
    view.setUint16(16, dosDate(dt), Endian.little); // creation date
    view.setUint16(18, dosDate(dt), Endian.little); // last access date
    view.setUint16(22, dosTime(dt), Endian.little); // write time
    view.setUint16(24, dosDate(dt), Endian.little); // write date

    // Only a name that does not fit 8.3 (or would lose its case) gets a long name.
    final lfn = shortNameToString(short) == name ? Uint8List(0) : longNameEntries(name, short);
    return (lfn, entry);
  }

  static void setCluster(Uint8List entry, int cluster) {
    ByteData.sublistView(entry)
      ..setUint16(26, cluster & 0xFFFF, Endian.little)
      ..setUint16(20, (cluster >> 16) & 0xFFFF, Endian.little);
  }

  _Directory mkdir(_Directory parent, String name, DateTime dt) {
    final (lfn, entry) = newEntry(parent, name, FatAttr.directory, dt);
    // A directory always starts with its own '.' and '..' entries; '..' points at
    // cluster 0 when the parent is the (cluster-less) fixed root directory.
    final chain = allocate(1, erase: true);
    setCluster(entry, chain.first);
    final dir = _Directory(chain.first, entry)..chain.addAll(chain);

    final dot = Uint8List.fromList(entry)..setAll(0, '.          '.codeUnits);
    final dotdot = Uint8List.fromList(parent.header)..setAll(0, '..         '.codeUnits);
    if (parent.cluster == null) {
      // The root has no entry of its own: pyfatfs's stand-in has the directory
      // attribute, zero timestamps and cluster 0.
      dotdot[11] = FatAttr.directory;
      setCluster(dotdot, 0);
    }
    dir.entries.addAll([dot, dotdot]);
    flushDirectory(dir);

    parent.entries.addAll([lfn, entry]);
    flushDirectory(parent);
    return dir;
  }

  void mkfile(_Directory parent, String name, Uint8List data, DateTime dt) {
    // ATTR_ARCHIVE is what FatFs (and ESP-IDF's fatfsgen) sets on every new file; some readers,
    // including ESP-IDF's own fatfsparse.py, match on the attribute byte exactly and skip files
    // without it.
    final (lfn, entry) = newEntry(parent, name, FatAttr.archive, dt);
    if (data.length > 0xFFFFFFFF) throw FatException("'$name' is larger than a FAT file can be (4 GiB)");
    List<int> chain = const [];
    if (data.isNotEmpty) {
      // The data's clusters come before any the parent directory needs to grow by.
      chain = allocate((data.length + bytesPerCluster - 1) ~/ bytesPerCluster, erase: false);
      setCluster(entry, chain.first);
      ByteData.sublistView(entry).setUint32(28, data.length, Endian.little);
    }
    parent.entries.addAll([lfn, entry]);
    flushDirectory(parent);
    if (data.isNotEmpty) writeChain(chain, data);
  }

  /// Write the FAT into every copy. Only the volume's own entries are
  /// written; the rest of each FAT region keeps the zeroes it was formatted
  /// with, which reads as free.
  void flushFat() {
    final bytes = Uint8List(geometry.bits.fatBytes(fat.length));
    for (var i = 0; i < fat.length; i++) {
      geometry.bits.write(bytes, i, fat[i]);
    }
    for (var copy = 0; copy < geometry.fatCount; copy++) {
      image.setAll(geometry.fatOffset(copy), bytes);
    }
  }
}

// --------------------------------------------------------------------------
// Names
// --------------------------------------------------------------------------

/// Characters an 8.3 name cannot contain, replaced with `_` when deriving one.
///
/// pyfatfs means to reject control characters too, but its check compares
/// each byte against a `range` object rather than its members, so they slip
/// through; the same set is used here so the derived names agree.
const Set<int> _invalidShortChars = {
  0x22, 0x2A, 0x2B, 0x2C, 0x2E, 0x2F, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F, 0x5B, 0x5C, 0x5D, 0x7C, //
};

/// python's `os.path.splitext`: split at the last dot, unless every character
/// before it is also a dot (so `.bashrc` has no extension).
(List<int>, List<int>) _splitExt(List<int> runes) {
  final dot = runes.lastIndexOf(0x2E);
  for (var i = 0; i < dot; i++) {
    if (runes[i] != 0x2E) return (runes.sublist(0, dot), runes.sublist(dot));
  }
  return (runes, const []);
}

/// python's `str.strip()`: whitespace off both ends.
List<int> _strip(List<int> runes) {
  var start = 0, end = runes.length;
  while (start < end && _isSpace(runes[start])) {
    start++;
  }
  while (end > start && _isSpace(runes[end - 1])) {
    end--;
  }
  return runes.sublist(start, end);
}

bool _isSpace(int rune) => String.fromCharCode(rune).trim().isEmpty;

/// Encode as code page 437, `?` for anything it lacks, then apply the 8.3
/// character rules: spaces vanish and invalid characters become `_`.
List<int> _mapShortChars(List<int> runes) {
  final out = <int>[];
  for (final rune in runes) {
    final byte = cp437EncodeRune(rune) ?? 0x3F;
    if (byte == 0x20) continue;
    out.add(_invalidShortChars.contains(byte) ? 0x5F : byte);
  }
  return out;
}

/// The code points python's `str.upper()` expands to more than one character
/// (Unicode's unconditional SpecialCasing: `ß` → `SS`, the `ﬁ` ligatures,
/// Greek with iota subscript, …). Dart's `toUpperCase` only applies simple
/// one-to-one mappings, so these are handled by hand to derive the same 8.3
/// names.
const Map<int, List<int>> _upperExpansions = {
  0x00DF: [0x0053, 0x0053], 0x0149: [0x02BC, 0x004E], 0x01F0: [0x004A, 0x030C], //
  0x0390: [0x0399, 0x0308, 0x0301], 0x03B0: [0x03A5, 0x0308, 0x0301], 0x0587: [0x0535, 0x0552],
  0x1E96: [0x0048, 0x0331], 0x1E97: [0x0054, 0x0308], 0x1E98: [0x0057, 0x030A], 0x1E99: [0x0059, 0x030A],
  0x1E9A: [0x0041, 0x02BE], 0x1F50: [0x03A5, 0x0313], 0x1F52: [0x03A5, 0x0313, 0x0300],
  0x1F54: [0x03A5, 0x0313, 0x0301], 0x1F56: [0x03A5, 0x0313, 0x0342],
  0x1F80: [0x1F08, 0x0399], 0x1F81: [0x1F09, 0x0399], 0x1F82: [0x1F0A, 0x0399], 0x1F83: [0x1F0B, 0x0399],
  0x1F84: [0x1F0C, 0x0399], 0x1F85: [0x1F0D, 0x0399], 0x1F86: [0x1F0E, 0x0399], 0x1F87: [0x1F0F, 0x0399],
  0x1F88: [0x1F08, 0x0399], 0x1F89: [0x1F09, 0x0399], 0x1F8A: [0x1F0A, 0x0399], 0x1F8B: [0x1F0B, 0x0399],
  0x1F8C: [0x1F0C, 0x0399], 0x1F8D: [0x1F0D, 0x0399], 0x1F8E: [0x1F0E, 0x0399], 0x1F8F: [0x1F0F, 0x0399],
  0x1F90: [0x1F28, 0x0399], 0x1F91: [0x1F29, 0x0399], 0x1F92: [0x1F2A, 0x0399], 0x1F93: [0x1F2B, 0x0399],
  0x1F94: [0x1F2C, 0x0399], 0x1F95: [0x1F2D, 0x0399], 0x1F96: [0x1F2E, 0x0399], 0x1F97: [0x1F2F, 0x0399],
  0x1F98: [0x1F28, 0x0399], 0x1F99: [0x1F29, 0x0399], 0x1F9A: [0x1F2A, 0x0399], 0x1F9B: [0x1F2B, 0x0399],
  0x1F9C: [0x1F2C, 0x0399], 0x1F9D: [0x1F2D, 0x0399], 0x1F9E: [0x1F2E, 0x0399], 0x1F9F: [0x1F2F, 0x0399],
  0x1FA0: [0x1F68, 0x0399], 0x1FA1: [0x1F69, 0x0399], 0x1FA2: [0x1F6A, 0x0399], 0x1FA3: [0x1F6B, 0x0399],
  0x1FA4: [0x1F6C, 0x0399], 0x1FA5: [0x1F6D, 0x0399], 0x1FA6: [0x1F6E, 0x0399], 0x1FA7: [0x1F6F, 0x0399],
  0x1FA8: [0x1F68, 0x0399], 0x1FA9: [0x1F69, 0x0399], 0x1FAA: [0x1F6A, 0x0399], 0x1FAB: [0x1F6B, 0x0399],
  0x1FAC: [0x1F6C, 0x0399], 0x1FAD: [0x1F6D, 0x0399], 0x1FAE: [0x1F6E, 0x0399], 0x1FAF: [0x1F6F, 0x0399],
  0x1FB2: [0x1FBA, 0x0399], 0x1FB3: [0x0391, 0x0399], 0x1FB4: [0x0386, 0x0399], 0x1FB6: [0x0391, 0x0342],
  0x1FB7: [0x0391, 0x0342, 0x0399], 0x1FBC: [0x0391, 0x0399], 0x1FC2: [0x1FCA, 0x0399], 0x1FC3: [0x0397, 0x0399],
  0x1FC4: [0x0389, 0x0399], 0x1FC6: [0x0397, 0x0342], 0x1FC7: [0x0397, 0x0342, 0x0399], 0x1FCC: [0x0397, 0x0399],
  0x1FD2: [0x0399, 0x0308, 0x0300], 0x1FD3: [0x0399, 0x0308, 0x0301], 0x1FD6: [0x0399, 0x0342],
  0x1FD7: [0x0399, 0x0308, 0x0342], 0x1FE2: [0x03A5, 0x0308, 0x0300], 0x1FE3: [0x03A5, 0x0308, 0x0301],
  0x1FE4: [0x03A1, 0x0313], 0x1FE6: [0x03A5, 0x0342], 0x1FE7: [0x03A5, 0x0308, 0x0342], 0x1FF2: [0x1FFA, 0x0399],
  0x1FF3: [0x03A9, 0x0399], 0x1FF4: [0x038F, 0x0399], 0x1FF6: [0x03A9, 0x0342], 0x1FF7: [0x03A9, 0x0342, 0x0399],
  0x1FFC: [0x03A9, 0x0399], 0xFB00: [0x0046, 0x0046], 0xFB01: [0x0046, 0x0049], 0xFB02: [0x0046, 0x004C],
  0xFB03: [0x0046, 0x0046, 0x0049], 0xFB04: [0x0046, 0x0046, 0x004C], 0xFB05: [0x0053, 0x0054],
  0xFB06: [0x0053, 0x0054], 0xFB13: [0x0544, 0x0546], 0xFB14: [0x0544, 0x0535], 0xFB15: [0x0544, 0x053B],
  0xFB16: [0x054E, 0x0546], 0xFB17: [0x0544, 0x053D],
};

/// python's `str.upper()`, as code points.
List<int> _pythonUpper(String s) => [
      for (final rune in s.runes) ...(_upperExpansions[rune] ?? String.fromCharCode(rune).toUpperCase().runes),
    ];

/// Derive the 11-byte 8.3 name for [name], avoiding the (unpadded) names in
/// [taken], the way pyfatfs's `make_8dot3_name` does: upper-cased, the first
/// eight characters of the base and three of the extension, and a `~N`
/// suffix (N from 1, eating into the base) when that collides.
Uint8List make8dot3Name(String name, Set<String> taken) {
  final upper = _pythonUpper(name);
  final (root, ext) = _splitExt(upper);
  final base = _mapShortChars(_strip(root.sublist(0, min(8, root.length))));
  final extension = _mapShortChars(_strip(ext.sublist(min(1, ext.length), min(4, ext.length))));

  for (var i = 0; i <= 999999; i++) {
    var candidate = base;
    if (i > 0) {
      final suffix = '~$i'.codeUnits;
      candidate = base.sublist(0, min(base.length, 8 - suffix.length)) + suffix;
    }
    final short = cp437Decode(candidate) + (extension.isEmpty ? '' : '.') + cp437Decode(extension);
    if (taken.contains(short)) continue;
    if (candidate.isEmpty) {
      // A base that maps to nothing (all spaces, or only an extension) has no
      // valid 8.3 form; pyfatfs rejects it too.
      throw FatException("Cannot derive an 8.3 name for '$name'");
    }
    final bytes = Uint8List(11)..fillRange(0, 11, 0x20);
    bytes.setAll(0, candidate);
    bytes.setAll(8, extension);
    if (bytes[0] == FatLayout.deletedEntry) bytes[0] = FatLayout.escapedE5;
    return bytes;
  }
  throw FatException("Cannot derive an 8.3 name for '$name': every ~N suffix is taken");
}

/// The long name parts for [name] belonging to the 8.3 entry [short], in
/// on-disk order (last part first).
Uint8List longNameEntries(String name, Uint8List short) {
  final units = name.codeUnits;
  if (units.length > FatLayout.maxLongName) {
    throw FatException("'$name' is longer than the ${FatLayout.maxLongName} characters a long name can hold");
  }
  final checksum = shortNameChecksum(short);
  final count = (units.length + FatLayout.lfnCharsPerEntry - 1) ~/ FatLayout.lfnCharsPerEntry;
  // NUL-terminated if there is room, then padded with 0xFFFF.
  final padded = List<int>.filled(count * FatLayout.lfnCharsPerEntry, 0xFFFF)..setAll(0, units);
  if (units.length < padded.length) padded[units.length] = 0;

  final out = Uint8List(count * FatLayout.dirEntrySize);
  for (var part = count; part >= 1; part--) {
    final entry = Uint8List.sublistView(
        out, (count - part) * FatLayout.dirEntrySize, (count - part + 1) * FatLayout.dirEntrySize);
    entry[0] = part == count ? part | FatLayout.lastLongEntry : part;
    entry[11] = FatAttr.longName;
    entry[12] = 0;
    entry[13] = checksum;
    // First cluster (offset 26) is always 0.
    final chars = padded.sublist((part - 1) * FatLayout.lfnCharsPerEntry, part * FatLayout.lfnCharsPerEntry);
    const offsets = [1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30];
    for (var i = 0; i < FatLayout.lfnCharsPerEntry; i++) {
      entry[offsets[i]] = chars[i] & 0xFF;
      entry[offsets[i] + 1] = chars[i] >> 8;
    }
  }
  return out;
}
