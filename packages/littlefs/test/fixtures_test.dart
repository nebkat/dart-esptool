@TestOn('vm')
library;

// Every image under test/fixtures was written by littlefs itself (through
// littlefs-python) and the expected listing and file contents come from python
// idftool, so this compares the Dart reader against the reference
// implementation rather than against itself. See fixtures/generate.py.
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:littlefs/littlefs.dart';
import 'package:test/test.dart';

final _fixtures = Directory('test/fixtures');

Uint8List _image(String name) =>
    Uint8List.fromList(GZipDecoder().decodeBytes(File('${_fixtures.path}/$name.bin.gz').readAsBytesSync()));

/// `idftool print-fs` rows as `path\t<size|dir>`, one per line, in
/// [comparePaths] order — the same shape [_listing] renders.
String _expectedListing(String name) => File('${_fixtures.path}/$name.list.txt').readAsStringSync();

String _listing(LittleFsVolume volume) => volume.entries.map((e) => '${e.path}\t${e.isDir ? 'dir' : e.size}\n').join();

Map<String, String> _geometry(String name) => {
      for (final line in File('${_fixtures.path}/$name.geom.txt').readAsLinesSync())
        if (line.contains('=')) line.split('=')[0]: line.split('=')[1],
    };

/// `idftool extract-fs` output: path to bytes for files, path to null for
/// directories.
Map<String, Uint8List?> _extracted(String name) {
  final tar =
      TarDecoder().decodeBytes(GZipDecoder().decodeBytes(File('${_fixtures.path}/$name.tar.gz').readAsBytesSync()));
  return {
    for (final file in tar.files)
      file.name.replaceAll(RegExp(r'^\./|/$'), ''): file.isFile ? Uint8List.fromList(file.content) : null,
  };
}

void _checkAgainstOracle(LittleFsVolume volume, String listingName, String tarName, {Set<String> ignore = const {}}) {
  final expected = _expectedListing(listingName)
      .split('\n')
      .where((l) => l.isNotEmpty && !ignore.contains(l.split('\t').first))
      .map((l) => '$l\n')
      .join();
  expect(_listing(volume), expected);

  final extracted = _extracted(tarName)..removeWhere((path, _) => ignore.contains(path));
  for (final entry in volume.entries) {
    if (entry.isDir) {
      expect(extracted.containsKey(entry.path), isTrue, reason: '${entry.path} should be an extracted directory');
      expect(extracted[entry.path], isNull, reason: '${entry.path} should be a directory');
      expect(() => volume.read(entry.path), throwsA(isA<LittleFsException>()));
      continue;
    }
    final bytes = extracted[entry.path];
    expect(bytes, isNotNull, reason: '${entry.path} should have been extracted');
    final read = volume.read(entry.path);
    expect(read.length, entry.size, reason: '${entry.path}: size');
    expect(read, bytes, reason: '${entry.path}: contents');
  }
  expect(extracted.keys.toSet(), volume.entries.map((e) => e.path).toSet(),
      reason: 'every extracted path should be listed');
}

void main() {
  final names = _fixtures
      .listSync()
      .map((f) => f.path.split('/').last)
      .where((f) => f.endsWith('.list.txt'))
      .map((f) => f.substring(0, f.length - '.list.txt'.length))
      .toList()
    ..sort();
  test('fixtures are generated', () => expect(names, isNotEmpty, reason: 'run test/fixtures/generate.py first'));

  // The reference's read path hides the entry after a pending move's id, so
  // its listing of the pending image is not the one to compare against; the
  // image it produced after completing the move is (minus the marker file).
  const pendingMove = 'pending_move';
  const pendingMoveRecovered = 'pending_move_recovered';

  for (final name in names) {
    if (name == pendingMove) continue;
    group(name, () {
      late final Uint8List image;
      late final LittleFsVolume volume;
      setUpAll(() {
        image = _image(name);
        volume = LittleFsVolume.mount(image);
      });

      test('is detected', () => expect(LittleFsVolume.detect(image), isTrue));

      test('mounts cleanly, strict too', () {
        expect(volume.errors, isEmpty);
        expect(() => LittleFsVolume.mount(image, strict: true), returnsNormally);
      });

      test('geometry matches the formatter', () {
        final geometry = _geometry(name);
        expect(volume.geometry.blockSize, int.parse(geometry['block_size']!));
        expect(volume.geometry.blockCount, int.parse(geometry['block_count']!));
        expect(volume.geometry.nameMax, int.parse(geometry['name_max']!));
        expect(volume.geometry.diskVersion, int.parse(geometry['disk_version']!));
        expect(volume.geometry.versionMajor, 2);
        expect(volume.geometry.size, lessThanOrEqualTo(image.length));
      });

      test('listing and contents match idftool', () => _checkAgainstOracle(volume, name, name));

      test('mounts with an explicit block size', () {
        final explicit = LittleFsVolume.mount(image, blockSize: volume.geometry.blockSize);
        expect(_listing(explicit), _listing(volume));
      });
    });
  }

  group(pendingMove, () {
    test('lists the moved entry once, at its destination, and keeps its neighbours', () {
      final volume = LittleFsVolume.mount(_image(pendingMove), strict: true);
      expect(volume.errors, isEmpty);
      // The interrupted rename left the file physically in both directories;
      // only the global state says the source copy is dead.
      expect(volume.entries.where((e) => e.name == 'moved.txt').map((e) => e.path), ['dst/moved.txt']);
      expect(volume.entries.map((e) => e.path), contains('src/stays.txt'));
      _checkAgainstOracle(volume, pendingMoveRecovered, pendingMoveRecovered, ignore: {'recovered.txt'});
    });

    test('the reference hides the entry after the moved id until it completes the move', () {
      // Documents the divergence: python's listing of the pending image.
      expect(_expectedListing(pendingMove), isNot(contains('src/stays.txt')));
      expect(_expectedListing(pendingMoveRecovered), contains('src/stays.txt'));
    });
  });

  group('stale block 0', () {
    test('erased block 0 mounts from block 1 and is detected by probing block sizes', () {
      final image = _image('stale0_erased');
      expect(image.sublist(0, 4096).every((b) => b == 0xFF), isTrue);
      expect(LittleFsVolume.detect(image), isTrue);
      expect(sniffSuperblock(image)!.offset, 4096);
    });

    test('garbage block 0 loses to the valid block 1', () {
      final image = _image('stale0_garbage');
      expect(sniffSuperblock(image)!.offset, 4096);
      final volume = LittleFsVolume.mount(image, strict: true);
      expect(volume.entries.map((e) => e.path), ['keep.txt']);
    });
  });

  group('many entries', () {
    test('the root spans several metadata pairs', () {
      final volume = LittleFsVolume.mount(_image('many'), strict: true);
      expect(volume.entries.where((e) => !e.isDir && !e.path.contains('/')).length, 300);
      expect(volume.entries.where((e) => e.path.startsWith('sub/')).length, 151);
      expect(volume.entries.where((e) => e.isDir).length, 22);
    });
  });

  group('large files', () {
    test('multi-level CTZ skip-lists read back exactly', () {
      final volume = LittleFsVolume.mount(_image('large'), strict: true);
      final big = volume.read('big300k.txt');
      expect(big.length, 300 * 1024);
      expect(String.fromCharCodes(big.sublist(0, 21)), 'big300k line 00000000');
      // The last block is the head of the skip-list; its data is the tail of the file.
      expect(String.fromCharCodes(big).trimRight().split('\n').last, startsWith('big300k line '));
      expect(volume.entries.firstWhere((e) => e.path == 'big300k.txt').size, 300 * 1024);
    });
  });
}
