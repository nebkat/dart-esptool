@TestOn('vm')
library;

// Every image under test/fixtures/ was built and listed by the python idftool
// CLI; the Dart reader must see the same files, and the Dart builder must
// produce the same bytes.
import 'dart:typed_data';

import 'package:spiffs/spiffs.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  final cases = FixtureCase.all();
  test('fixtures are present', () {
    expect(cases.map((c) => c.name), containsAll(['empty', 'small', 'large', 'nested', 'names', 'mib']));
  });

  for (final fixture in cases) {
    group(fixture.name, () {
      late final Uint8List image = fixture.image;
      late final SpiffsConfig config = fixture.config;

      test('mount lists what python listed', () {
        final volume = SpiffsVolume.mount(image, config: config, strict: true);
        expect(volume.errors, isEmpty);
        expect({for (final e in volume.entries) e.path: e.size}, fixture.listing);
        expect(volume.entries.map((e) => e.path), fixture.listing.keys, reason: 'sorted like python');
        expect(volume.entries.every((e) => !e.isDir), isTrue);
      });

      test('read returns the packed bytes', () {
        final volume = SpiffsVolume.mount(image, config: config, strict: true);
        final expected = fixture.sourceFiles;
        expect(volume.entries.map((e) => e.path).toSet(), expected.keys.toSet());
        for (final MapEntry(key: path, value: bytes) in expected.entries) {
          expect(volume.read(path), bytes, reason: path);
          expect(volume.read('/$path'), bytes, reason: 'leading slash accepted');
        }
      });

      test('detect', () {
        expect(SpiffsVolume.detect(image, config: config), config.useMagic);
        // Without a config the default block size is assumed and page sizes probed.
        if (config.blockSize == SpiffsConfig.defaults.blockSize) {
          expect(SpiffsVolume.detect(image), config.useMagic);
        }
      });

      test('spiffsCreate is byte-identical to python', () {
        final created = spiffsCreate(fixture.sources, fixture.size, config: config);
        expect(created.length, image.length);
        final firstDiff = _firstDifference(created, image);
        expect(firstDiff, -1, reason: 'first differing byte at offset $firstDiff');
      });

      test('round-trips through mount', () {
        final created = spiffsCreate(fixture.sources, fixture.size, config: config);
        final volume = SpiffsVolume.mount(created, config: config, strict: true);
        final expected = fixture.sourceFiles;
        expect({for (final e in volume.entries) e.path: e.size}, {for (final e in expected.entries) e.key: e.value.length});
        for (final MapEntry(key: path, value: bytes) in expected.entries) {
          expect(volume.read(path), bytes, reason: path);
        }
      });
    });
  }
}

int _firstDifference(Uint8List a, Uint8List b) {
  for (var i = 0; i < a.length && i < b.length; i++) {
    if (a[i] != b[i]) return i;
  }
  return a.length == b.length ? -1 : a.length.clamp(0, b.length);
}
