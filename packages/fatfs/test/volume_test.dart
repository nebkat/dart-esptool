@TestOn('vm')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fatfs/fatfs.dart';
import 'package:test/test.dart';

import 'fixture.dart';

void main() {
  final fixtures = Fixture.loadAll();

  group('mount', () {
    for (final fixture in fixtures) {
      test('${fixture.name}: listing and contents match python', () {
        final volume = FatVolume.mount(fixture.image, strict: true);
        expect(volume.errors, isEmpty);
        expect(fixture.geometry, startsWith(volume.geometry.toString()));
        expect(volume.geometry.label, 'Espressif');
        expect(volume.geometry.volumeId, fixture.volumeId);
        expect(volume.geometry.oemName, 'MSDOS5.0');

        final listing = [for (final e in volume.entries) (path: e.path, isDir: e.isDir, size: e.size)]
          ..sort((a, b) => a.path.compareTo(b.path));
        final expected = [for (final e in fixture.entries) (path: e.path, isDir: e.isDir, size: e.size)]
          ..sort((a, b) => a.path.compareTo(b.path));
        expect(listing, expected);

        for (final entry in fixture.entries.where((e) => !e.isDir)) {
          final bytes = volume.read(entry.path);
          expect(sha256.convert(bytes).toString(), entry.sha256, reason: entry.path);
          expect(bytes, fixture.sourceBytes(entry.path), reason: entry.path);
        }
        expect(volume.errors, isEmpty);
      });
    }

    test('entries are depth first with siblings in code-point order', () {
      final volume = FatVolume.mount(Fixture.load('basic_256k_wl').image);
      final paths = volume.entries.map((e) => e.path).toList();
      expect(paths.indexOf('dir1/inner.txt'), volume.entries.indexWhere((e) => e.path == 'dir1') + 1);
      expect(paths.indexOf('dir1/sub/deep/deeper/deepest/file.txt'), paths.indexOf('dir1/sub/deep/deeper/deepest') + 1);
      // The whole dir1 subtree precedes its next sibling.
      final dir1 = paths.indexOf('dir1'), next = paths.indexWhere((p) => !p.startsWith('dir1'), dir1);
      expect(paths.sublist(dir1, next).every((p) => p.startsWith('dir1')), isTrue);
      // Names compare by code point: uppercase before lowercase before non-ASCII.
      expect(paths.indexOf('README.TXT'), lessThan(paths.indexOf('read me.txt')));
      expect(paths.indexOf('x'), lessThan(paths.indexOf('файл.txt')));
    });

    test('exposes short names, attributes and timestamps', () {
      final fixture = Fixture.load('basic_256k_raw');
      final volume = FatVolume.mount(fixture.image);
      FatEntry entry(String path) => volume.lookup(path)!;

      expect(entry('README.TXT').shortName, 'README.TXT');
      expect(entry('read me.txt').shortName, 'README~1.TXT');
      expect(entry('Hello World.txt').shortName, 'HELLOWO.TXT');
      expect(entry('héllo wörld.txt').shortName, 'HÉLLOWÖ.TXT');
      expect(entry('файл.txt').shortName, '____.TXT');
      expect(entry('\u{1F600} emoji.txt').shortName, '_EMOJI.TXT');
      // Created in path order: the literal LONGNA~4.TXT comes first (upper case sorts
      // first), then longname1 takes LONGNAME.TXT itself and the rest count up past ~4.
      expect(entry('longname1.txt').shortName, 'LONGNAME.TXT');
      expect(entry('longname2.txt').shortName, 'LONGNA~1.TXT');
      expect(entry('longname4.txt').shortName, 'LONGNA~3.TXT');
      expect(entry('longname5.txt').shortName, 'LONGNA~5.TXT');
      expect(entry('.hidden').shortName, '_HIDDEN');
      expect(entry('dots.in.name.txt').shortName, 'DOTS_IN_.TXT');
      expect(entry('Straße.txt').shortName, 'STRASSE.TXT');
      expect(entry('ﬁle.txt').shortName, 'FILE.TXT');
      expect(entry('Long Directory Name').shortName, 'LONGDIR');
      expect(entry('dir1').attributes, FatAttr.directory);
      expect(entry('x').attributes, FatAttr.archive);
      expect(entry('x').name, 'x');
      expect(entry('dir1/sub/deep/deeper/deepest/file.txt').name, 'file.txt');

      for (final source in fixture.sources) {
        final path = source.path.endsWith('/') ? source.path.substring(0, source.path.length - 1) : source.path;
        final modified = source.modified!;
        // DOS time has two-second resolution.
        final expected = DateTime.utc(
            modified.year, modified.month, modified.day, modified.hour, modified.minute, modified.second & ~1);
        expect(entry(path).modified, expected, reason: path);
      }
    });

    test('a wear-levelled image can be mounted as a bare filesystem via its raw form', () {
      final fixture = Fixture.load('basic_256k_wl');
      final raw = FatVolume.mount(fixture.rawImage, wearLevelling: false);
      expect(raw.entries.length, fixture.entries.length);
      // The container itself is not a FAT filesystem.
      expect(() => FatVolume.mount(fixture.image, wearLevelling: false), throwsA(isA<FatException>()));
    });

    test('read errors', () {
      final volume = FatVolume.mount(Fixture.load('basic_256k_wl').image);
      expect(() => volume.read('missing.txt'), throwsA(isA<FatException>()));
      expect(() => volume.read('dir1'), throwsA(isA<FatException>()));
      expect(volume.read('/README.TXT'), volume.read('README.TXT'));
      expect(volume.read('empty.bin'), isEmpty);
      expect(volume.lookup('dir1/'), isNotNull);
    });

    test('free clusters add up', () {
      final fixture = Fixture.load('spanning_1m_wl');
      final volume = FatVolume.mount(fixture.image);
      var used = 0;
      for (final source in fixture.sources) {
        used += (source.bytes.length + 4095) ~/ 4096;
      }
      expect(volume.freeClusters, volume.geometry.clusterCount - used);
    });
  });

  group('detect', () {
    test('recognises FAT images with and without wear levelling', () {
      for (final fixture in fixtures) {
        expect(FatVolume.detect(fixture.image), isTrue, reason: fixture.name);
        if (fixture.wearLevelling) expect(FatVolume.detect(fixture.rawImage), isTrue, reason: fixture.name);
      }
    });

    test('rejects other things', () {
      expect(FatVolume.detect(Uint8List(0)), isFalse);
      expect(FatVolume.detect(Uint8List(0x40000)), isFalse);
      expect(FatVolume.detect(Uint8List(0x40000)..fillRange(0, 0x40000, 0xFF)), isFalse);
      final almost = Uint8List(1024)
        ..[510] = 0x55
        ..[511] = 0xAA;
      expect(FatVolume.detect(almost), isFalse); // signature but no BPB
      // A wear levelling container around garbage.
      expect(FatVolume.detect(wlWrap(Uint8List(0x1000), 0x40000, deviceId: 1)), isFalse);
    });
  });

  group('damage', () {
    Uint8List broken(void Function(Uint8List image, FatVolume volume) damage) {
      final image = Uint8List.fromList(Fixture.load('basic_256k_raw').image);
      damage(image, FatVolume.mount(image, wearLevelling: false));
      return image;
    }

    test('a bad long name checksum falls back to the short name', () {
      final image = broken((image, volume) {
        // The first LFN part in the root directory belongs to '.hidden', the first entry created.
        final root = volume.geometry.rootDirOffset;
        for (var offset = root; offset < root + volume.geometry.rootDirBytes; offset += 32) {
          if (FatAttr.isLongName(image[offset + 11])) {
            image[offset + 13] ^= 0xFF;
            break;
          }
        }
      });
      final volume = FatVolume.mount(image, wearLevelling: false);
      expect(volume.errors, hasLength(1));
      expect(volume.errors.single, contains('checksum'));
      expect(volume.entries.map((e) => e.path), contains('_HIDDEN'));
      expect(volume.entries.map((e) => e.path), isNot(contains('.hidden')));
      expect(() => FatVolume.mount(image, wearLevelling: false, strict: true), throwsA(isA<FatException>()));
    });

    test('a truncated cluster chain is reported', () {
      late String path;
      final image = broken((image, volume) {
        final entry = volume.lookup('onecluster.bin')!;
        path = entry.path;
        // Mark the file's only cluster free in both FATs.
        for (var copy = 0; copy < volume.geometry.fatCount; copy++) {
          volume.geometry.bits
              .write(Uint8List.sublistView(image, volume.geometry.fatOffset(copy)), entry.firstCluster, 0);
        }
      });
      final volume = FatVolume.mount(image, wearLevelling: false);
      expect(volume.errors, isEmpty);
      final bytes = volume.read(path);
      expect(bytes.length, 4096); // the first cluster is still handed back
      expect(volume.errors, hasLength(1));
      expect(volume.errors.single, contains('free cluster'));
    });

    test('differing FAT copies are noted', () {
      final image = broken((image, volume) => image[volume.geometry.fatOffset(1) + 100] ^= 0xFF);
      expect(FatVolume.mount(image, wearLevelling: false).errors.single, contains('FAT copy 1 differs'));
    });

    test('a deleted entry disappears', () {
      final image = broken((image, volume) {
        final root = volume.geometry.rootDirOffset;
        for (var offset = root; offset < root + volume.geometry.rootDirBytes; offset += 32) {
          if (latin1.decode(image.sublist(offset, offset + 11)) == 'README  TXT') {
            image[offset] = FatLayout.deletedEntry;
            break;
          }
        }
      });
      final volume = FatVolume.mount(image, wearLevelling: false, strict: true);
      expect(volume.entries.map((e) => e.path), isNot(contains('README.TXT')));
      expect(volume.entries.map((e) => e.path), contains('read me.txt'));
    });

    test('not a FAT image', () {
      expect(() => FatVolume.mount(Uint8List(0x40000)), throwsA(isA<FatException>()));
      expect(() => FatVolume.mount(Uint8List(100)), throwsA(isA<FatException>()));
    });
  });
}
