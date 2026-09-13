@TestOn('browser')
library;

// NVS encryption must work when compiled to JavaScript (the web app), where
// integer and typed-data behaviour differs from the VM.
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:idftool/src/nvs/crypto.dart';
import 'package:idftool/src/nvs/nvs.dart';
import 'package:test/test.dart';

// test/fixtures/nvs/basic.csv
const _basicCsv = 'key,type,encoding,value\n'
    'storage,namespace,,\n'
    'device_id,data,u32,12345\n'
    'device_name,data,string,idftool-test\n'
    'counter,data,u16,7\n';

// sha256 of test/fixtures/nvs/enc-basic.bin, from nvs_partition_gen encrypt.
const _encBasicSha256 = '4b4f1454561d920f5522bc8c4732718cbfc8d73373d9908a6e0a2d768215b738';

void main() {
  test('AES-256 (FIPS-197 C.3)', () {
    final aes = Aes(Uint8List.fromList([for (var i = 0; i < 32; i++) i]));
    final block = hexDecode('00112233445566778899aabbccddeeff');
    aes.encryptBlock(block);
    expect(hexEncode(block), '8ea2b7ca516745bfeafc49904b496089');
    aes.decryptBlock(block);
    expect(hexEncode(block), '00112233445566778899aabbccddeeff');
  });

  test('XTS-AES-256', () {
    final xts = AesXts(hexDecode(
        '05121f2c394653606d7a8794a1aebbc8d5e2effc091623303d4a5764717e8b98a5b2bfccd9e6f3000d1a2734414e5b6875828f9ca9b6c3d0ddeaf704111e2b38'));
    final unit = hexDecode('0726456483a2c1e0ff1e3d5c7b9ab9d8f71635547392b1d0ef0e2d4c6b8aa9c8');
    xts.encrypt(unit, hexDecode('74120000000000000000000000000000'));
    expect(hexEncode(unit), '97b92020a0f3e364e8be1c208d088e633cb17cabce12d43c1737b41c5500acfc');
  });

  test('encrypted generate matches nvs_partition_gen, and decrypts back', () {
    final keys = NvsKeys.fromHmacKey([for (var i = 0; i < 32; i++) i]);
    final image = generateNvsImage(_basicCsv, 0x6000, keys: keys);
    expect(sha256.convert(image).toString(), _encBasicSha256);
    expect(parseNvs(image).looksEncrypted, isTrue);
    final plain = parseNvs(decryptNvs(image, keys));
    expect(plain.errors, isEmpty);
    expect(plain.get('storage', 'device_name')!.value, 'idftool-test');
    expect(encryptNvs(plain.data, keys), image);
  });
}
