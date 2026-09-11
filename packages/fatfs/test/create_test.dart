@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fatfs/fatfs.dart';
import 'package:test/test.dart';

import 'fixture.dart';

void main() {
  final fixtures = Fixture.loadAll();
  final stamp = DateTime.utc(2024, 3, 5, 6, 7, 8);

  FatSource file(String path, String text) =>
      (path: path, bytes: Uint8List.fromList(utf8.encode(text)), modified: null);

  group('fatCreate', () {
    for (final fixture in fixtures) {
      test('${fixture.name}: byte-identical to python', () {
        final image = fixture.create();
        final expected = fixture.image;
        expect(image.length, expected.length);
        for (var i = 0; i < image.length; i++) {
          if (image[i] != expected[i]) {
            fail('first difference at byte 0x${i.toRadixString(16)}: '
                'dart 0x${image[i].toRadixString(16)}, python 0x${expected[i].toRadixString(16)}');
          }
        }
      });
    }

    test('round trips through mount', () {
      final sources = [
        file('hello.txt', 'hello\n'),
        file('Mixed Case Name.md', '# hi\n'),
        (path: 'data/big.bin', bytes: Uint8List.fromList([for (var i = 0; i < 20000; i++) i & 0xFF]), modified: stamp),
        file('data/nested/deeper/x', ''),
        (path: 'empty/', bytes: Uint8List(0), modified: null),
      ];
      final image = fatCreate(sources, 0x40000, timestamp: stamp, volumeId: 1, deviceId: 2);
      expect(image.length, 0x40000);
      expect(FatVolume.detect(image), isTrue);
      final volume = FatVolume.mount(image, strict: true);
      expect(volume.entries.map((e) => e.path).toList(), [
        'Mixed Case Name.md',
        'data',
        'data/big.bin',
        'data/nested',
        'data/nested/deeper',
        'data/nested/deeper/x',
        'empty',
        'hello.txt'
      ]);
      for (final source in sources.where((s) => !s.path.endsWith('/'))) {
        expect(volume.read(source.path), source.bytes, reason: source.path);
        expect(volume.lookup(source.path)!.modified, stamp, reason: source.path);
      }
      expect(volume.lookup('empty')!.isDir, isTrue);
      expect(volume.lookup('data/nested/deeper/x')!.size, 0);
    });

    test('source order does not matter', () {
      final sources = [file('b/2.txt', '2'), file('a.txt', 'a'), file('b/1.txt', '1'), file('c/d/e.txt', 'e')];
      final image = fatCreate(sources, 0x40000, timestamp: stamp, volumeId: 1, deviceId: 2);
      expect(fatCreate(sources.reversed.toList(), 0x40000, timestamp: stamp, volumeId: 1, deviceId: 2), image);
    });

    test('random ids by default, fixed ones reproduce', () {
      final a = fatCreate([file('a', 'a')], 0x40000, timestamp: stamp);
      final b = fatCreate([file('a', 'a')], 0x40000, timestamp: stamp);
      expect(a, isNot(equals(b)));
      expect(FatVolume.mount(a).geometry.volumeId, isNot(FatVolume.mount(b).geometry.volumeId));
      expect(fatCreate([file('a', 'a')], 0x40000, timestamp: stamp, volumeId: 5, deviceId: 6),
          fatCreate([file('a', 'a')], 0x40000, timestamp: stamp, volumeId: 5, deviceId: 6));
    });

    test('without wear levelling the image is the bare filesystem', () {
      final image = fatCreate([file('a', 'a')], 0x40000, wearLevelling: false, volumeId: 1);
      expect(looksLikeWl(image), isFalse);
      expect(image[510], 0x55);
      final volume = FatVolume.mount(image);
      expect(volume.geometry.clusterCount, 57);
      expect(volume.geometry.size, 0x40000);
      expect(volume.read('a'), 'a'.codeUnits);
    });

    test('label and geometry options', () {
      final image = fatCreate([], 0x400000,
          wearLevelling: false, sectorSize: 512, sectorsPerCluster: 8, label: 'MYLABEL', volumeId: 1);
      final geometry = FatVolume.mount(image).geometry;
      expect(geometry.label, 'MYLABEL');
      expect(geometry.sectorSize, 512);
      expect(geometry.sectorsPerCluster, 8);
      expect(geometry.bits, FatBits.fat12);
      expect(() => fatCreate([], 0x40000, label: 'é'), throwsA(isA<FatException>()));
      expect(FatVolume.mount(fatCreate([], 0x40000, label: 'a very long label indeed')).geometry.label, 'a very long');
    });

    test('forced FAT type', () {
      expect(FatVolume.mount(fatCreate([], 0x400000, sectorSize: 512, fatBits: 16)).geometry.bits, FatBits.fat16);
      expect(() => fatCreate([], 0x400000, fatBits: 16), throwsA(isA<FatException>())); // too few clusters
      expect(() => fatCreate([], 0x400000, fatBits: 32), throwsA(isA<FatException>()));
    });

    test('too much data', () {
      final big = Uint8List(0x40000);
      expect(() => fatCreate([(path: 'big', bytes: big, modified: null)], 0x40000),
          throwsA(isA<FatException>().having((e) => e.message, 'message', contains('do not fit'))));
      // Exactly filling the volume is fine.
      final image =
          fatCreate([(path: 'big', bytes: Uint8List(57 * 4096), modified: null)], 0x40000, wearLevelling: false);
      final volume = FatVolume.mount(image, strict: true);
      expect(volume.freeClusters, 0);
      expect(volume.read('big').length, 57 * 4096);
      expect(
          () => fatCreate([(path: 'big', bytes: Uint8List(57 * 4096 + 1), modified: null)], 0x40000,
              wearLevelling: false),
          throwsA(isA<FatException>()));
    });

    test('a full root directory is an error, a full subdirectory grows', () {
      // 512 root entries; each long name takes at least two.
      final sources = [for (var i = 0; i < 300; i++) file('long name $i.txt', '$i')];
      expect(() => fatCreate(sources, 0x400000),
          throwsA(isA<FatException>().having((e) => e.message, 'message', contains('root'))));
      final nested = [for (final s in sources) (path: 'dir/${s.path}', bytes: s.bytes, modified: s.modified)];
      final volume = FatVolume.mount(fatCreate(nested, 0x400000), strict: true);
      expect(volume.entries.length, 301);
      expect(volume.clusterChain(volume.lookup('dir')!.firstCluster).length, greaterThan(1));
    });

    test('a partition too small for anything', () {
      expect(() => fatCreate([], 0x8000), throwsA(isA<FatException>()));
      expect(() => fatCreate([], 0x4000), throwsA(isA<WearLevellingException>()));
      expect(() => fatCreate([], 0x40100), throwsA(isA<WearLevellingException>()));
      expect(() => fatCreate([], 0x40100, wearLevelling: false), throwsA(isA<FatException>()));
    });

    test('rejects bad sources', () {
      expect(() => fatCreate([file('', 'x')], 0x40000), throwsA(isA<FatException>()));
      expect(() => fatCreate([file('/', 'x')], 0x40000), throwsA(isA<FatException>()));
      expect(() => fatCreate([file('a//b', 'x')], 0x40000), throwsA(isA<FatException>()));
      expect(() => fatCreate([file('../b', 'x')], 0x40000), throwsA(isA<FatException>()));
      expect(() => fatCreate([file('a', 'x'), file('a', 'y')], 0x40000), throwsA(isA<FatException>()));
      expect(() => fatCreate([file('a', 'x'), file('a/b', 'y')], 0x40000), throwsA(isA<FatException>()));
      expect(() => fatCreate([file('d/', 'x')], 0x40000), throwsA(isA<FatException>()));
      expect(() => fatCreate([file('a', 'x')], 0x40000, timestamp: DateTime.utc(1979)), throwsA(isA<FatException>()));
      // A directory listed twice, or alongside its contents, is fine.
      final image = fatCreate([file('d/', ''), file('d/', ''), file('d/x', 'x'), file('/lead', 'l')], 0x40000);
      expect(FatVolume.mount(image, strict: true).entries.map((e) => e.path), ['d', 'd/x', 'lead']);
    });

    test('names that cannot be shortened', () {
      expect(() => fatCreate([file('   ', 'x')], 0x40000), throwsA(isA<FatException>()));
      expect(() => fatCreate([file(' .txt', 'x')], 0x40000), throwsA(isA<FatException>()));
      expect(() => fatCreate([file('x' * 256, 'x')], 0x40000), throwsA(isA<FatException>()));
      final long = 'x' * 255;
      expect(FatVolume.mount(fatCreate([file(long, 'x')], 0x40000), strict: true).entries.single.path, long);
    });

    test('8.3 derivation matches pyfatfs', () {
      String short(String name, [Set<String> taken = const {}]) => latin1.decode(make8dot3Name(name, taken));
      expect(short('README.TXT'), 'README  TXT');
      expect(short('readme.txt'), 'README  TXT');
      expect(short('readme.txt', {'README.TXT'}), 'README~1TXT');
      expect(short('readme.txt', {'README.TXT', 'README~1.TXT'}), 'README~2TXT');
      expect(short('Hello World.txt'), 'HELLOWO TXT');
      expect(short('a_very_long_file_name_with_many_characters.log'), 'A_VERY_LLOG');
      expect(short('.hidden'), '_HIDDEN    ');
      expect(short('dots.in.name.txt'), 'DOTS_IN_TXT');
      expect(short('trailing.'), 'TRAILING   ');
      expect(short('..foo'), '__FOO      ');
      expect(short('a+b=c;d.tar.gz'), 'A_B_C_D_GZ ');
      expect(short('longname1.txt', {'LONGNAME.TXT', for (var i = 1; i < 10; i++) 'LONGNA~$i.TXT'}), 'LONGN~10TXT');
      expect(short('Straße.txt'), 'STRASSE TXT');
      expect(short('ﬂ.ﬁ'), 'FL      FI ');
      expect(short('\u{1F600}'), '_          ');
      expect(short('Ünïcödé.txt'), '\x9AN_C\x99D\x90 TXT'); // cp437 Ü, Ö, É; Ï has no cp437 form and becomes _
      expect(short('Ü'), '\x9A          ');
    });

    test('names that are already 8.3 get no long name, others do', () {
      final image =
          fatCreate([file('PLAIN.TXT', 'a'), file('plain2.txt', 'b'), file('Ü', 'c'), file('A B', 'd')], 0x40000);
      final volume = FatVolume.mount(image, strict: true);
      expect(volume.entries.map((e) => e.path), ['A B', 'PLAIN.TXT', 'plain2.txt', 'Ü']);
      expect(volume.lookup('Ü')!.shortName, 'Ü'); // stored in cp437 without a long name
      expect(volume.lookup('A B')!.shortName, 'AB');
    });
  });

  group('solveGeometry', () {
    final cases = jsonDecode(File('${fixturesDir.path}/geometries.json').readAsStringSync()) as List;
    for (final c in cases) {
      final size = c['size'] as int, sectorSize = c['sector_size'] as int, spc = c['sectors_per_cluster'] as int;
      final fatType = c['fat_type'] as int?;
      test('0x${size.toRadixString(16)} / $sectorSize × $spc${fatType == null ? '' : ' forced $fatType'}', () {
        FatGeometry solve() => solveGeometry(size, sectorSize: sectorSize, sectorsPerCluster: spc, fatBits: fatType);
        final expected = c['geometry'] as Map<String, dynamic>?;
        if (expected == null) {
          expect(solve, throwsA(isA<FatException>()), reason: c['error'] as String);
        } else {
          final g = solve();
          expect((g.bits.bits, g.fatSectors, g.clusterCount),
              (expected['bits'], expected['fat_size'], expected['clusters']));
          // The solved geometry survives a trip through a boot sector.
          final image = fatCreate([], size,
              wearLevelling: false, sectorSize: sectorSize, sectorsPerCluster: spc, fatBits: fatType);
          final parsed = FatVolume.mount(image, wearLevelling: false, strict: true).geometry;
          expect((parsed.bits, parsed.fatSectors, parsed.clusterCount), (g.bits, g.fatSectors, g.clusterCount));
        }
      });
    }
  });
}
