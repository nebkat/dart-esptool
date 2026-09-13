/// NVS partition images: the on-flash layout, parsing one back into key/value
/// pairs, generating one from CSV, and editing one in place.
library;

import 'dart:typed_data';

import 'common.dart';

export 'common.dart';
export 'crypto.dart' show NvsKeys, encryptNvs, decryptNvs, looksEncryptedNvs;
export 'csv.dart';
export 'edit.dart';
export 'parser.dart';
export 'spec.dart';
export 'writer.dart' show NvsWriter, generatorSize, encodePrimitive, encodeVarlen, encodeBlobIndex;

/// Whether [data] parses as an NVS partition image.
///
/// An NVS partition is a sequence of 4 KiB pages. A page is either entirely
/// erased (all `0xFF`) or carries a 32-byte header whose last 4 bytes are the
/// CRC32 of header bytes `[4:28]`, with a version byte of `0xFF` (v1) or
/// `0xFE` (v2). The header CRC is a strong signature: matching it on a
/// non-erased page means the file really is an NVS image, not CSV.
///
/// Deliberately a cheap sniff rather than a full [parseNvs], because it runs
/// on files that are usually *not* NVS images and only has to tell the two
/// apart.
bool looksLikeNvsBinary(Uint8List data) {
  if (data.isEmpty || data.length % NvsLayout.pageSize != 0) return false;

  var nonBlankPages = 0;
  for (var offset = 0; offset < data.length; offset += NvsLayout.pageSize) {
    final page = Uint8List.sublistView(data, offset, offset + NvsLayout.pageSize);
    if (page.every((b) => b == 0xFF)) continue;
    final header = Uint8List.sublistView(page, 0, NvsLayout.headerSize);
    if (NvsVersion.fromByte(header[8]) == null) return false;
    final stored = ByteData.sublistView(header).getUint32(28, Endian.little);
    if (stored != headerCrc(header)) return false;
    nonBlankPages++;
  }

  // A valid NVS image has at least one initialised (non-blank) page.
  return nonBlankPages > 0;
}

/// Validate a pre-built NVS binary against a partition size and pad it out.
///
/// The image must fit the partition; if it is smaller it is padded with
/// `0xFF` (erased flash) so the whole partition is written cleanly.
Uint8List fitNvsBinary(Uint8List data, int size) {
  if (data.length > size) {
    throw NvsError('NVS binary size 0x${data.length.toRadixString(16)} exceeds partition size '
        '0x${size.toRadixString(16)}');
  }
  if (data.length == size) return data;
  return Uint8List(size)
    ..setRange(0, data.length, data)
    ..fillRange(data.length, size, 0xFF);
}
