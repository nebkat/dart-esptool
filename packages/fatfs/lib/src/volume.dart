/// Reading a FAT image back into a listing and file contents.
///
/// The parse is deliberately forgiving: a broken long name, a chain that
/// ends early, or a FAT copy that disagrees with the first is recorded in
/// [FatVolume.errors] and worked around rather than aborting, because an
/// image read off a live device can legitimately be mid-write. Pass
/// `strict: true` to turn them into [FatException]s.
library;

import 'dart:typed_data';

import 'common.dart';
import 'geometry.dart';
import 'wear_levelling.dart';

/// One file or directory found inside an image.
class FatEntry {
  FatEntry({
    required this.path,
    required this.isDir,
    required this.size,
    required this.modified,
    required this.shortName,
    required this.firstCluster,
    required this.attributes,
  });

  /// Slash-separated location inside the image, without a leading slash.
  final String path;
  final bool isDir;

  /// File size in bytes (0 for a directory).
  final int size;

  /// The write timestamp. DOS timestamps carry no zone, so this is a UTC
  /// `DateTime` holding exactly the fields that were on disk; `null` if they
  /// were not a valid date.
  final DateTime? modified;

  /// The 8.3 name the entry is stored under, e.g. `LONGNA~1.TXT`.
  final String shortName;

  /// First data cluster, 0 for an empty file.
  final int firstCluster;

  /// The raw attribute byte; see [FatAttr].
  final int attributes;

  /// The last path segment.
  String get name => path.substring(path.lastIndexOf('/') + 1);

  @override
  String toString() => isDir ? '$path/' : '$path ($size bytes)';
}

/// A mounted FAT image.
class FatVolume {
  FatVolume._(this.image, this.geometry, this._fat, this._strict);

  /// The bare filesystem image — unwrapped from wear levelling if it had it.
  final Uint8List image;
  final FatGeometry geometry;
  final Uint8List _fat;
  final bool _strict;

  /// Every file and directory, depth first: a directory is followed by its
  /// contents, and siblings are in code-point order of their names.
  final List<FatEntry> entries = [];

  /// Anything that did not parse cleanly. Empty unless the image is damaged.
  final List<String> errors = [];

  final Map<String, FatEntry> _byPath = {};

  /// Open a FAT image.
  ///
  /// With [wearLevelling] (the default) an image that [looksLikeWl] is
  /// unwrapped first; pass `false` to read it as a bare filesystem no matter
  /// what. Damage is collected into [errors] unless [strict] is set, in which
  /// case it throws [FatException].
  static FatVolume mount(Uint8List image, {bool wearLevelling = true, bool strict = false}) {
    if (wearLevelling && looksLikeWl(image)) image = wlUnwrap(image);
    final geometry = parseBootSector(image);
    if (geometry.fatOffset(geometry.fatCount - 1) + geometry.fatBytes > image.length) {
      throw FatException('Image is ${hex(image.length)} bytes, too short for the FATs its boot sector describes');
    }
    final fat = Uint8List.sublistView(image, geometry.fatOffset(0), geometry.fatOffset(0) + geometry.fatBytes);
    final volume = FatVolume._(image, geometry, fat, strict);
    volume._checkFatCopies();
    volume._walk();
    return volume;
  }

  /// Recognise a FAT image by its boot sector: signature word plus a
  /// plausible BPB, looking through wear levelling if present.
  static bool detect(Uint8List image) {
    if (looksLikeWl(image)) {
      try {
        image = wlUnwrap(image);
      } on WearLevellingException {
        return false;
      }
    }
    return looksLikeFatBootSector(image);
  }

  void _fail(String message) {
    if (_strict) throw FatException(message);
    errors.add(message);
  }

  void _checkFatCopies() {
    for (var i = 1; i < geometry.fatCount; i++) {
      final start = geometry.fatOffset(i);
      for (var b = 0; b < geometry.fatBytes; b++) {
        if (image[start + b] != _fat[b]) {
          _fail('FAT copy $i differs from the first (at byte $b); using the first');
          break;
        }
      }
    }
  }

  /// The FAT entry for [cluster], from the first FAT.
  int fatEntry(int cluster) => geometry.bits.read(_fat, cluster);

  /// Follow the chain starting at [first]. Damage ends the chain early (with
  /// an error recorded) rather than being followed.
  List<int> clusterChain(int first, {String what = 'chain'}) {
    final chain = <int>[];
    final seen = <int>{};
    var cluster = first;
    while (true) {
      if (!geometry.isValidCluster(cluster)) {
        _fail('$what: cluster $cluster is outside the volume (${geometry.clusterCount} clusters)');
        break;
      }
      if (!seen.add(cluster)) {
        _fail('$what: cluster chain loops back to $cluster');
        break;
      }
      chain.add(cluster);
      final next = fatEntry(cluster);
      if (geometry.bits.isEndOfChain(next)) break;
      if (next == 0) {
        _fail('$what: cluster $cluster is followed by a free cluster');
        break;
      }
      if (next == geometry.bits.badCluster) {
        _fail('$what: cluster $cluster is followed by the bad cluster marker');
        break;
      }
      cluster = next;
    }
    return chain;
  }

  Uint8List _clusterBytes(int cluster) => Uint8List.sublistView(
      image, geometry.clusterOffset(cluster), geometry.clusterOffset(cluster) + geometry.bytesPerCluster);

  /// The bytes of a directory: its fixed area for the FAT12/16 root, its
  /// cluster chain otherwise.
  Uint8List _directoryBytes(int? cluster, String what) {
    if (cluster == null) {
      return Uint8List.sublistView(image, geometry.rootDirOffset, geometry.rootDirOffset + geometry.rootDirBytes);
    }
    final builder = BytesBuilder(copy: false);
    for (final c in clusterChain(cluster, what: what)) {
      builder.add(_clusterBytes(c));
    }
    return builder.toBytes();
  }

  void _walk() {
    final rootCluster = geometry.bits == FatBits.fat32 ? geometry.rootCluster : null;
    _walkDirectory(rootCluster, '', {if (rootCluster != null) rootCluster});
  }

  /// Parse one directory and, depth first, everything below it.
  void _walkDirectory(int? cluster, String prefix, Set<int> ancestors) {
    final children =
        _parseDirectory(_directoryBytes(cluster, prefix.isEmpty ? 'root directory' : "directory '$prefix'"), prefix);
    children.sort((a, b) => compareCodePoints(a.name, b.name));
    for (final child in children) {
      if (_byPath.containsKey(child.path)) {
        _fail("'${child.path}': duplicate directory entry (8.3 name ${child.shortName}); keeping the first");
        continue;
      }
      _byPath[child.path] = child;
      entries.add(child);
      if (!child.isDir) continue;
      if (child.firstCluster == 0) {
        _fail("'${child.path}': directory has no cluster");
        continue;
      }
      if (ancestors.contains(child.firstCluster)) {
        _fail("'${child.path}': directory cluster ${child.firstCluster} is one of its own ancestors");
        continue;
      }
      _walkDirectory(child.firstCluster, '${child.path}/', {...ancestors, child.firstCluster});
    }
  }

  /// Decode the entries of a directory. Dot entries, volume labels and
  /// deleted entries are skipped; long names are attached to the 8.3 entry
  /// that follows them when their sequence and checksum check out.
  List<FatEntry> _parseDirectory(Uint8List data, String prefix) {
    final found = <FatEntry>[];
    // Long name parts collected so far, indexed by sequence number, plus the
    // checksum and sequence the next part has to carry to belong to them.
    var lfnParts = <int, List<int>>{};
    var lfnChecksum = -1;
    var lfnExpected = 0;
    var lfnTotal = 0;

    void dropLfn(String why) {
      if (lfnParts.isNotEmpty) _fail('${prefix.isEmpty ? 'root directory' : "directory '$prefix'"}: $why');
      lfnParts = {};
      lfnChecksum = -1;
      lfnExpected = 0;
      lfnTotal = 0;
    }

    for (var offset = 0; offset + FatLayout.dirEntrySize <= data.length; offset += FatLayout.dirEntrySize) {
      final entry = Uint8List.sublistView(data, offset, offset + FatLayout.dirEntrySize);
      final first = entry[0];
      if (first == FatLayout.endOfDirectory) break;
      if (first == FatLayout.deletedEntry) {
        dropLfn('long name parts left without an entry by a deleted entry');
        continue;
      }
      final attr = entry[11];

      if (FatAttr.isLongName(attr)) {
        final sequence = first & 0x3F;
        final checksum = entry[13];
        if (sequence == 0 || sequence > 20) {
          dropLfn('long name part with sequence number $sequence');
          continue;
        }
        if (first & FatLayout.lastLongEntry != 0) {
          dropLfn('long name parts left without an entry');
          lfnTotal = sequence;
          lfnChecksum = checksum;
        } else if (sequence != lfnExpected || checksum != lfnChecksum) {
          dropLfn('long name part $sequence out of sequence');
          continue;
        }
        lfnParts[sequence] = [
          for (var i = 1; i < 11; i += 2) entry[i] | (entry[i + 1] << 8),
          for (var i = 14; i < 26; i += 2) entry[i] | (entry[i + 1] << 8),
          for (var i = 28; i < 32; i += 2) entry[i] | (entry[i + 1] << 8),
        ];
        lfnExpected = sequence - 1;
        continue;
      }

      final shortBytes = entry.sublist(0, 11);
      final shortName = shortNameToString(shortBytes);
      String? longName;
      if (lfnParts.isNotEmpty) {
        if (lfnExpected != 0) {
          dropLfn("long name for '$shortName' is missing its first part; using the short name");
        } else if (lfnChecksum != shortNameChecksum(shortBytes)) {
          dropLfn("long name checksum does not match '$shortName'; using the short name");
        } else {
          final units = <int>[for (var s = 1; s <= lfnTotal; s++) ...lfnParts[s]!];
          // The last part is padded with 0xFFFF after a NUL terminator (if there was room for one).
          var end = units.length;
          while (end > 0 && units[end - 1] == 0xFFFF) {
            end--;
          }
          final nul = units.indexOf(0);
          if (nul >= 0 && nul < end) end = nul;
          longName = String.fromCharCodes(units.sublist(0, end));
          lfnParts = {};
          lfnChecksum = -1;
          lfnTotal = 0;
        }
      }

      if (attr & FatAttr.volumeId != 0 && attr & FatAttr.directory == 0) continue; // the volume label
      if (shortName == '.' || shortName == '..') continue;
      if (shortName.isEmpty && longName == null) {
        _fail('${prefix.isEmpty ? 'root directory' : "directory '$prefix'"}: entry with an empty name skipped');
        continue;
      }

      final view = ByteData.sublistView(entry);
      final isDir = attr & FatAttr.directory != 0;
      var cluster = view.getUint16(26, Endian.little);
      if (geometry.bits == FatBits.fat32) cluster |= view.getUint16(20, Endian.little) << 16;
      found.add(FatEntry(
        path: '$prefix${longName ?? shortName}',
        isDir: isDir,
        size: isDir ? 0 : view.getUint32(28, Endian.little),
        modified: dosDateTime(view.getUint16(24, Endian.little), view.getUint16(22, Endian.little)),
        shortName: shortName,
        firstCluster: cluster,
        attributes: attr,
      ));
    }
    dropLfn('long name parts at the end of the directory without an entry');
    return found;
  }

  /// The entry at [path] (no leading slash), or `null`.
  FatEntry? lookup(String path) => _byPath[_normalise(path)];

  static String _normalise(String path) {
    var p = path;
    while (p.startsWith('/')) {
      p = p.substring(1);
    }
    while (p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  /// The contents of the file at [path].
  ///
  /// Throws [FatException] if there is no such file. A chain that ends before
  /// the recorded size is an error in strict mode; otherwise the bytes that
  /// are there are returned and the shortfall recorded in [errors].
  Uint8List read(String path) {
    final entry = lookup(path);
    if (entry == null) throw FatException("No such file: '$path'");
    if (entry.isDir) throw FatException("'$path' is a directory");
    if (entry.size == 0) return Uint8List(0);
    if (entry.firstCluster == 0) {
      _fail("'$path': ${entry.size}-byte file has no first cluster");
      return Uint8List(0);
    }
    final chain = clusterChain(entry.firstCluster, what: "'$path'");
    final available = chain.length * geometry.bytesPerCluster;
    if (available < entry.size) {
      _fail("'$path': cluster chain holds $available bytes but the entry says ${entry.size}");
    }
    final out = Uint8List(entry.size < available ? entry.size : available);
    var written = 0;
    for (final cluster in chain) {
      if (written >= out.length) break;
      final bytes = _clusterBytes(cluster);
      final take = out.length - written < bytes.length ? out.length - written : bytes.length;
      out.setRange(written, written + take, bytes);
      written += take;
    }
    return out;
  }

  /// Clusters not allocated to anything, per the FAT.
  int get freeClusters {
    var free = 0;
    for (var c = FatLayout.firstCluster; c < geometry.clusterCount + FatLayout.firstCluster; c++) {
      if (fatEntry(c) == 0) free++;
    }
    return free;
  }
}
