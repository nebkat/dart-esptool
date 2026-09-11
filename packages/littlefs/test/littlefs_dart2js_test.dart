@TestOn('browser')
library;

// Reading must work when compiled to JavaScript (the web app), where ints are
// doubles and bit operations are 32-bit. The fixtures are the same
// littlefs-written images as the VM tests use, inlined as base64 by
// test/fixtures/generate.py because there is no dart:io here.
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:littlefs/littlefs.dart';
import 'package:test/test.dart';

import 'dart2js_fixtures.dart';

Uint8List _gunzip(String key) => Uint8List.fromList(GZipDecoder().decodeBytes(base64Decode(dart2jsFixtures[key]!)));

Map<String, Uint8List?> _extracted(String name) => {
      for (final file in TarDecoder().decodeBytes(_gunzip('$name.tar.gz')).files)
        file.name.replaceAll(RegExp(r'^\./|/$'), ''): file.isFile ? Uint8List.fromList(file.content) : null,
    };

String _listing(LittleFsVolume volume) => volume.entries.map((e) => '${e.path}\t${e.isDir ? 'dir' : e.size}\n').join();

void _checkAgainstOracle(LittleFsVolume volume, String name, {Set<String> ignore = const {}}) {
  final expected = utf8
      .decode(base64Decode(dart2jsFixtures['$name.list.txt']!))
      .split('\n')
      .where((l) => l.isNotEmpty && !ignore.contains(l.split('\t').first))
      .map((l) => '$l\n')
      .join();
  expect(_listing(volume), expected);
  final extracted = _extracted(name)..removeWhere((path, _) => ignore.contains(path));
  for (final entry in volume.entries.where((e) => !e.isDir)) {
    expect(volume.read(entry.path), extracted[entry.path], reason: entry.path);
  }
  expect(extracted.keys.toSet(), volume.entries.map((e) => e.path).toSet());
}

void main() {
  test('reads an idftool create-fs image', () {
    final image = _gunzip('small.bin.gz');
    expect(LittleFsVolume.detect(image), isTrue);
    final volume = LittleFsVolume.mount(image, strict: true);
    expect(volume.geometry.blockSize, 4096);
    expect(volume.geometry.blockCount, 8);
    expect(volume.geometry.versionString, '2.1');
    _checkAgainstOracle(volume, 'small');
  });

  test('reads a multi-commit log with 512-byte blocks and a long CTZ file', () {
    final volume = LittleFsVolume.mount(_gunzip('log_prog16.bin.gz'), strict: true);
    expect(volume.geometry.blockSize, 512);
    expect(volume.read('long.txt').length, 30000);
    _checkAgainstOracle(volume, 'log_prog16');
  });

  test('finds the superblock in block 1 when block 0 is erased', () {
    final image = _gunzip('stale0_erased.bin.gz');
    expect(sniffSuperblock(image)!.offset, 4096);
    _checkAgainstOracle(LittleFsVolume.mount(image, strict: true), 'stale0_erased');
  });

  test('applies a pending move from the global state', () {
    final volume = LittleFsVolume.mount(_gunzip('pending_move.bin.gz'), strict: true);
    expect(volume.entries.where((e) => e.name == 'moved.txt').map((e) => e.path), ['dst/moved.txt']);
    _checkAgainstOracle(volume, 'pending_move_recovered', ignore: {'recovered.txt'});
  });

  test('32-bit helpers behave under dart2js', () {
    expect(lfsCrc(0xFFFFFFFF, Uint8List.fromList(ascii.encode('123456789'))), 0xCBF43926 ^ 0xFFFFFFFF);
    expect(lfsSeqCompare(0, 0xFFFFFFFF), greaterThan(0));
    expect(LfsTag.isValid(0xFFFFFFFF ^ 0x7FFFFFFF), isFalse);
    expect(LfsTag.dsize(0xFFFFFFFF), 4);
    expect(lfsCtz(0x80000000), 31);
    expect(lfsPopc(0xFFFFFFFF), 32);
  });
}
