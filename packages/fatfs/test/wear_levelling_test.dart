@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:fatfs/fatfs.dart';
import 'package:fatfs/src/crc32.dart';
import 'package:test/test.dart';

import 'fixture.dart';

void main() {
  group('crc32', () {
    test('matches zlib.crc32(data, 0xFFFFFFFF)', () {
      // Values from python: zlib.crc32(b'123456789', 0xFFFFFFFF) etc.
      expect(wlCrc32('123456789'.codeUnits), 0xD202D277);
      expect(wlCrc32([]), 0xFFFFFFFF);
      expect(wlCrc32([0, 0, 0, 0]), 0xFFFFFFFF);
    });

    test('plain start value is the textbook CRC-32', () {
      expect(crc32('123456789'.codeUnits), 0xCBF43926);
      // A running CRC continues where the previous call left off.
      expect(crc32('6789'.codeUnits, crc32('12345'.codeUnits)), 0xCBF43926);
    });
  });

  group('filesystem size', () {
    test('overhead grows with the partition', () {
      expect(wlFilesystemSize(0x40000), 0x40000 - 0x4000); // 4 sectors
      expect(wlFilesystemSize(0x100000), 0x100000 - 0x6000); // 6 sectors
      expect(wlFilesystemSize(0x400000), 0x400000 - 0xC000); // 12 sectors
      expect(WlLayout.stateSectorsFor(0x40000), 1);
      expect(WlLayout.stateSectorsFor(0x100000), 2);
    });

    test('rejects unaligned and tiny partitions', () {
      expect(() => wlFilesystemSize(0x40001), throwsA(isA<WearLevellingException>()));
      expect(() => wlFilesystemSize(0x4000), throwsA(isA<WearLevellingException>()));
      expect(() => wlFilesystemSize(0), throwsA(isA<WearLevellingException>()));
    });
  });

  group('wrap / unwrap', () {
    Uint8List pattern(int size) => Uint8List.fromList([for (var i = 0; i < size; i++) (i * 7 + i ~/ 4096) & 0xFF]);

    test('round trips', () {
      final fs = pattern(wlFilesystemSize(0x100000));
      final image = wlWrap(fs, 0x100000, deviceId: 1);
      expect(image.length, 0x100000);
      expect(looksLikeWl(image), isTrue);
      expect(wlUnwrap(image), fs);
    });

    test('pads a short filesystem with erased flash', () {
      final image = wlWrap(pattern(0x2000), 0x40000, deviceId: 1);
      final fs = wlUnwrap(image);
      expect(fs.length, wlFilesystemSize(0x40000));
      expect(fs.sublist(0, 0x2000), pattern(0x2000));
      expect(fs.sublist(0x2000).every((b) => b == 0xFF), isTrue);
    });

    test('refuses a filesystem that does not fit', () {
      expect(() => wlWrap(pattern(0x40000), 0x40000), throwsA(isA<WearLevellingException>()));
    });

    test('is byte-identical to python', () {
      for (final fixture in Fixture.loadAll().where((f) => f.wearLevelling)) {
        final raw = fixture.rawImage;
        expect(wlWrap(raw, fixture.size, deviceId: fixture.deviceId), fixture.image, reason: fixture.name);
        expect(wlUnwrap(fixture.image), raw, reason: fixture.name);
        expect(looksLikeWl(fixture.image), isTrue, reason: fixture.name);
        expect(looksLikeWl(raw), isFalse, reason: fixture.name);
      }
    });

    test('random device id by default', () {
      final a = wlWrap(pattern(0x1000), 0x40000), b = wlWrap(pattern(0x1000), 0x40000);
      expect(a, isNot(equals(b)));
      expect(wlUnwrap(a), wlUnwrap(b));
    });

    test('follows a migrated dummy sector and a rotated filesystem', () {
      // Simulate what the driver does after some writes: the dummy sector has moved to
      // position `pos` (one state record per move) and the filesystem has been rotated
      // left `moveCount` times.
      const partitionSize = 0x100000;
      final fsSize = wlFilesystemSize(partitionSize);
      final fs = pattern(fsSize);
      final pristine = wlWrap(fs, partitionSize, deviceId: 7);
      const pos = 5, moveCount = 3;

      final rotation = moveCount * WlLayout.sectorSize;
      final rotated = Uint8List(fsSize)
        ..setRange(0, fsSize - rotation, fs, rotation)
        ..setRange(fsSize - rotation, fsSize, fs);
      final dummy = pos * WlLayout.sectorSize;
      final image = Uint8List.fromList(pristine);
      image.setRange(0, dummy, rotated);
      image.fillRange(dummy, dummy + WlLayout.sectorSize, 0xFF);
      image.setRange(dummy + WlLayout.sectorSize, fsSize + WlLayout.sectorSize, rotated, dummy);

      final copySize = WlLayout.stateSectorsFor(partitionSize) * WlLayout.sectorSize;
      final statesStart = partitionSize - WlLayout.sectorSize - WlLayout.stateCopyCount * copySize;
      for (var copy = 0; copy < WlLayout.stateCopyCount; copy++) {
        final start = statesStart + copy * copySize;
        final header = Uint8List.sublistView(image, start, start + WlLayout.stateHeaderSize);
        ByteData.sublistView(header).setUint32(8, moveCount, Endian.little);
        ByteData.sublistView(header).setUint32(
            WlLayout.stateCrcOffset, wlCrc32(Uint8List.sublistView(header, 0, WlLayout.stateCrcOffset)), Endian.little);
        for (var record = 0; record < pos; record++) {
          image.fillRange(start + WlLayout.stateHeaderSize + record * WlLayout.stateRecordSize,
              start + WlLayout.stateHeaderSize + (record + 1) * WlLayout.stateRecordSize, 0);
        }
      }

      expect(looksLikeWl(image), isTrue);
      expect(wlUnwrap(image), fs);

      // The second copy is still used if the first is damaged.
      final damaged = Uint8List.fromList(image);
      damaged[statesStart] ^= 0xFF;
      expect(wlUnwrap(damaged), fs);
      damaged[statesStart + copySize] ^= 0xFF;
      expect(() => wlUnwrap(damaged), throwsA(isA<WearLevellingException>()));
    });
  });

  group('looksLikeWl', () {
    test('rejects bare images and damaged config sectors', () {
      expect(looksLikeWl(Uint8List(0x1000)), isFalse);
      expect(looksLikeWl(Uint8List(0x2000)), isFalse);
      expect(looksLikeWl(Uint8List(0x2000)..fillRange(0, 0x2000, 0xFF)), isFalse);
      final image = wlWrap(Uint8List(0x1000), 0x40000, deviceId: 1);
      expect(looksLikeWl(image), isTrue);
      expect(looksLikeWl(Uint8List.sublistView(image, 0, 0x3F000)), isFalse); // size no longer matches
      final corrupt = Uint8List.fromList(image);
      corrupt[corrupt.length - WlLayout.sectorSize + 4] ^= 1; // full_mem_size
      expect(looksLikeWl(corrupt), isFalse);
      expect(looksLikeWl(Uint8List.fromList(image)..[5] = 0), isTrue); // the dummy sector is not covered
    });
  });
}
