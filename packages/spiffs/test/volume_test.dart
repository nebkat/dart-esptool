// Behaviour the python generator cannot produce fixtures for: pages a device
// deleted or superseded, half-written files, damaged tables, and the builder's
// limits. Images are built with spiffsCreate and then edited the way the
// firmware would edit flash (only ever clearing bits).
import 'dart:typed_data';

import 'package:spiffs/spiffs.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

const _config = SpiffsConfig.defaults;

Uint8List _bytes(String text) => Uint8List.fromList(text.codeUnits);

/// A 64 KiB image with three files: `a.txt` (1 page), `b.bin` (3 pages) and `c.txt`.
Uint8List _image() => spiffsCreate([
      (path: 'a.txt', bytes: _bytes('alpha')),
      (path: 'b.bin', bytes: pattern(600, 1)),
      (path: 'c.txt', bytes: _bytes('charlie')),
    ], 0x10000);

/// Page indexes whose lookup entry is [objId] (index pages carry the flag).
List<int> _pagesOf(Uint8List image, int objId, {bool index = false}) {
  final view = ByteData.sublistView(image);
  final wanted = index ? objId | SpiffsConfig.objIdIndexFlag : objId;
  final pages = <int>[];
  for (var block = 0; block < image.length ~/ _config.blockSize; block++) {
    for (var slot = 0; slot < _config.usablePagesPerBlock; slot++) {
      if (view.getUint16(block * _config.blockSize + slot * 2, Endian.little) == wanted) {
        pages.add(block * _config.pagesPerBlock + _config.lookupPagesPerBlock + slot);
      }
    }
  }
  return pages;
}

/// Delete a page as the firmware does: clear the deleted flag, zero the lookup slot.
void _deletePage(Uint8List image, int page) {
  image[page * _config.pageSize + 4] &= ~SpiffsFlags.deleted & 0xFF;
  final block = page ~/ _config.pagesPerBlock;
  final slot = page % _config.pagesPerBlock - _config.lookupPagesPerBlock;
  ByteData.sublistView(image).setUint16(block * _config.blockSize + slot * 2, SpiffsConfig.objIdDeleted, Endian.little);
}

/// Copy [page] to the first free page, tagging it with the same object id, and
/// return the copy's index.
int _clonePage(Uint8List image, int page) {
  final view = ByteData.sublistView(image);
  for (var block = 0; block < image.length ~/ _config.blockSize; block++) {
    for (var slot = 0; slot < _config.usablePagesPerBlock; slot++) {
      final lu = block * _config.blockSize + slot * 2;
      if (view.getUint16(lu, Endian.little) != SpiffsConfig.objIdFree) continue;
      view.setUint16(lu, view.getUint16(page * _config.pageSize, Endian.little), Endian.little);
      final copy = block * _config.pagesPerBlock + _config.lookupPagesPerBlock + slot;
      image.setRange(copy * _config.pageSize, (copy + 1) * _config.pageSize, image, page * _config.pageSize);
      return copy;
    }
  }
  throw StateError('image full');
}

void main() {
  group('live pages', () {
    test('a deleted file disappears, the rest stay readable', () {
      final image = _image();
      for (final page in [..._pagesOf(image, 2), ..._pagesOf(image, 2, index: true)]) {
        _deletePage(image, page);
      }
      final volume = SpiffsVolume.mount(image, strict: true);
      expect(volume.entries.map((e) => e.path), ['a.txt', 'c.txt']);
      expect(volume.read('c.txt'), _bytes('charlie'));
      expect(() => volume.read('b.bin'), throwsA(isA<SpiffsException>()));
    });

    test('a superseded data page is ignored in favour of what the index points at', () {
      final image = _image();
      final old = _pagesOf(image, 2)[1];
      // The firmware rewrites a page by writing the new copy, repointing the index, then
      // deleting the old page. Stop after the first two steps.
      final fresh = _clonePage(image, old);
      image.fillRange(fresh * _config.pageSize + 5, (fresh + 1) * _config.pageSize, 0x42);
      final indexPage = _pagesOf(image, 2, index: true).single;
      final view = ByteData.sublistView(image);
      final tableEntry = indexPage * _config.pageSize + _config.headTableOffset + 1 * 2;
      expect(view.getUint16(tableEntry, Endian.little), old);
      // Only clearing bits would be needed on a real device; here we just overwrite.
      view.setUint16(tableEntry, fresh, Endian.little);

      final volume = SpiffsVolume.mount(image);
      expect(volume.errors, [contains('data span 1 is live on both page $old and page $fresh')]);
      final data = volume.read('b.bin');
      expect(data.sublist(0, 251), pattern(600, 1).sublist(0, 251));
      expect(data.sublist(251, 502), everyElement(0x42));
      expect(() => SpiffsVolume.mount(image, strict: true), throwsA(isA<SpiffsException>()));
    });

    test('a stale index entry falls back to the page that claims the span', () {
      final image = _image();
      final indexPage = _pagesOf(image, 2, index: true).single;
      final view = ByteData.sublistView(image);
      view.setUint16(indexPage * _config.pageSize + _config.headTableOffset + 2 * 2, 0x0123, Endian.little);
      final volume = SpiffsVolume.mount(image);
      expect(volume.errors, [contains('index entry for data page 2 points at page 291')]);
      expect(volume.read('b.bin'), pattern(600, 1));
    });

    test('a page not yet final is skipped', () {
      final image = _image();
      final page = _pagesOf(image, 1).single;
      image[page * _config.pageSize + 4] |= SpiffsFlags.finalized; // unwritten flag bit
      final volume = SpiffsVolume.mount(image);
      expect(volume.errors, [
        "'/a.txt' (object 0x1): index entry for data page 0 points at page $page, which is not a live data page of it",
        "'/a.txt' (object 0x1): data page 0 is missing",
      ]);
      expect(() => volume.read('a.txt'), throwsA(isA<SpiffsException>()));
    });

    test('orphaned data pages are reported', () {
      final image = _image();
      _deletePage(image, _pagesOf(image, 3, index: true).single);
      final volume = SpiffsVolume.mount(image);
      expect(volume.entries.map((e) => e.path), ['a.txt', 'b.bin']);
      expect(volume.errors, ['object 0x3: data pages without any index page']);
    });

    test('a file whose size was never written is recovered from its pages', () {
      final image = _image();
      final indexPage = _pagesOf(image, 2, index: true).single;
      ByteData.sublistView(image)
          .setUint32(indexPage * _config.pageSize + SpiffsConfig.dataHeaderLenAligned, 0xFFFFFFFF, Endian.little);
      final volume = SpiffsVolume.mount(image);
      expect(volume.errors, [contains('size was never written; recovering 753 bytes')]);
      expect(volume.entries.firstWhere((e) => e.path == 'b.bin').size, 3 * 251);
      expect(volume.read('b.bin').sublist(0, 600), pattern(600, 1));
    });
  });

  group('mount', () {
    test('rejects sizes that are not whole blocks', () {
      expect(() => SpiffsVolume.mount(Uint8List(0)), throwsA(isA<SpiffsException>()));
      expect(() => SpiffsVolume.mount(Uint8List(0x1800)), throwsA(isA<SpiffsException>()));
    });

    test('rejects erased flash but accepts an empty volume', () {
      final blank = Uint8List(0x10000)..fillRange(0, 0x10000, 0xFF);
      expect(() => SpiffsVolume.mount(blank), throwsA(isA<SpiffsException>()));
      expect(SpiffsVolume.mount(spiffsCreate([], 0x10000)).entries, isEmpty);
      // Without magic there is nothing to check, so erased flash is an empty volume.
      expect(SpiffsVolume.mount(blank, config: const SpiffsConfig(useMagic: false)).entries, isEmpty);
    });

    test('read of an unknown path throws', () {
      expect(() => SpiffsVolume.mount(_image()).read('nope'), throwsA(isA<SpiffsException>()));
    });

    test('detect probes page sizes and magic-length variants', () {
      for (final pageSize in SpiffsConfig.candidatePageSizes) {
        for (final useMagicLen in [true, false]) {
          final config = SpiffsConfig(pageSize: pageSize, useMagicLen: useMagicLen);
          final image = spiffsCreate([(path: 'a', bytes: _bytes('x'))], 0x8000, config: config);
          expect(SpiffsVolume.detect(image), isTrue, reason: '$config');
          expect(SpiffsVolume.detect(image, config: config), isTrue);
          expect(SpiffsVolume.detect(image, config: config.copyWith(pageSize: pageSize == 256 ? 512 : 256)), isFalse);
        }
      }
      expect(SpiffsVolume.detect(Uint8List(0x1000)), isFalse);
      expect(SpiffsVolume.detect(Uint8List(0x800)), isFalse);
      expect(SpiffsVolume.detect(spiffsCreate([], 0x8000, config: const SpiffsConfig(useMagic: false))), isFalse);
    });

    test('a 64 KiB block with two lookup pages', () {
      const config = SpiffsConfig(blockSize: 0x10000);
      expect(config.lookupPagesPerBlock, 2);
      expect(config.usablePagesPerBlock, 254);
      final files = [for (var i = 0; i < 300; i++) (path: 'f$i', bytes: pattern(i * 3, i))];
      final image = spiffsCreate(files, 0x40000, config: config);
      expect(SpiffsVolume.detect(image, config: config), isTrue);
      final volume = SpiffsVolume.mount(image, config: config, strict: true);
      expect(volume.entries.length, 300);
      for (final file in files) {
        expect(volume.read(file.path), file.bytes);
      }
    });
  });

  group('spiffsCreate', () {
    test('size must be whole blocks', () {
      expect(() => spiffsCreate([], 0x1800), throwsA(isA<SpiffsException>()));
      expect(() => spiffsCreate([], 0), throwsA(isA<SpiffsException>()));
    });

    test('names are limited by their UTF-8 length including the leading slash', () {
      final ok = 'a' * 31;
      expect(SpiffsVolume.mount(spiffsCreate([(path: ok, bytes: Uint8List(0))], 0x1000)).entries.single.path, ok);
      expect(() => spiffsCreate([(path: '${ok}a', bytes: Uint8List(0))], 0x1000), throwsA(isA<SpiffsException>()));
      // 'é' is two bytes: 30 code points but 32 bytes with the slash — still fits, 33 does not.
      final accented = 'é' * 15 + 'x';
      final image = spiffsCreate([(path: accented, bytes: _bytes('hi'))], 0x1000);
      expect(SpiffsVolume.mount(image, strict: true).read(accented), _bytes('hi'));
      expect(() => spiffsCreate([(path: '${accented}x', bytes: Uint8List(0))], 0x1000), throwsA(isA<SpiffsException>()));
    });

    test('an image that is too small throws', () {
      // One block: 15 usable pages, so 14 data pages plus the index page fit and 15 don't.
      expect(spiffsCreate([(path: 'f', bytes: Uint8List(14 * 251))], 0x1000), hasLength(0x1000));
      expect(() => spiffsCreate([(path: 'f', bytes: Uint8List(14 * 251 + 1))], 0x1000), throwsA(isA<SpiffsException>()));
      // Each file needs an index page even when empty.
      final empties = [for (var i = 0; i < 15; i++) (path: 'e$i', bytes: Uint8List(0))];
      expect(spiffsCreate(empties, 0x1000), hasLength(0x1000));
      expect(() => spiffsCreate([...empties, (path: 'x', bytes: Uint8List(0))], 0x1000), throwsA(isA<SpiffsException>()));
    });

    test('many index pages, files straddling blocks', () {
      // 300 data pages need a head index page (103 entries) and two more (124 each).
      final big = pattern(300 * 251 - 5, 7);
      final files = [(path: 'first', bytes: _bytes('1')), (path: 'big', bytes: big), (path: 'last', bytes: _bytes('2'))];
      final image = spiffsCreate(files, 0x20000);
      expect(_pagesOf(image, 2, index: true), hasLength(3));
      final volume = SpiffsVolume.mount(image, strict: true);
      expect(volume.read('big'), big);
      expect(volume.read('last'), _bytes('2'));
      expect(volume.entries.map((e) => e.path), ['big', 'first', 'last']);
    });

    test('a file of exactly one page and an empty file', () {
      final image = spiffsCreate([(path: 'page', bytes: pattern(251, 3)), (path: 'empty', bytes: Uint8List(0))], 0x1000);
      final volume = SpiffsVolume.mount(image, strict: true);
      expect(volume.read('page'), pattern(251, 3));
      expect(volume.read('empty'), isEmpty);
      expect(_pagesOf(image, 1), hasLength(1));
      expect(_pagesOf(image, 2), isEmpty);
    });

    test('config validation', () {
      expect(() => spiffsCreate([], 0x1000, config: const SpiffsConfig(pageSize: 300)), throwsA(isA<SpiffsException>()));
      expect(() => spiffsCreate([], 0x1000, config: const SpiffsConfig(pageSize: 8192)), throwsA(isA<SpiffsException>()));
      expect(() => spiffsCreate([], 0x1000, config: const SpiffsConfig(objNameLen: 1)), throwsA(isA<SpiffsException>()));
      expect(const SpiffsConfig().describe(0x10000), 'SPIFFS, 16 blocks of 0x1000 bytes, 0x100-byte pages, name limit 32');
    });

    test('aligned object index tables shift the head table by a byte', () {
      // The default 49-byte index header is odd, so alignment moves the table to 50.
      const config = SpiffsConfig(alignedObjIxTables: true);
      expect(SpiffsConfig.defaults.indexHeaderLen, 49);
      expect(SpiffsConfig.defaults.headTableOffset, 49);
      expect(config.headTableOffset, 50);
      expect(config.headTableEntries, 103);
      // An even header needs no padding.
      expect(const SpiffsConfig(objNameLen: 33, alignedObjIxTables: true).headTableOffset, 50);
      final big = pattern(200 * 251, 9);
      final image = spiffsCreate([(path: 'big', bytes: big)], 0x20000, config: config);
      expect(SpiffsVolume.mount(image, config: config, strict: true).read('big'), big);
      expect(SpiffsVolume.mount(image).errors, isNotEmpty);
    });
  });
}
