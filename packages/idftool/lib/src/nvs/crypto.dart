/// NVS encryption: the XTS-AES layer ESP-IDF puts under an NVS partition
/// when `CONFIG_NVS_ENCRYPTION` is on.
///
/// Only the entries are encrypted. Page headers and entry state bitmaps are
/// read and written raw by the firmware (`read_raw`/`write_raw` in
/// `nvs_page.cpp`), and every CRC is computed over the plaintext. Each
/// 32-byte entry is its own XTS data unit — two AES blocks, so no ciphertext
/// stealing — with its offset within the partition, as a little-endian
/// `uint32` zero-padded to 16 bytes, as the tweak
/// (`nvs_encrypted_partition.cpp`).
///
/// The XTS key is `eky || tky`: 32 bytes each, AES-256. With the HMAC-based
/// key protection scheme (`CONFIG_NVS_SEC_KEY_PROTECT_USING_HMAC`) the
/// firmware derives both from an HMAC key held in eFuse
/// (see [NvsKeys.fromHmacKey]); with the flash encryption scheme they live in
/// an `nvs_keys` partition ([NvsKeys.fromKeyPartition]).
///
/// Everything else in the NVS modules works on plaintext; decrypt an image
/// with [decryptNvs] as it comes in and [encryptNvs] it on the way out.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show Hmac, sha256;

import 'common.dart';

/// The pair of keys an encrypted NVS partition is keyed with.
class NvsKeys {
  /// [eky] is the XTS data key, [tky] the tweak key; 32 bytes each.
  NvsKeys(List<int> eky, List<int> tky)
      : eky = Uint8List.fromList(eky),
        tky = Uint8List.fromList(tky) {
    if (eky.length != keySize || tky.length != keySize) {
      throw NvsError('NVS encryption keys are $keySize bytes each, not ${eky.length} and ${tky.length}');
    }
  }

  /// Derive the keys from the HMAC key the firmware uses under the HMAC-based
  /// scheme: `eky = HMAC-SHA256(key, 5A5ABEAE × 8)` and
  /// `tky = HMAC-SHA256(key, A5A5DECE × 8)`. The seeds are the `uint32`
  /// constants `EKEY_SEED` and `TKEY_SEED` from `nvs_sec_provider` as they
  /// sit in memory.
  factory NvsKeys.fromHmacKey(List<int> hmacKey) {
    if (hmacKey.length != keySize) throw NvsError('An NVS HMAC key is $keySize bytes, not ${hmacKey.length}');
    final hmac = Hmac(sha256, hmacKey);
    return NvsKeys(
      hmac.convert([for (var i = 0; i < 8; i++) ...const [0x5A, 0x5A, 0xBE, 0xAE]]).bytes,
      hmac.convert([for (var i = 0; i < 8; i++) ...const [0xA5, 0xA5, 0xDE, 0xCE]]).bytes,
    );
  }

  /// Read the keys out of an `nvs_keys` partition (or the keys file
  /// `nvs_partition_gen` writes): `eky`, `tky`, then a CRC32 of the two.
  factory NvsKeys.fromKeyPartition(Uint8List data) {
    if (data.length < 2 * keySize + 4) throw NvsError('An nvs_keys partition holds at least ${2 * keySize + 4} bytes');
    final stored = ByteData.sublistView(data).getUint32(2 * keySize, Endian.little);
    if (stored != nvsCrc32(Uint8List.sublistView(data, 0, 2 * keySize))) {
      throw NvsError('The nvs_keys CRC does not match — the partition is blank, damaged or flash-encrypted');
    }
    return NvsKeys(data.sublist(0, keySize), data.sublist(keySize, 2 * keySize));
  }

  /// An HMAC key typed as hex (64 digits; spaces, colons and a `0x` prefix
  /// are ignored), or read from a file: the raw 32 bytes, as `espefuse
  /// burn_key` and `nvs_partition_gen --kp_hmac_inputkey` take it, or 64 hex
  /// digits of text.
  static List<int> parseHmacKey(Object source) {
    String? text;
    if (source is String) {
      text = source;
    } else if (source is List<int>) {
      if (source.length == keySize) return source;
      try {
        text = utf8.decode(source);
      } on FormatException {
        text = null;
      }
    }
    final digits = text?.trim().replaceFirst(RegExp('^0[xX]'), '').replaceAll(RegExp(r'[\s:]'), '');
    if (digits == null || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(digits)) {
      throw NvsError('An NVS HMAC key is $keySize bytes: 64 hex digits, or a file holding the raw bytes');
    }
    return hexDecode(digits);
  }

  static const int keySize = 32;

  final Uint8List eky;
  final Uint8List tky;

  late final AesXts _xts = AesXts(Uint8List.fromList([...eky, ...tky]));
}

/// Encrypt the entries of a plaintext NVS image. Returns a new image; headers,
/// bitmaps and erased pages are copied as they are.
Uint8List encryptNvs(Uint8List image, NvsKeys keys) => _transform(image, keys, encrypt: true);

/// Decrypt the entries of an encrypted NVS image. Returns a new image.
///
/// A wrong key can't be told apart from damage except by its result, so this
/// throws [NvsError] when the decrypted image still has no entry that passes
/// its CRC (see [looksEncryptedNvs]) — which is also what a plaintext image
/// run through here looks like.
Uint8List decryptNvs(Uint8List image, NvsKeys keys) {
  final out = _transform(image, keys, encrypt: false);
  if (looksEncryptedNvs(out)) {
    throw NvsError('The key does not decrypt this NVS image (wrong key, or the image is not encrypted)');
  }
  return out;
}

Uint8List _transform(Uint8List image, NvsKeys keys, {required bool encrypt}) {
  if (image.length % NvsLayout.pageSize != 0) {
    throw NvsError('NVS image size 0x${image.length.toRadixString(16)} is not a multiple of the '
        '0x${NvsLayout.pageSize.toRadixString(16)}-byte page size');
  }
  final out = Uint8List.fromList(image);
  final tweak = Uint8List(16);
  final tweakView = ByteData.sublistView(tweak);
  for (var base = 0; base < out.length; base += NvsLayout.pageSize) {
    if (ByteData.sublistView(out).getUint32(base, Endian.little) == NvsPageState.uninitialised.value) continue;
    final bitmap = Uint8List.sublistView(out, base + NvsLayout.bitmapOffset, base + NvsLayout.bitmapOffset + NvsLayout.bitmapSize);
    for (var i = 0; i < NvsLayout.maxEntries; i++) {
      // Go by the bitmap, not by whether the bytes are all 0xFF: a written payload entry can
      // hold 0xFF plaintext and still has to be encrypted. An EMPTY entry with bytes in it is
      // a half-written one the firmware purges; leave it as it is.
      if (entryState(bitmap, i) == NvsEntryState.empty) continue;
      final offset = base + NvsLayout.firstEntryOffset + i * NvsLayout.entrySize;
      tweakView.setUint32(0, offset, Endian.little);
      final unit = Uint8List.sublistView(out, offset, offset + NvsLayout.entrySize);
      encrypt ? keys._xts.encrypt(unit, tweak) : keys._xts.decrypt(unit, tweak);
    }
  }
  return out;
}

/// Whether [data] has initialised pages with written entries but not one
/// entry header that passes its CRC — what an encrypted image (or one
/// decrypted with the wrong key) looks like to the parser. A plaintext image
/// that has been damaged still has good entries around the damage.
bool looksEncryptedNvs(Uint8List data) {
  if (data.isEmpty || data.length % NvsLayout.pageSize != 0) return false;
  var failed = 0;
  for (var base = 0; base < data.length; base += NvsLayout.pageSize) {
    final page = Uint8List.sublistView(data, base, base + NvsLayout.pageSize);
    final view = ByteData.sublistView(page);
    if (view.getUint32(0, Endian.little) == NvsPageState.uninitialised.value) continue;
    final header = Uint8List.sublistView(page, 0, NvsLayout.headerSize);
    if (view.getUint32(28, Endian.little) != headerCrc(header) || NvsVersion.fromByte(page[8]) == null) continue;
    final bitmap = Uint8List.sublistView(page, NvsLayout.bitmapOffset, NvsLayout.bitmapOffset + NvsLayout.bitmapSize);
    var i = 0;
    while (i < NvsLayout.maxEntries) {
      if (entryState(bitmap, i) != NvsEntryState.written) {
        i++;
        continue;
      }
      final start = NvsLayout.firstEntryOffset + i * NvsLayout.entrySize;
      final entry = Uint8List.sublistView(page, start, start + NvsLayout.entrySize);
      if (ByteData.sublistView(entry).getUint32(4, Endian.little) == entryCrc(entry)) return false;
      failed++;
      i++;
    }
  }
  return failed > 0;
}

// --------------------------------------------------------------------------
// AES and XTS
// --------------------------------------------------------------------------

/// XTS-AES (IEEE P1619) over data units of whole 16-byte blocks. [key] is the
/// data key followed by the tweak key: 32 bytes for XTS-AES-128, 64 for
/// XTS-AES-256.
final class AesXts {
  AesXts(Uint8List key)
      : _data = Aes(Uint8List.sublistView(key, 0, key.length ~/ 2)),
        _tweak = Aes(Uint8List.sublistView(key, key.length ~/ 2)) {
    if (key.length != 32 && key.length != 64) throw ArgumentError('XTS-AES takes a 32- or 64-byte key');
  }

  final Aes _data;
  final Aes _tweak;
  final Uint8List _t = Uint8List(16);

  /// Encrypt [unit] in place under the 16-byte [tweak].
  void encrypt(Uint8List unit, Uint8List tweak) => _crypt(unit, tweak, true);

  /// Decrypt [unit] in place under the 16-byte [tweak].
  void decrypt(Uint8List unit, Uint8List tweak) => _crypt(unit, tweak, false);

  void _crypt(Uint8List unit, Uint8List tweak, bool encrypt) {
    if (unit.isEmpty || unit.length % 16 != 0) throw ArgumentError('XTS data unit must be whole blocks (no ciphertext stealing)');
    if (tweak.length != 16) throw ArgumentError('XTS tweak must be 16 bytes');
    final t = _t..setRange(0, 16, tweak);
    _tweak.encryptBlock(t);
    for (var o = 0; o < unit.length; o += 16) {
      for (var i = 0; i < 16; i++) {
        unit[o + i] ^= t[i];
      }
      encrypt ? _data.encryptBlock(unit, o) : _data.decryptBlock(unit, o);
      for (var i = 0; i < 16; i++) {
        unit[o + i] ^= t[i];
      }
      // Multiply the tweak by α in GF(2^128), little-endian.
      var carry = 0;
      for (var i = 0; i < 16; i++) {
        final b = t[i];
        t[i] = ((b << 1) | carry) & 0xFF;
        carry = b >> 7;
      }
      if (carry != 0) t[0] ^= 0x87;
    }
  }
}

/// The AES block cipher (FIPS-197) with a 128-, 192- or 256-bit key.
///
/// Byte-oriented with lookup tables rather than 32-bit T-tables, so it
/// behaves identically when compiled to JavaScript.
final class Aes {
  Aes(Uint8List key)
      : _rounds = key.length ~/ 4 + 6,
        _w = _expandKey(key);

  final int _rounds;
  final Uint8List _w;
  final Uint8List _s = Uint8List(16);

  static Uint8List _expandKey(Uint8List key) {
    if (key.length != 16 && key.length != 24 && key.length != 32) throw ArgumentError('AES takes a 16-, 24- or 32-byte key');
    final nk = key.length ~/ 4, words = 4 * (nk + 7);
    final w = Uint8List(words * 4)..setRange(0, key.length, key);
    var rcon = 1;
    for (var i = nk; i < words; i++) {
      var t0 = w[(i - 1) * 4], t1 = w[(i - 1) * 4 + 1], t2 = w[(i - 1) * 4 + 2], t3 = w[(i - 1) * 4 + 3];
      if (i % nk == 0) {
        final first = t0;
        t0 = _sbox[t1] ^ rcon;
        t1 = _sbox[t2];
        t2 = _sbox[t3];
        t3 = _sbox[first];
        rcon = _xtime(rcon);
      } else if (nk > 6 && i % nk == 4) {
        t0 = _sbox[t0];
        t1 = _sbox[t1];
        t2 = _sbox[t2];
        t3 = _sbox[t3];
      }
      w[i * 4] = w[(i - nk) * 4] ^ t0;
      w[i * 4 + 1] = w[(i - nk) * 4 + 1] ^ t1;
      w[i * 4 + 2] = w[(i - nk) * 4 + 2] ^ t2;
      w[i * 4 + 3] = w[(i - nk) * 4 + 3] ^ t3;
    }
    return w;
  }

  void _addRoundKey(Uint8List b, int o, int round) {
    for (var i = 0; i < 16; i++) {
      b[o + i] ^= _w[round * 16 + i];
    }
  }

  /// Encrypt the block at [offset] in [block], in place.
  void encryptBlock(Uint8List block, [int offset = 0]) {
    final s = _s;
    _addRoundKey(block, offset, 0);
    for (var round = 1; round <= _rounds; round++) {
      // SubBytes and ShiftRows. The state is column-major: byte row + 4 * column.
      for (var i = 0; i < 16; i++) {
        s[i] = _sbox[block[offset + (i + 4 * (i & 3)) % 16]];
      }
      if (round != _rounds) {
        for (var c = 0; c < 16; c += 4) {
          final a0 = s[c], a1 = s[c + 1], a2 = s[c + 2], a3 = s[c + 3];
          block[offset + c] = _mul2[a0] ^ _mul3[a1] ^ a2 ^ a3;
          block[offset + c + 1] = a0 ^ _mul2[a1] ^ _mul3[a2] ^ a3;
          block[offset + c + 2] = a0 ^ a1 ^ _mul2[a2] ^ _mul3[a3];
          block[offset + c + 3] = _mul3[a0] ^ a1 ^ a2 ^ _mul2[a3];
        }
      } else {
        block.setRange(offset, offset + 16, s);
      }
      _addRoundKey(block, offset, round);
    }
  }

  /// Decrypt the block at [offset] in [block], in place.
  void decryptBlock(Uint8List block, [int offset = 0]) {
    final s = _s;
    _addRoundKey(block, offset, _rounds);
    for (var round = _rounds - 1; round >= 0; round--) {
      // InvShiftRows and InvSubBytes.
      for (var i = 0; i < 16; i++) {
        s[i] = _invSbox[block[offset + (i + 12 * (i & 3)) % 16]];
      }
      block.setRange(offset, offset + 16, s);
      _addRoundKey(block, offset, round);
      if (round != 0) {
        for (var c = 0; c < 16; c += 4) {
          final a0 = block[offset + c], a1 = block[offset + c + 1], a2 = block[offset + c + 2], a3 = block[offset + c + 3];
          block[offset + c] = _mul14[a0] ^ _mul11[a1] ^ _mul13[a2] ^ _mul9[a3];
          block[offset + c + 1] = _mul9[a0] ^ _mul14[a1] ^ _mul11[a2] ^ _mul13[a3];
          block[offset + c + 2] = _mul13[a0] ^ _mul9[a1] ^ _mul14[a2] ^ _mul11[a3];
          block[offset + c + 3] = _mul11[a0] ^ _mul13[a1] ^ _mul9[a2] ^ _mul14[a3];
        }
      }
    }
  }
}

int _xtime(int b) => ((b << 1) ^ ((b & 0x80) != 0 ? 0x1B : 0)) & 0xFF;

int _gmul(int a, int b) {
  var p = 0;
  while (b != 0) {
    if (b & 1 != 0) p ^= a;
    a = _xtime(a);
    b >>= 1;
  }
  return p;
}

Uint8List _mulTable(int factor) => Uint8List.fromList([for (var i = 0; i < 256; i++) _gmul(i, factor)]);

final Uint8List _mul2 = _mulTable(2), _mul3 = _mulTable(3);
final Uint8List _mul9 = _mulTable(9), _mul11 = _mulTable(11), _mul13 = _mulTable(13), _mul14 = _mulTable(14);

/// The S-box: the multiplicative inverse in GF(2^8), then the affine map.
final Uint8List _sbox = () {
  final box = Uint8List(256);
  for (var x = 0; x < 256; x++) {
    var inv = 0;
    if (x != 0) {
      for (var y = 1; y < 256; y++) {
        if (_gmul(x, y) == 1) {
          inv = y;
          break;
        }
      }
    }
    int rotl(int v, int n) => ((v << n) | (v >> (8 - n))) & 0xFF;
    box[x] = inv ^ rotl(inv, 1) ^ rotl(inv, 2) ^ rotl(inv, 3) ^ rotl(inv, 4) ^ 0x63;
  }
  return box;
}();

final Uint8List _invSbox = () {
  final box = Uint8List(256);
  for (var x = 0; x < 256; x++) {
    box[_sbox[x]] = x;
  }
  return box;
}();
