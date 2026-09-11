/// Helpers for the fixture cases under `test/fixtures/`, produced by
/// `generate.py` with the python idftool CLI.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:spiffs/spiffs.dart';

final Directory fixturesDir = Directory('${Directory.current.path}/test/fixtures');

class FixtureCase {
  FixtureCase(this.name, this.dir);
  final String name;
  final Directory dir;

  late final Map<String, dynamic> _config = jsonDecode(File('${dir.path}/config.json').readAsStringSync());

  int get size => _config['size'] as int;
  List<String> get options => (_config['options'] as List).cast<String>();

  /// The `--spiffs-*` options as a [SpiffsConfig].
  SpiffsConfig get config => configFromOptions(options);

  Uint8List get image {
    final gz = File('${dir.path}/image.bin.gz').readAsBytesSync();
    return Uint8List.fromList(const GZipDecoder().decodeBytes(gz));
  }

  /// `print-fs` rows as path → size.
  Map<String, int> get listing {
    final rows = <String, int>{};
    for (final line in File('${dir.path}/listing.txt').readAsLinesSync()) {
      final match = RegExp(r'^\| (.*?)\s*\|\s*(\d+) \|$').firstMatch(line);
      if (match != null) rows[match.group(1)!] = int.parse(match.group(2)!);
    }
    return rows;
  }

  /// The packed tree, path → contents. Git does not keep empty directories, so a
  /// missing `src/` is the empty case.
  Map<String, Uint8List> get sourceFiles => readTree(Directory('${dir.path}/src'));

  /// The tree in the order the python CLI adds files (parents first, sorted).
  List<SpiffsSource> get sources => collectOrder(sourceFiles);

  static List<FixtureCase> all() => [
        for (final entry in fixturesDir.listSync().whereType<Directory>())
          if (File('${entry.path}/config.json').existsSync()) FixtureCase(entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty), entry),
      ]..sort((a, b) => a.name.compareTo(b.name));
}

SpiffsConfig configFromOptions(List<String> options) {
  var config = SpiffsConfig.defaults;
  for (var i = 0; i < options.length; i++) {
    int value() => int.parse(options[++i]);
    config = switch (options[i]) {
      '--spiffs-page-size' => config.copyWith(pageSize: value()),
      '--spiffs-block-size' => config.copyWith(blockSize: value()),
      '--spiffs-obj-name-len' => config.copyWith(objNameLen: value()),
      '--spiffs-meta-len' => config.copyWith(metaLen: value()),
      '--spiffs-use-magic' => config.copyWith(useMagic: true),
      '--no-spiffs-use-magic' => config.copyWith(useMagic: false),
      '--spiffs-use-magic-len' => config.copyWith(useMagicLen: true),
      '--no-spiffs-use-magic-len' => config.copyWith(useMagicLen: false),
      final other => throw ArgumentError('unknown option $other'),
    };
  }
  return config;
}

Map<String, Uint8List> readTree(Directory root) {
  if (!root.existsSync()) return {};
  final files = <String, Uint8List>{};
  for (final entity in root.listSync(recursive: true, followLinks: true).whereType<File>()) {
    final path = entity.path.substring(root.path.length + 1).replaceAll(Platform.pathSeparator, '/');
    files[path] = entity.readAsBytesSync();
  }
  return files;
}

/// Order files the way `idftool.fs.common.collect` does: by depth, then path.
List<SpiffsSource> collectOrder(Map<String, Uint8List> files) {
  final paths = files.keys.toList()
    ..sort((a, b) {
      final depth = '/'.allMatches(a).length.compareTo('/'.allMatches(b).length);
      return depth != 0 ? depth : a.compareTo(b);
    });
  return [for (final path in paths) (path: path, bytes: files[path]!)];
}

void writeTree(Directory root, Map<String, Uint8List> files) {
  root.createSync(recursive: true);
  for (final MapEntry(key: path, value: bytes) in files.entries) {
    File('${root.path}/$path')
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(bytes);
  }
}

/// Deterministic filler that survives dart2js (no 64-bit intermediates).
Uint8List pattern(int length, int seed) {
  final out = Uint8List(length);
  var x = (seed * 7919 + 13) & 0xFFFF;
  for (var i = 0; i < length; i++) {
    x = (x * 75 + 74) & 0xFFFF;
    out[i] = (x >> 8) & 0xFF;
  }
  return out;
}

/// Whether the python idftool CLI is available to act as an oracle.
final bool haveIdftool = () {
  try {
    return Process.runSync('idftool', ['--help']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}();

/// Run the python CLI, returning stdout; throws on failure.
String idftool(List<String> args) {
  final result = Process.runSync('idftool', args);
  if (result.exitCode != 0) {
    throw StateError('idftool ${args.join(' ')} failed (${result.exitCode}):\n${result.stdout}\n${result.stderr}');
  }
  return result.stdout as String;
}
