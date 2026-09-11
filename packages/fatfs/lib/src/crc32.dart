/// The CRC-32 ESP-IDF's wear levelling layer uses: `esp_rom_crc32_le`.
///
/// It is the plain IEEE CRC-32 (reflected polynomial `0xEDB88320`), and the
/// firmware calls it with `UINT32_MAX` as the starting value. Python's port
/// spells that `zlib.crc32(data, 0xFFFFFFFF)`, which is subtly different from
/// "seed the register with all ones": zlib treats its second argument as a
/// *running* CRC — it inverts it on the way in and inverts the result on the
/// way out — so a start value of `0xFFFFFFFF` means the register begins at
/// zero and the output is inverted once at the end. The upshot is that the
/// empty input hashes to `0xFFFFFFFF` and `'123456789'` to `0xD202D277`
/// (not the textbook `0xCBF43926`).
library;

import 'dart:typed_data';

final Uint32List _table = _buildTable();

Uint32List _buildTable() {
  final table = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    table[n] = c;
  }
  return table;
}

/// `zlib.crc32(data, start)`: continue a running CRC-32 over [data].
///
/// Every operation here stays within 32 bits so the result is the same on the
/// VM and under dart2js, where bitwise operators truncate to 32 bits.
int crc32(List<int> data, [int start = 0]) {
  var crc = (start ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  for (final byte in data) {
    crc = _table[(crc ^ byte) & 0xFF] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// The CRC the wear levelling layer stores: `esp_rom_crc32_le(UINT32_MAX, data)`.
int wlCrc32(List<int> data) => crc32(data, 0xFFFFFFFF);
