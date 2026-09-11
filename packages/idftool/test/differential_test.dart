import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:idftool/src/flash/differential.dart';
import 'package:test/test.dart';

const sector = 0x1000;

/// A region of [sectors] sectors whose in-flash copy differs from the data
/// in the given [changed] sectors (first byte flipped), as python's test
/// harness builds it.
({Uint8List data, FlashMd5 md5}) scenario(int sectors, Iterable<int> changed) {
  final data = Uint8List.fromList(List.generate(sectors * sector, (i) => (i * 7 + 3) & 0xFF));
  final flash = Uint8List.fromList(data);
  for (final s in changed) {
    flash[s * sector] ^= 0xFF;
  }
  return (
    data: data,
    md5: (address, size) async => md5.convert(Uint8List.sublistView(flash, address, address + size)).toString(),
  );
}

void main() {
  // Expected runs computed by python idftool's plan_sector_writes on the same
  // scenarios; (offset, length, reason).
  const changed = SectorWriteReason.changed;
  const remainder = SectorWriteReason.remainder;
  final cases = <String, (int, List<int>, List<SectorWrite>)>{
    'clean': (32, [], []),
    'one changed sector': (32, [5], [(offset: 0x5000, length: 0x1000, reason: changed)]),
    'gap of two is bridged': (32, [5, 8], [(offset: 0x5000, length: 0x4000, reason: changed)]),
    'gap of three splits the run': (
      32,
      [5, 9],
      [(offset: 0x5000, length: 0x1000, reason: changed), (offset: 0x9000, length: 0x1000, reason: changed)]
    ),
    'changes at the front then clean': (64, [0, 1, 2, 3], [(offset: 0, length: 0x4000, reason: changed)]),
    'mostly dirty bails out': (64, List.generate(40, (i) => i), [(offset: 0, length: 0x40000, reason: remainder)]),
    'dirty late is still scanned': (64, List.generate(24, (i) => 40 + i), [(offset: 0x28000, length: 0x18000, reason: changed)]),
    'last sector': (32, [31], [(offset: 0x1f000, length: 0x1000, reason: changed)]),
    'small all-dirty region below the sample floor': (4, [0, 1, 2, 3], [(offset: 0, length: 0x4000, reason: changed)]),
    'interleaved half-dirty coalesces into one run': (128, List.generate(64, (i) => 2 * i), [(offset: 0, length: 0x7f000, reason: changed)]),
  };

  group('planSectorWrites', () {
    cases.forEach((name, c) {
      final (sectors, dirty, expected) = c;
      test(name, () async {
        final s = scenario(sectors, dirty);
        final scanned = <int>[];
        final runs = await planSectorWrites(s.md5, 0, s.data, onScanned: scanned.add).toList();
        expect(runs, expected);
        expect(scanned.first, sector);
        if (expected.isEmpty || expected.last.reason == changed) expect(scanned.last, s.data.length);
      });
    });

    test('partial last sector', () async {
      final s = scenario(33, [32]);
      final data = Uint8List.sublistView(s.data, 0, 32 * sector + 0x100);
      final runs = await planSectorWrites(s.md5, 0, data).toList();
      expect(runs, [(offset: 0x20000, length: 0x100, reason: changed)]);
    });
  });

  group('flashMatches', () {
    test('hashes the first sector, then large chunks', () async {
      final s = scenario(64, []);
      final sizes = <int>[];
      expect(
          await flashMatches((a, n) {
            sizes.add(n);
            return s.md5(a, n);
          }, 0, s.data),
          isTrue);
      expect(sizes, [0x1000, 0x10000, 0x10000, 0x10000, 0xf000]);
    });

    test('stops at the first mismatching chunk', () async {
      final s = scenario(64, [40]);
      var calls = 0;
      expect(
          await flashMatches((a, n) {
            calls++;
            return s.md5(a, n);
          }, 0, s.data),
          isFalse);
      expect(calls, 4); // 0x1000, then 0x10000 chunks up to the one holding sector 40 (0x28000)
    });
  });

  test('bytesAsWritten pads to 4 bytes with 0xFF', () {
    expect(bytesAsWritten(Uint8List.fromList([1, 2, 3, 4])), [1, 2, 3, 4]);
    expect(bytesAsWritten(Uint8List.fromList([1, 2, 3, 4, 5])), [1, 2, 3, 4, 5, 0xFF, 0xFF, 0xFF]);
  });
}
