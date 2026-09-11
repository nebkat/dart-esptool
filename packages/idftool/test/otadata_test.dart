// Expectations generated with the Python original (`esp_idf_defs.otadata`).
import 'dart:typed_data';

import 'package:idftool/src/otadata.dart';
import 'package:test/test.dart';

Uint8List fromHex(String hex) =>
    Uint8List.fromList([for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)]);

String toHex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('OtaDataSelectEntry', () {
    const vectors = <(int, OtaImageState, String)>[
      (1, OtaImageState.newImage, '01000000ffffffffffffffffffffffffffffffffffffffff000000009a984347'),
      (2, OtaImageState.valid, '02000000ffffffffffffffffffffffffffffffffffffffff020000007437f655'),
      (5, OtaImageState.pendingVerify, '05000000ffffffffffffffffffffffffffffffffffffffff01000000cd0f21c8'),
      (0x12345678, OtaImageState.undefined, '78563412ffffffffffffffffffffffffffffffffffffffffffffffff31a7d671'),
      (0xFFFFFFFE, OtaImageState.aborted, 'feffffffffffffffffffffffffffffffffffffffffffffff0400000079b8f899'),
    ];

    test('toBytes layout matches python', () {
      for (final (seq, state, hex) in vectors) {
        expect(toHex(OtaDataSelectEntry(seq, state).toBytes()), hex, reason: 'seq $seq');
      }
    });

    test('fromBytes round trips', () {
      for (final (seq, state, hex) in vectors) {
        expect(OtaDataSelectEntry.fromBytes(fromHex(hex)), OtaDataSelectEntry(seq, state), reason: 'seq $seq');
      }
      // Entry at an offset inside a larger buffer.
      final buffer = Uint8List.fromList([...List.filled(8, 0), ...fromHex(vectors[1].$3)]);
      expect(OtaDataSelectEntry.fromBytes(buffer, 8), const OtaDataSelectEntry(2, OtaImageState.valid));
    });

    test('crc', () {
      expect(OtaDataSelectEntry.crcOf(1), 0x4743989a);
      expect(OtaDataSelectEntry.crcOf(0), 0xffffffff);
    });

    test('fromBytes rejects erased and corrupt entries', () {
      expect(OtaDataSelectEntry.fromBytes(Uint8List(32)..fillRange(0, 32, 0xFF)), isNull);
      // Deviations from Python, whose CRC comparison was a no-op (it compared
      // the computed CRC with itself) so these decoded as seq 0 / seq 3:
      expect(OtaDataSelectEntry.fromBytes(Uint8List(32)), isNull, reason: 'all zeros: crc 0 != crc(0)');
      final badCrc = const OtaDataSelectEntry(3).toBytes()..[28] ^= 1;
      expect(OtaDataSelectEntry.fromBytes(badCrc), isNull);
    });

    test('unknown state decodes as undefined', () {
      final bytes = const OtaDataSelectEntry(3).toBytes()..[24] = 0x77;
      expect(OtaDataSelectEntry.fromBytes(bytes), const OtaDataSelectEntry(3, OtaImageState.undefined));
      expect(OtaImageState.fromValue(7), OtaImageState.undefined);
      expect(OtaImageState.fromValue(0xFFFFFFFF), OtaImageState.undefined);
      expect(OtaImageState.fromValue(2), OtaImageState.valid);
    });

    test('select', () {
      const a = OtaDataSelectEntry(3);
      const b = OtaDataSelectEntry(4);
      expect(OtaDataSelectEntry.select(null, null), (entry: null, copy: null));
      expect(OtaDataSelectEntry.select(a, null), (entry: a, copy: OtaDataCopy.a));
      expect(OtaDataSelectEntry.select(null, b), (entry: b, copy: OtaDataCopy.b));
      expect(OtaDataSelectEntry.select(a, b), (entry: b, copy: OtaDataCopy.b));
      expect(OtaDataSelectEntry.select(b, a), (entry: b, copy: OtaDataCopy.a));
      expect(OtaDataSelectEntry.select(a, a), (entry: a, copy: OtaDataCopy.b), reason: 'ties go to b');
    });

    test('otaSlot and incremented', () {
      // seq → [slot for 1, 2, 3 apps], [incremented(slot, 2).seq for slots 0, 1],
      //       [incremented(slot, 3).seq for slots 0, 1, 2]
      const expected = <int, (List<int>, List<int>, List<int>)>{
        1: ([0, 0, 0], [3, 2], [4, 2, 3]),
        2: ([0, 1, 1], [3, 4], [4, 5, 3]),
        3: ([0, 0, 2], [5, 4], [4, 5, 6]),
        4: ([0, 1, 0], [5, 6], [7, 5, 6]),
        5: ([0, 0, 1], [7, 6], [7, 8, 6]),
        6: ([0, 1, 2], [7, 8], [7, 8, 9]),
        7: ([0, 0, 0], [9, 8], [10, 8, 9]),
      };
      expected.forEach((seq, e) {
        final entry = OtaDataSelectEntry(seq);
        expect([1, 2, 3].map(entry.otaSlot), e.$1, reason: 'seq $seq');
        expect([0, 1].map((s) => entry.incremented(s, 2).seq), e.$2, reason: 'seq $seq');
        expect([0, 1, 2].map((s) => entry.incremented(s, 3).seq), e.$3, reason: 'seq $seq');
        expect(entry.incremented(1, 2).state, OtaImageState.newImage);
      });
    });

    test('fromOtaSlot', () {
      expect(const OtaDataSelectEntry.fromOtaSlot(0), const OtaDataSelectEntry(1));
      expect(const OtaDataSelectEntry.fromOtaSlot(1), const OtaDataSelectEntry(2));
      expect(const OtaDataSelectEntry.fromOtaSlot(1).otaSlot(2), 1);
    });

    test('copy offsets', () {
      expect(OtaDataCopy.a.offset, 0);
      expect(OtaDataCopy.b.offset, 0x1000);
      expect(OtaDataCopy.a.other, OtaDataCopy.b);
    });
  });

  group('OtaDataParameters', () {
    test('no valid entry', () {
      const p = OtaDataParameters(entry: null, copy: null, appCount: 2);
      expect(p.slot, isNull);
      expect(p.nextSlot, 0);
      expect(p.incrementedAndSwapped(1),
          const OtaDataParameters(entry: OtaDataSelectEntry(2), copy: OtaDataCopy.b, appCount: 2));
      expect(p.incrementedAndSwapped(0),
          const OtaDataParameters(entry: OtaDataSelectEntry(1), copy: OtaDataCopy.b, appCount: 2));
    });

    test('two slots, live copy a', () {
      const p = OtaDataParameters(entry: OtaDataSelectEntry(4, OtaImageState.valid), copy: OtaDataCopy.a, appCount: 2);
      expect(p.slot, 1);
      expect(p.nextSlot, 0);
      expect(p.incrementedAndSwapped(1),
          const OtaDataParameters(entry: OtaDataSelectEntry(6), copy: OtaDataCopy.b, appCount: 2));
      expect(p.incrementedAndSwapped(0),
          const OtaDataParameters(entry: OtaDataSelectEntry(5), copy: OtaDataCopy.b, appCount: 2));
    });

    test('three slots, live copy b', () {
      const p = OtaDataParameters(entry: OtaDataSelectEntry(4, OtaImageState.valid), copy: OtaDataCopy.b, appCount: 3);
      expect(p.slot, 0);
      expect(p.nextSlot, 1);
      expect(p.incrementedAndSwapped(0),
          const OtaDataParameters(entry: OtaDataSelectEntry(7), copy: OtaDataCopy.a, appCount: 3));
      expect(p.incrementedAndSwapped(2),
          const OtaDataParameters(entry: OtaDataSelectEntry(6), copy: OtaDataCopy.a, appCount: 3));
    });

    test('select from the two copies', () {
      final p = OtaDataParameters.select(const OtaDataSelectEntry(3), const OtaDataSelectEntry(4), appCount: 2);
      expect(p, const OtaDataParameters(entry: OtaDataSelectEntry(4), copy: OtaDataCopy.b, appCount: 2));
      expect(OtaDataParameters.select(null, null, appCount: 2).slot, isNull);
    });
  });
}
