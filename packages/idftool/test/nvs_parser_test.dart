import 'dart:typed_data';

import 'package:idftool/src/nvs/nvs.dart';
import 'package:test/test.dart';

import 'nvs_fixtures.dart';

/// Every image the python tool produced, generated or edited.
const fixtureImages = [
  'basic',
  'types',
  'reopen',
  'bigblob',
  'readonly',
  'nearfull',
  'v1',
  'edit-append',
  'edit-replace',
  'edit-delete',
  'edit-bigblob',
  'edit-bigblob2',
  'edit-rewrite',
  'edit-compact',
  'edit-v1',
];

void main() {
  group('parse matches python print-nvs / extract-nvs', () {
    for (final name in fixtureImages) {
      test(name, () {
        final data = fixtureBytes('$name.bin');
        final image = parseNvs(data, strict: true);
        expect(image.errors, isEmpty);
        expect(describeImage(data), fixtureText('$name.pages.txt'));
        expect(nvsToCsv(image.entries), fixtureText('$name.extract.csv'));
      });
    }
  });

  group('parse details', () {
    test('values, sizes and namespaces of the types image', () {
      final image = parseNvs(fixtureBytes('types.bin'));
      expect(image.version, NvsVersion.v2);
      expect(image.namespaces, {1: 'nums', 2: 'text', 3: 'bin'});
      expect(image.namespaceIndex('text'), 2);
      expect(image.namespaceIndex('nope'), isNull);

      expect(image.get('nums', 'u64_max')!.value, BigInt.parse('18446744073709551615'));
      expect(image.get('nums', 'u64_max')!.valueText, '18446744073709551615');
      expect(image.get('nums', 'i64_min')!.value, BigInt.parse('-9223372036854775808'));
      expect(image.get('nums', 'i64_pos')!.value, BigInt.from(1234567890123));
      expect(image.get('nums', 'u32_v')!.value, 0xFFFFFFFF);
      expect(image.get('nums', 'u32_v')!.value, isA<int>());
      expect(image.get('nums', 'i8_min')!.value, -128);
      expect(image.get('nums', 'u8_max')!.size, 1);

      final long = image.get('text', 'long')!;
      expect(long.value, 'The quick brown fox jumps over the lazy dog. ' * 3);
      expect(long.size, 136, reason: 'payload includes the NUL');
      expect(long.raw.single.span, 1 + 5);
      expect(image.get('text', 'empty')!.value, '');
      expect(image.get('text', 'empty')!.size, 1);
      expect(image.get('text', 'utf8')!.value, 'héllo wörld ✓');

      final big = image.get('bin', 'big')!;
      expect(big.value, blob(500, 2));
      expect(big.type, NvsType.blob);
      expect(big.raw.length, 2, reason: 'a blobIndex plus one chunk');
      expect(big.raw.first.type, NvsType.blobIndex);
      expect(big.raw.last.type, NvsType.blobData);
      expect(image.get('bin', 'b64')!.value, 'hello world'.codeUnits);
      expect(image.get('bin', 'empty')!.value, isEmpty);
      expect(image.get('bin', 'empty')!.size, 0);
    });

    test('a v2 blob spanning pages is stitched from its chunks', () {
      final image = parseNvs(fixtureBytes('bigblob.bin'));
      final first = image.get('blobs', 'first')!;
      expect(first.value, blob(6000, 3));
      expect(first.raw.map((r) => r.page).toSet().length, greaterThan(1));
      expect(first.raw.where((r) => r.type == NvsType.blobData).map((r) => r.chunkIndex), [0, 1]);
      expect(image.get('blobs', 'maxstr')!.size, 3968);
    });

    test('a replaced blob starts its chunks at the other offset', () {
      final once = parseNvs(fixtureBytes('edit-bigblob.bin')).get('blobs', 'first')!;
      expect(once.raw.where((r) => r.type == NvsType.blobData).map((r) => r.chunkIndex), [0x80, 0x81]);
      final twice = parseNvs(fixtureBytes('edit-bigblob2.bin')).get('blobs', 'first')!;
      expect(twice.raw.where((r) => r.type == NvsType.blobData).map((r) => r.chunkIndex), [0, 1]);
    });

    test('a v1 image uses single-page blobs', () {
      final image = parseNvs(fixtureBytes('v1.bin'));
      expect(image.version, NvsVersion.v1);
      final entry = image.get('v1', 'bigblob')!;
      expect(entry.raw.single.type, NvsType.blob);
      expect(entry.value, ('ABC' * 400).codeUnits);
    });

    test('erased entries are skipped and the page map counts them', () {
      final image = parseNvs(fixtureBytes('edit-delete.bin'));
      expect(image.get('nums', 'u8_max'), isNull);
      expect(image.get('text', 'long'), isNull);
      expect(image.get('bin', 'big'), isNull);
      final page = image.pages[0];
      // u8 (1) + 136-byte string (1 + 5) + 500-byte blob (index 1 + chunk header 1 + 16 data)
      expect(page.entryStates.where((s) => s == NvsEntryState.erased).length, 1 + 6 + 18);
      expect(page.usedEntries, 58, reason: 'erasing never lowers the high-water mark');
    });

    test('a blank image parses as empty', () {
      final blank = Uint8List(0x3000)..fillRange(0, 0x3000, 0xFF);
      final image = parseNvs(blank);
      expect(image.entries, isEmpty);
      expect(image.pages.every((p) => p.isUninit), isTrue);
      expect(image.errors, isEmpty);
      expect(formatNvsEntries(image.entries), '(empty)');
    });

    test('rejects impossible sizes', () {
      expect(() => parseNvs(Uint8List(0)), throwsA(isA<NvsError>()));
      expect(() => parseNvs(Uint8List(100)), throwsA(isA<NvsError>()));
    });

    test('damage is collected, or thrown when strict', () {
      final data = Uint8List.fromList(fixtureBytes('types.bin'));
      data[64 + 32 + 8] ^= 0xFF; // corrupt the second entry's key → header CRC mismatch
      final image = parseNvs(data);
      expect(image.errors, ['page 0 entry 1: header CRC mismatch']);
      expect(image.get('nums', 'u8_max'), isNull, reason: 'the corrupt entry is skipped');
      expect(image.get('nums', 'i8_min')!.value, -128, reason: 'the rest still parses');
      expect(() => parseNvs(data, strict: true), throwsA(isA<NvsError>()));

      final namespace = Uint8List.fromList(fixtureBytes('types.bin'));
      namespace[64 + 8] ^= 0xFF; // the namespace entry itself: everything in it becomes unresolvable
      final orphaned = parseNvs(namespace);
      expect(orphaned.errors.first, 'page 0 entry 0: header CRC mismatch');
      expect(orphaned.errors.skip(1), everyElement(contains('namespace index 1 is not in the namespace table')));
      expect(orphaned.get('<1>', 'u8_max')!.value, 255, reason: 'orphans are listed under a placeholder');

      final header = Uint8List.fromList(fixtureBytes('types.bin'));
      header[4] ^= 0x01; // sequence number → page CRC mismatch
      final broken = parseNvs(header);
      expect(broken.errors.single, startsWith('page 0: header CRC mismatch'));
      expect(broken.entries, isEmpty);
      expect(() => applyNvsEdits(header, [const NvsEdit.set('a', 'b', type: NvsType.u8, value: 1)]),
          throwsA(isA<NvsError>()));
    });

    test('the newest copy of a duplicated key wins', () {
      // Build an image by hand with the same key written on two pages.
      final writer = NvsWriter.blank(0x4000);
      writer.writeNamespace('ns', 1);
      writer.writeItem(1, 'k', NvsType.u8, 1);
      for (var i = 0; i < 124; i++) {
        writer.writeItem(1, 'pad$i', NvsType.u8, 0);
      }
      writer.writeItem(1, 'k', NvsType.u8, 2); // lands on page 1
      final image = parseNvs(writer.data);
      expect(image.get('ns', 'k')!.value, 2);
      expect(image.get('ns', 'k')!.page, 1);
    });
  });

  group('formatting', () {
    test('abbreviates long values', () {
      final entry = NvsEntry(namespace: 'n', key: 'k', type: NvsType.blob, value: blob(100, 0), size: 100, nsIndex: 1);
      expect(entry.formatValue(), '${hex(blob(24, 0))}… (100 bytes)');
      final text = NvsEntry(namespace: 'n', key: 'k', type: NvsType.string, value: 'x' * 60, size: 61, nsIndex: 1);
      expect(text.formatValue(), '${'x' * 48}…');
      expect(text.formatValue(limit: 100), 'x' * 60);
    });

    test('page map for an uninitialised page', () {
      final image = parseNvs(fixtureBytes('readonly.bin'));
      expect(formatNvsPages(image), fixtureText('readonly.pages.txt').split('\n\n').first);
    });
  });
}
