@TestOn('browser')
library;

// Everything must work when compiled to JavaScript (the web app), where ints
// are doubles, bitwise operators are 32-bit and typed-data views behave
// differently from the VM. Run with `dart test -p chrome`.
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:fatfs/fatfs.dart';
import 'package:fatfs/src/crc32.dart';
import 'package:test/test.dart';

import 'inline_fixtures.dart';

Uint8List gunzip(String b64) => Uint8List.fromList(const GZipDecoder().decodeBytes(base64Decode(b64)));

void main() {
  final fixture = jsonDecode(tinyFixtureJson) as Map<String, dynamic>;
  final image = gunzip(tinyImageGzBase64);
  final raw = gunzip(tinyRawGzBase64);
  final sources = [
    for (final s in fixture['sources'] as List)
      (
        path: (s['is_dir'] as bool) ? '${s['path']}/' : s['path'] as String,
        bytes: s['data'] == null ? Uint8List(0) : base64Decode(s['data'] as String),
        modified: DateTime.fromMillisecondsSinceEpoch((s['mtime'] as int) * 1000, isUtc: true),
      ),
  ];

  test('crc32 stays within 32 bits', () {
    expect(wlCrc32('123456789'.codeUnits), 0xD202D277);
    expect(wlCrc32([]), 0xFFFFFFFF);
    // Inputs that drive the register through its high bit; values from python's zlib.
    expect(wlCrc32([0xFF, 0xFF, 0xFF, 0xFF, 0x80, 0x00]), 0x8A4139E8);
    final all = [for (var i = 0; i < 1024; i++) i & 0xFF];
    expect(wlCrc32(all), 0xA7411CF7);
    expect(crc32(all), 0xB70B4C26);
  });

  test('wear levelling round trip and python parity', () {
    expect(looksLikeWl(image), isTrue);
    expect(wlUnwrap(image), raw);
    expect(wlWrap(raw, fixture['size'] as int, deviceId: fixture['options']['device_id'] as int), image);
  });

  test('mounts a python-built image', () {
    final volume = FatVolume.mount(image, strict: true);
    expect(volume.geometry.toString(), 'FAT12, 21 clusters of 0x1000 bytes');
    expect(volume.geometry.volumeId, 0x12345678);
    expect(volume.entries.map((e) => e.path), ['a.txt', 'dir', 'dir/Long Name.txt', 'dir/b.bin']);
    for (final source in sources.where((s) => !s.path.endsWith('/'))) {
      expect(volume.read(source.path), source.bytes, reason: source.path);
      // DOS time has two-second resolution.
      final m = source.modified;
      expect(
          volume.lookup(source.path)!.modified, DateTime.utc(m.year, m.month, m.day, m.hour, m.minute, m.second & ~1),
          reason: source.path);
    }
    expect(volume.lookup('dir/Long Name.txt')!.shortName, 'LONGNAM.TXT');
  });

  test('builds the same image as python', () {
    final built = fatCreate(sources, fixture['size'] as int,
        volumeId: fixture['options']['volume_id'] as int, deviceId: fixture['options']['device_id'] as int);
    expect(built, image);
  });

  test('create and mount round trip with a FAT16 geometry', () {
    final data = Uint8List.fromList([for (var i = 0; i < 70000; i++) (i * 31) & 0xFF]);
    final built = fatCreate([
      (path: 'big.bin', bytes: data, modified: DateTime.utc(2030, 12, 31, 23, 59, 58)),
      (path: 'd/Straße.txt', bytes: Uint8List.fromList([1, 2, 3]), modified: null),
    ], 0x400000, sectorSize: 512, timestamp: DateTime.utc(2001, 2, 3));
    final volume = FatVolume.mount(built, strict: true);
    expect(volume.geometry.bits, FatBits.fat16);
    expect(volume.read('big.bin'), data);
    expect(volume.read('d/Straße.txt'), [1, 2, 3]);
    expect(volume.lookup('d/Straße.txt')!.shortName, 'STRASSE.TXT');
    expect(volume.lookup('big.bin')!.modified, DateTime.utc(2030, 12, 31, 23, 59, 58));
    expect(volume.lookup('d')!.modified, DateTime.utc(2001, 2, 3));
    // 137 clusters of data, one for the directory, one for the three-byte file.
    expect(volume.freeClusters, volume.geometry.clusterCount - 137 - 1 - 1);
  });
}
