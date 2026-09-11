@TestOn('vm')
library;

// Cross-checks against the python `idftool` CLI, skipped when it is not on PATH.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fatfs/fatfs.dart';
import 'package:test/test.dart';

void main() {
  final idftool = Process.runSync('which', ['idftool']).exitCode == 0;
  final stamp = DateTime.utc(2023, 11, 21, 10, 20, 30);

  const tree = {
    'README.TXT': 'plain\n',
    'Mixed Case.txt': 'lfn\n',
    'sub/nested/deep.bin': 'deep\n',
    'sub/über.dat': 'umlaut\n',
    'sub/Longer File Name Than Thirteen.log': 'multi part\n',
    'many/': '',
  };

  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('fatfs-cli-'));
  tearDown(() => temp.deleteSync(recursive: true));

  List<FatSource> sources() => [
        for (final entry in tree.entries)
          (path: entry.key, bytes: Uint8List.fromList(utf8.encode(entry.value)), modified: stamp),
        for (var i = 0; i < 150; i++)
          (path: 'many/file $i.txt', bytes: Uint8List.fromList(utf8.encode('$i\n')), modified: stamp),
      ];

  /// Lay the tree out on disk with the pinned timestamps, for `create-fs`.
  Directory materialise() {
    final root = Directory('${temp.path}/src')..createSync();
    for (final source in sources()) {
      if (source.path.endsWith('/')) {
        Directory('${root.path}/${source.path}').createSync(recursive: true);
      } else {
        File('${root.path}/${source.path}')
          ..createSync(recursive: true)
          ..writeAsBytesSync(source.bytes);
      }
    }
    // Stamp everything at once, after all the writes that bump directory mtimes.
    // `touch -t` reads the stamp in the local zone, hence TZ=UTC.
    final all = [root, ...root.listSync(recursive: true)];
    String two(int v) => v.toString().padLeft(2, '0');
    final t =
        '${stamp.year}${two(stamp.month)}${two(stamp.day)}${two(stamp.hour)}${two(stamp.minute)}.${two(stamp.second)}';
    final touch = Process.runSync('touch', ['-t', t, for (final e in all) e.path], environment: {'TZ': 'UTC'});
    if (touch.exitCode != 0) fail('touch failed: ${touch.stderr}');
    return root;
  }

  ProcessResult run(List<String> args) {
    final result = Process.runSync('idftool', args, environment: {'TZ': 'UTC'});
    if (result.exitCode != 0) fail('idftool ${args.join(' ')} failed:\n${result.stdout}\n${result.stderr}');
    return result;
  }

  test('create-fs output is byte-identical', () {
    final root = materialise();
    final out = '${temp.path}/python.bin';
    run([
      'create-fs',
      root.path,
      '-o',
      out,
      '--type',
      'fatfs',
      '--size',
      '0x100000',
      '--fat-volume-id',
      '0x1234',
      '--fat-device-id',
      '0x5678'
    ]);
    final python = File(out).readAsBytesSync();
    // `timestamp` covers the implicitly created 'sub' and 'sub/nested', which python
    // stamps from the directories on disk.
    final dart = fatCreate(sources(), 0x100000, volumeId: 0x1234, deviceId: 0x5678, timestamp: stamp);
    expect(dart, python);

    final out512 = '${temp.path}/python512.bin';
    run([
      'create-fs',
      root.path,
      '-o',
      out512,
      '--type',
      'fatfs',
      '--size',
      '0x400000',
      '--fat-sector-size',
      '512',
      '--no-fat-wear-levelling',
      '--fat-volume-id',
      '1'
    ]);
    expect(fatCreate(sources(), 0x400000, sectorSize: 512, wearLevelling: false, volumeId: 1, timestamp: stamp),
        File(out512).readAsBytesSync());
  }, skip: idftool ? false : 'idftool CLI not on PATH');

  test('python reads a Dart image back', () {
    final image = fatCreate(sources(), 0x100000, volumeId: 1, deviceId: 2);
    final file = File('${temp.path}/dart.bin')..writeAsBytesSync(image);

    final listing = run(['print-fs', '-f', file.path]).stdout as String;
    expect(listing, contains('fatfs'));
    for (final source in sources()) {
      final path = source.path.endsWith('/') ? source.path.substring(0, source.path.length - 1) : source.path;
      expect(listing, contains('| $path '), reason: path);
    }
    expect(listing, contains('${sources().where((s) => !s.path.endsWith('/')).length} files'));

    final dest = Directory('${temp.path}/extracted');
    run(['extract-fs', '-f', file.path, dest.path]);
    for (final source in sources()) {
      if (source.path.endsWith('/')) {
        expect(Directory('${dest.path}/${source.path}').existsSync(), isTrue, reason: source.path);
      } else {
        expect(File('${dest.path}/${source.path}').readAsBytesSync(), source.bytes, reason: source.path);
      }
    }
  }, skip: idftool ? false : 'idftool CLI not on PATH');
}
