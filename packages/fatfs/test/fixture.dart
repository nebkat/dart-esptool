/// Loading the python-generated fixtures under `test/fixtures/`.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:fatfs/fatfs.dart';

final Directory fixturesDir = Directory('${Directory.current.path}/test/fixtures');

/// One `create-fs` run: what went in, how, and what python read back.
class Fixture {
  Fixture(this.name, Map<String, dynamic> json)
      : size = json['size'] as int,
        options = json['options'] as Map<String, dynamic>,
        geometry = json['geometry'] as String,
        sources = [
          for (final s in json['sources'] as List)
            (
              path: (s['is_dir'] as bool) ? '${s['path']}/' : s['path'] as String,
              bytes: s['data'] == null ? Uint8List(0) : base64Decode(s['data'] as String),
              modified: DateTime.fromMillisecondsSinceEpoch((s['mtime'] as int) * 1000, isUtc: true),
            ),
        ],
        entries = [
          for (final e in json['entries'] as List)
            (
              path: e['path'] as String,
              isDir: e['is_dir'] as bool,
              size: e['size'] as int,
              sha256: e['sha256'] as String?
            ),
        ];

  static Fixture load(String name) =>
      Fixture(name, jsonDecode(File('${fixturesDir.path}/$name.json').readAsStringSync()) as Map<String, dynamic>);

  /// Every fixture that has a `.json` next to its image.
  static List<Fixture> loadAll() => [
        for (final file in fixturesDir.listSync().whereType<File>())
          if (file.path.endsWith('.json') && !file.path.endsWith('geometries.json'))
            load(file.uri.pathSegments.last.replaceAll('.json', '')),
      ]..sort((a, b) => a.name.compareTo(b.name));

  final String name;
  final int size;
  final Map<String, dynamic> options;
  final String geometry;
  final List<FatSource> sources;
  final List<({String path, bool isDir, int size, String? sha256})> entries;

  bool get wearLevelling => options['wear_levelling'] as bool? ?? true;
  int get sectorSize => options['sector_size'] as int? ?? FatLayout.defaultSectorSize;
  int? get sectorsPerCluster => options['sectors_per_cluster'] as int?;
  int? get fatType => options['fat_type'] as int?;
  int get volumeId => options['volume_id'] as int;
  int get deviceId => options['device_id'] as int;

  /// The image python's `create-fs` produced.
  Uint8List get image => gunzip('$name.bin.gz');

  /// The bare filesystem python's `wl.unwrap` recovers from [image]; only
  /// for wear-levelled fixtures.
  Uint8List get rawImage => gunzip('$name.raw.bin.gz');

  /// The bytes of the source file at [path].
  Uint8List sourceBytes(String path) => sources.firstWhere((s) => s.path == path).bytes;

  /// Build the same image with Dart.
  Uint8List create() => fatCreate(
        sources,
        size,
        wearLevelling: wearLevelling,
        sectorSize: sectorSize,
        sectorsPerCluster: sectorsPerCluster,
        fatBits: fatType,
        volumeId: volumeId,
        deviceId: deviceId,
      );
}

Uint8List gunzip(String file) =>
    Uint8List.fromList(const GZipDecoder().decodeBytes(File('${fixturesDir.path}/$file').readAsBytesSync()));
