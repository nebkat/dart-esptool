import 'dart:typed_data';

import 'package:idftool/src/nvs/nvs.dart';
import 'package:test/test.dart';

import 'nvs_fixtures.dart';

void main() {
  group('crc32', () {
    // python: zlib.crc32(b'abc', 0xFFFFFFFF) & 0xFFFFFFFF
    test('matches zlib.crc32(data, 0xFFFFFFFF)', () {
      expect(nvsCrc32('abc'.codeUnits), 0x359a672f);
      expect(nvsCrc32([]), 0xffffffff);
    });

    test('validates every header and entry of a python-generated image', () {
      final data = fixtureBytes('types.bin');
      final header = Uint8List.sublistView(data, 0, 32);
      expect(ByteData.sublistView(header).getUint32(28, Endian.little), headerCrc(header));
      final entry = Uint8List.sublistView(data, 64, 96);
      expect(ByteData.sublistView(entry).getUint32(4, Endian.little), entryCrc(entry));
      final image = parseNvs(data, strict: true);
      expect(image.errors, isEmpty);
      for (final raw in image.pages.expand((p) => p.entries)) {
        expect(raw.crcOk, isTrue);
        if (raw.payload != null) expect(raw.payloadCrcOk, isTrue, reason: raw.key);
      }
    });
  });

  group('primitives', () {
    test('pack and unpack round-trip every width', () {
      final cases = {
        NvsType.u8: [0, 255],
        NvsType.i8: [-128, 127],
        NvsType.u16: [0, 65535],
        NvsType.i16: [-32768, 32767],
        NvsType.u32: [0, 0xFFFFFFFF],
        NvsType.i32: [-2147483648, 2147483647],
        NvsType.u64: [0, -1, 1 << 62],
        NvsType.i64: [-9223372036854775808, 9223372036854775807, 1234567890123],
      };
      for (final MapEntry(key: type, value: values) in cases.entries) {
        for (final value in values) {
          final packed = packPrimitive(type, value);
          expect(packed.length, 8);
          expect(packed.sublist(type.width!), everyElement(0xFF), reason: 'padding is erased flash');
          expect(unpackPrimitive(type, packed), value, reason: '${type.label} $value');
        }
      }
    });

    test('packs the same bytes as the python fixture', () {
      final image = parseNvs(fixtureBytes('types.bin'));
      for (final entry in image.entries.where((e) => e.type.isPrimitive)) {
        expect(packPrimitive(entry.type, entry.value as int), entry.raw.single.data, reason: entry.key);
      }
    });

    test('rejects out-of-range values', () {
      expect(() => packPrimitive(NvsType.u8, 256), throwsA(isA<NvsError>()));
      expect(() => packPrimitive(NvsType.u8, -1), throwsA(isA<NvsError>()));
      expect(() => packPrimitive(NvsType.i8, 128), throwsA(isA<NvsError>()));
      expect(() => packPrimitive(NvsType.u32, 1 << 32), throwsA(isA<NvsError>()));
      expect(() => packPrimitive(NvsType.string, 1), throwsArgumentError);
    });

    test('u64 formats unsigned', () {
      expect(formatNvsValue(-1, type: NvsType.u64), '18446744073709551615');
      expect(formatNvsValue(-1, type: NvsType.i64), '-1');
      expect(formatNvsValue(Uint8List.fromList([0xde, 0xad])), 'dead');
      expect(parseNvsInt('18446744073709551615', NvsType.u64), -1);
      expect(parseNvsInt('-1', NvsType.u64), isNull);
      expect(parseNvsInt('18446744073709551616', NvsType.u64), isNull);
      expect(parseNvsInt('0x10', NvsType.u8), 16);
      expect(parseNvsInt('-0b11', NvsType.i8), -3);
      expect(parseNvsInt('0o17', NvsType.u8), 15);
      expect(parseNvsInt(' 42 ', NvsType.u8), 42);
      expect(parseNvsInt('4x', NvsType.u8), isNull);
      expect(parseNvsInt('', NvsType.u8), isNull);
    });
  });

  group('bitmap', () {
    test('entry states read and write two bits, only ever clearing', () {
      final bitmap = Uint8List(32)..fillRange(0, 32, 0xFF);
      expect(entryState(bitmap, 0), NvsEntryState.empty);
      expect(entryState(bitmap, 125), NvsEntryState.empty);
      setEntryState(bitmap, 5, NvsEntryState.written);
      expect(entryState(bitmap, 5), NvsEntryState.written);
      expect(entryState(bitmap, 4), NvsEntryState.empty);
      expect(entryState(bitmap, 6), NvsEntryState.empty);
      expect(bitmap[1], 0xFB); // entry 5 is bits 10-11 → byte 1, bits 2-3: 0b1111_1011
      setEntryState(bitmap, 5, NvsEntryState.erased);
      expect(entryState(bitmap, 5), NvsEntryState.erased);
      expect(bitmap[1], 0xF3);
    });
  });

  group('types', () {
    test('look up by code and label', () {
      expect(NvsType.fromCode(0x21), NvsType.string);
      expect(NvsType.fromCode(0x42), NvsType.blobData);
      expect(NvsType.fromCode(0x99), isNull);
      expect(NvsType.fromLabel('u64'), NvsType.u64);
      expect(NvsType.fromLabel('blob'), NvsType.blob);
      expect(NvsType.fromLabel('blob_data'), isNull, reason: 'internal types are not user-writable');
      expect(NvsType.writable.map((t) => t.label),
          ['u8', 'i8', 'u16', 'i16', 'u32', 'i32', 'u64', 'i64', 'string', 'blob']);
    });

    test('hex decode', () {
      expect(hexDecode('deadBEEF'), [0xde, 0xad, 0xbe, 0xef]);
      expect(hexDecode(''), isEmpty);
      expect(() => hexDecode('abc'), throwsFormatException);
      expect(() => hexDecode('zz'), throwsFormatException);
    });
  });
}
