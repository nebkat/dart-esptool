import 'dart:typed_data';

import 'package:idftool/src/nvs/crypto.dart';
import 'package:idftool/src/nvs/nvs.dart';
import 'package:test/test.dart';

import 'nvs_fixtures.dart';

/// Encrypted fixture → the plaintext fixture and size it was generated from.
const encrypted = {
  'basic': 0x6000,
  'types': 0x6000,
  'bigblob': 0x8000,
};

Uint8List unhex(String s) => hexDecode(s);

NvsKeys fixtureKeys() => NvsKeys.fromHmacKey(fixtureBytes('hmac-key.bin'));

void main() {
  group('AES', () {
    // FIPS-197 appendix C.
    const plain = '00112233445566778899aabbccddeeff';
    for (final (bits, cipher) in const [(128, '69c4e0d86a7b0430d8cdb78070b4c55a'), (256, '8ea2b7ca516745bfeafc49904b496089')]) {
      test('AES-$bits', () {
        final aes = Aes(Uint8List.fromList([for (var i = 0; i < bits ~/ 8; i++) i]));
        final block = unhex(plain);
        aes.encryptBlock(block);
        expect(hex(block), cipher);
        aes.decryptBlock(block);
        expect(hex(block), plain);
      });
    }
  });

  group('XTS-AES', () {
    // Computed with python `cryptography` (OpenSSL): a 32-byte unit, as NVS uses.
    const plain = '0726456483a2c1e0ff1e3d5c7b9ab9d8f71635547392b1d0ef0e2d4c6b8aa9c8';
    for (final (name, key, tweak, cipher) in const [
      (
        '128',
        '05121f2c394653606d7a8794a1aebbc8d5e2effc091623303d4a5764717e8b98',
        '40000000000000000000000000000000',
        'e5910cac7dc5c7a3182a4ef866225931a4e5e98b551ae4bf3e5b058c78c8c826',
      ),
      (
        '256',
        '05121f2c394653606d7a8794a1aebbc8d5e2effc091623303d4a5764717e8b98a5b2bfccd9e6f3000d1a2734414e5b6875828f9ca9b6c3d0ddeaf704111e2b38',
        '74120000000000000000000000000000',
        '97b92020a0f3e364e8be1c208d088e633cb17cabce12d43c1737b41c5500acfc',
      ),
    ]) {
      test('XTS-AES-$name', () {
        final xts = AesXts(unhex(key));
        final unit = unhex(plain);
        xts.encrypt(unit, unhex(tweak));
        expect(hex(unit), cipher);
        xts.decrypt(unit, unhex(tweak));
        expect(hex(unit), plain);
      });
    }
  });

  group('keys', () {
    test('derived from the HMAC key like nvs_partition_gen', () {
      final fromHmac = fixtureKeys();
      final fromFile = NvsKeys.fromKeyPartition(fixtureBytes('enc-keys.bin'));
      expect(hex(fromHmac.eky), '813a141220ddb819f4d73d59fa3032ab9f592cc26a18cf1fde692f712b6a025c');
      expect(hex(fromHmac.eky), hex(fromFile.eky));
      expect(hex(fromHmac.tky), hex(fromFile.tky));
    });

    test('key partition CRC is checked', () {
      final bad = Uint8List.fromList(fixtureBytes('enc-keys.bin'))..[0] ^= 1;
      expect(() => NvsKeys.fromKeyPartition(bad), throwsA(isA<NvsError>()));
    });

    test('HMAC key parsing', () {
      final raw = fixtureBytes('hmac-key.bin');
      expect(NvsKeys.parseHmacKey(raw), raw);
      expect(NvsKeys.parseHmacKey('0x${hex(raw)}\n'), raw);
      expect(NvsKeys.parseHmacKey(hex(raw).toUpperCase().replaceAllMapped(RegExp('..'), (m) => '${m[0]}:')), raw);
      expect(NvsKeys.parseHmacKey(Uint8List.fromList('${hex(raw)}\n'.codeUnits)), raw);
      expect(() => NvsKeys.parseHmacKey('abcd'), throwsA(isA<NvsError>()));
      expect(() => NvsKeys.parseHmacKey(Uint8List(31)), throwsA(isA<NvsError>()));
      expect(() => NvsKeys.fromHmacKey(Uint8List(16)), throwsA(isA<NvsError>()));
    });
  });

  group('encrypted images', () {
    for (final MapEntry(key: name, value: size) in encrypted.entries) {
      group(name, () {
        test('generate is byte-identical to nvs_partition_gen encrypt', () {
          final dart = generateNvsImage(fixtureText('$name.csv'), size, keys: fixtureKeys());
          expect(dart, sameBytesAs(fixtureBytes('enc-$name.bin')));
        });

        test('decrypts to the plaintext image', () {
          expect(decryptNvs(fixtureBytes('enc-$name.bin'), fixtureKeys()), sameBytesAs(fixtureBytes('$name.bin')));
        });

        test('encrypt(decrypt(x)) is x', () {
          final keys = fixtureKeys();
          final image = fixtureBytes('enc-$name.bin');
          expect(encryptNvs(decryptNvs(image, keys), keys), sameBytesAs(image));
        });

        test('parses as encrypted without the key', () {
          final image = fixtureBytes('enc-$name.bin');
          expect(looksLikeNvsBinary(image), isTrue);
          expect(looksEncryptedNvs(image), isTrue);
          final parsed = parseNvs(image);
          expect(parsed.looksEncrypted, isTrue);
          expect(parsed.entries, isEmpty);
          expect(parsed.errors, hasLength(1));
          expect(formatNvsPages(parsed), formatNvsPages(parseNvs(fixtureBytes('$name.bin'))));
          expect(() => parseNvs(image, strict: true), throwsA(isA<NvsError>()));
          expect(() => applyNvsEdits(image, [const NvsEdit.delete('x', 'y')]), throwsA(isA<NvsError>()));
        });

        test('the plaintext does not look encrypted', () {
          expect(looksEncryptedNvs(fixtureBytes('$name.bin')), isFalse);
          expect(parseNvs(fixtureBytes('$name.bin')).looksEncrypted, isFalse);
        });

        test('a wrong key is refused', () {
          final wrong = NvsKeys.fromHmacKey(Uint8List(32));
          expect(() => decryptNvs(fixtureBytes('enc-$name.bin'), wrong), throwsA(isA<NvsError>()));
        });
      });
    }

    test('a blank image round-trips and is neither', () {
      final blank = Uint8List(0x3000)..fillRange(0, 0x3000, 0xFF);
      expect(looksEncryptedNvs(blank), isFalse);
      expect(decryptNvs(blank, fixtureKeys()), sameBytesAs(blank));
    });

    test('edit an encrypted image the way editNvs does', () {
      final keys = fixtureKeys();
      final image = fixtureBytes('enc-types.bin');
      const edits = [
        NvsEdit.set('nums', 'new_u8', type: NvsType.u8, value: 200),
        NvsEdit.delete('text', 'long'),
      ];
      // All-0xFF payload entries must be encrypted too: the bitmap, not the bytes, decides.
      final ffBlob = NvsEdit.set('bin', 'ff', type: NvsType.blob, value: Uint8List(64)..fillRange(0, 64, 0xFF));

      final plain = applyNvsEdits(fixtureBytes('types.bin'), [...edits, ffBlob]);
      final result = applyNvsEdits(decryptNvs(image, keys), [...edits, ffBlob]);
      final written = encryptNvs(result.image, keys);

      expect(result.dirtyPages, plain.dirtyPages);
      // Only the dirty pages differ from what was on flash.
      for (var p = 0; p < image.length ~/ NvsLayout.pageSize; p++) {
        final start = p * NvsLayout.pageSize, end = start + NvsLayout.pageSize;
        expect(written.sublist(start, end), plain.dirtyPages.contains(p) ? isNot(image.sublist(start, end)) : image.sublist(start, end),
            reason: 'page $p');
      }
      expect(decryptNvs(written, keys), sameBytesAs(plain.image));
      final reread = parseNvs(decryptNvs(written, keys));
      expect(reread.errors, isEmpty);
      expect(reread.get('bin', 'ff')!.value, everyElement(0xFF));
      expect(reread.get('text', 'long'), isNull);
    });
  });
}
