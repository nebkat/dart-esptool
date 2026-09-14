import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:fatfs/fatfs.dart';
import 'package:littlefs/littlefs.dart';
import 'package:spiffs/spiffs.dart';

import '../device.dart';
import '../partition_table.dart';

/// The filesystems idftool can read from a partition image, mapped onto the
/// ESP-IDF partition subtypes that declare them.
enum FsType {
  fatfs('fatfs', DataSubtype.fat),
  littlefs('littlefs', DataSubtype.littlefs),
  spiffs('spiffs', DataSubtype.spiffs);

  const FsType(this.label, this.subtype);
  final String label;
  final DataSubtype subtype;

  /// The filesystem a partition's subtype implies, or `null` if none.
  static FsType? forPartition(PartitionDefinition p) =>
      p.isData ? values.where((t) => t.subtype.value == p.subtype).firstOrNull : null;

  /// Identify an image by its content, or `null` if nothing recognises it.
  /// LittleFS and FAT carry unmistakable signatures; SPIFFS's magic is weak,
  /// so it goes last.
  static FsType? detect(Uint8List image) {
    if (_safe(() => LittleFsVolume.detect(image))) return littlefs;
    if (_safe(() => FatVolume.detect(image))) return fatfs;
    if (_safe(() => SpiffsVolume.detect(image))) return spiffs;
    return null;
  }

  static bool _safe(bool Function() probe) {
    try {
      return probe();
    } catch (_) {
      return false;
    }
  }

  static FsType? byLabel(String label) => switch (label.toLowerCase()) {
        'fat' || 'fatfs' => fatfs,
        'littlefs' => littlefs,
        'spiffs' => spiffs,
        _ => null,
      };

  /// Settle on a filesystem: an explicit choice, else the partition subtype,
  /// else the image content.
  static FsType resolve({FsType? explicit, PartitionDefinition? partition, Uint8List? image, String what = 'the filesystem'}) {
    if (explicit != null) return explicit;
    if (partition != null) {
      final t = forPartition(partition);
      if (t != null) return t;
    }
    if (image != null) {
      final t = detect(image);
      if (t != null) return t;
    }
    final hint = partition != null
        ? "partition '${partition.name}' has subtype '${partition.subtypeName}', which is not one of the filesystem subtypes (fat, littlefs, spiffs)"
        : image != null
            ? '$what does not look like any filesystem idftool knows'
            : 'there is no partition to take it from';
    throw IdfToolException('Cannot tell which filesystem to use — $hint. Choose one explicitly (fatfs/littlefs/spiffs).');
  }
}

/// A file or directory inside a mounted image.
class FsEntry {
  const FsEntry({required this.path, required this.isDir, required this.size, this.modified});

  /// `/`-separated, no leading slash.
  final String path;
  final bool isDir;
  final int size;
  final DateTime? modified;

  String get name => path.contains('/') ? path.substring(path.lastIndexOf('/') + 1) : path;
  String get parent => path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '';
}

/// A file to put in an image being built. [modified] only matters for FAT,
/// which stores timestamps; `null` means "now" (or the builder's default).
typedef FsSource = ({String path, Uint8List bytes, DateTime? modified});

/// A mounted filesystem image, whichever backend it came from.
abstract class FsVolume {
  FsType get type;
  List<FsEntry> get entries;
  Uint8List read(String path);
  List<String> get errors;

  /// A one-line description of the geometry for logs.
  String describe();

  /// Mount [image] as [type] (or whatever [FsType.resolve] settles on).
  static FsVolume mount(Uint8List image, {FsType? type, PartitionDefinition? partition, bool strict = false}) {
    final t = FsType.resolve(explicit: type, partition: partition, image: image);
    try {
      return switch (t) {
        FsType.littlefs => _LittleFs(LittleFsVolume.mount(image, strict: strict)),
        FsType.spiffs => _Spiffs(SpiffsVolume.mount(image, strict: strict)),
        FsType.fatfs => _Fat(FatVolume.mount(image, strict: strict)),
      };
    } on IdfToolException {
      rethrow;
    } catch (e) {
      throw IdfToolException('Could not mount ${t.label} image: $e');
    }
  }

  /// Every file as a ZIP, directories included as entries.
  Uint8List toZip() {
    final archive = Archive();
    for (final e in entries) {
      if (e.isDir) {
        archive.add(ArchiveFile.directory('${e.path}/'));
      } else {
        archive.add(ArchiveFile.bytes(e.path, read(e.path)));
      }
    }
    return ZipEncoder().encodeBytes(archive);
  }
}

/// Build a whole image of exactly [size] bytes. LittleFS images can't be
/// built yet (the writer isn't ported), so that throws.
Uint8List createFs(FsType type, List<FsSource> sources, int size) {
  try {
    return switch (type) {
      FsType.spiffs => spiffsCreate([for (final s in sources) (path: s.path, bytes: s.bytes)], size),
      FsType.fatfs => fatCreate(sources, size),
      FsType.littlefs => throw IdfToolException('Building LittleFS images is not supported yet; flash a prebuilt image instead'),
    };
  } on IdfToolException {
    rethrow;
  } catch (e) {
    throw IdfToolException('Could not build ${type.label} image: $e');
  }
}

/// What [editFsImage] did.
typedef FsEditResult = ({Uint8List image, int put, int deleted, List<String> missing});

/// Rebuild [image] with [put] added or replaced and [delete] removed: every
/// file is read out, the changes applied, and a fresh image of [size] bytes
/// built. An image that is all `0xFF` (an erased partition) or `null` starts
/// empty. Paths are relative to the root; a leading `/` is ignored. Deletes
/// of paths that are not there are reported in `missing`, not errors.
FsEditResult editFsImage(
  Uint8List? image, {
  required FsType type,
  required int size,
  Map<String, Uint8List> put = const {},
  List<String> delete = const [],
}) {
  String norm(String path) => path.replaceAll(RegExp(r'^/+'), '');
  final files = <String, Uint8List>{};
  if (image != null && image.any((b) => b != 0xFF)) {
    final v = FsVolume.mount(image, type: type);
    for (final e in v.entries) {
      if (!e.isDir) files[e.path] = v.read(e.path);
    }
  }
  final missing = <String>[];
  var deleted = 0;
  for (final path in delete) {
    if (files.remove(norm(path)) == null) {
      missing.add(path);
    } else {
      deleted++;
    }
  }
  for (final MapEntry(key: path, value: bytes) in put.entries) {
    if (norm(path).isEmpty) throw IdfToolException('A file to put needs a path');
    files[norm(path)] = bytes;
  }
  final rebuilt = createFs(type, [for (final e in files.entries) (path: e.key, bytes: e.value, modified: null)], size);
  return (image: rebuilt, put: put.length, deleted: deleted, missing: missing);
}

/// The files in a ZIP as sources for [createFs] (directories are implied by
/// paths; empty directories are dropped, as SPIFFS has none anyway).
List<FsSource> sourcesFromZip(Uint8List zip) {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(zip, verify: true);
  } catch (e) {
    throw IdfToolException('Not a valid ZIP archive: $e');
  }
  return [
    for (final f in archive.files)
      if (f.isFile)
        (
          path: f.name.replaceAll(RegExp(r'^/+'), ''),
          bytes: f.readBytes()!,
          modified: f.lastModTime == 0 ? null : DateTime.fromMillisecondsSinceEpoch(f.lastModTime * 1000),
        ),
  ];
}

/// Render a listing as a table in the same style as the partition table
/// (python idftool's `format_listing`).
String formatFsListing(List<FsEntry> entries) {
  if (entries.isEmpty) return '(empty)';
  final width = entries.map((e) => e.path.length).reduce((a, b) => a > b ? a : b) + 1;
  final sorted = List.of(entries)..sort((a, b) => a.path.compareTo(b.path));
  final lines = [
    '| ${'Path'.padRight(width)}| ${'Size'.padLeft(9)} |',
    '|${'-' * (width + 1)}|${'-' * 11}|',
    for (final e in sorted) '| ${e.path.padRight(width)}| ${(e.isDir ? '<dir>' : '${e.size}').padLeft(9)} |',
  ];
  final files = entries.where((e) => !e.isDir).length;
  final total = entries.where((e) => !e.isDir).fold(0, (n, e) => n + e.size);
  final dirs = entries.length - files;
  var summary = '$files file${files == 1 ? '' : 's'}, $total bytes';
  if (dirs > 0) summary += ', $dirs director${dirs == 1 ? 'y' : 'ies'}';
  return [...lines, summary].join('\n');
}

class _LittleFs extends FsVolume {
  _LittleFs(this._v);
  final LittleFsVolume _v;
  @override
  FsType get type => FsType.littlefs;
  @override
  List<FsEntry> get entries => [for (final e in _v.entries) FsEntry(path: e.path, isDir: e.isDir, size: e.size)];
  @override
  Uint8List read(String path) => _v.read(path);
  @override
  List<String> get errors => _v.errors;
  @override
  String describe() {
    final g = _v.geometry;
    return 'littlefs: block size ${g.blockSize}, ${g.blockCount} blocks, name_max ${g.nameMax}';
  }
}

class _Spiffs extends FsVolume {
  _Spiffs(this._v);
  final SpiffsVolume _v;
  @override
  FsType get type => FsType.spiffs;
  @override
  List<FsEntry> get entries => [for (final e in _v.entries) FsEntry(path: e.path, isDir: false, size: e.size)];
  @override
  Uint8List read(String path) => _v.read(path);
  @override
  List<String> get errors => _v.errors;
  @override
  String describe() => 'spiffs';
}

class _Fat extends FsVolume {
  _Fat(this._v);
  final FatVolume _v;
  @override
  FsType get type => FsType.fatfs;
  @override
  List<FsEntry> get entries =>
      [for (final e in _v.entries) FsEntry(path: e.path, isDir: e.isDir, size: e.size, modified: e.modified)];
  @override
  Uint8List read(String path) => _v.read(path);
  @override
  List<String> get errors => _v.errors;
  @override
  String describe() {
    final g = _v.geometry;
    return 'fat${g.bits}: sector size ${g.sectorSize}, ${g.sectorsPerCluster} sectors/cluster, ${g.clusterCount} clusters';
  }
}
