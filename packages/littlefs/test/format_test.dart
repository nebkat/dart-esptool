// Hand-built metadata logs for the states littlefs only reaches after power
// loss or corruption, which the python oracle cannot produce on demand. The
// builder writes the on-disk format described in lib/src/common.dart.
import 'dart:convert';
import 'dart:typed_data';

import 'package:littlefs/littlefs.dart';
import 'package:test/test.dart';

const _blockSize = 4096;
const _blockCount = 16;

List<int> _le32(int value) => [value & 0xFF, (value >>> 8) & 0xFF, (value >>> 16) & 0xFF, (value >>> 24) & 0xFF];

List<int> _pair(LfsPair pair) => [..._le32(pair.$1), ..._le32(pair.$2)];

/// Appends tags and commits to one metadata block.
class _Log {
  _Log({int rev = 1, int blockSize = _blockSize}) : bytes = Uint8List(blockSize) {
    bytes.fillRange(0, bytes.length, 0xFF);
    ByteData.sublistView(bytes).setUint32(0, rev, Endian.little);
    _crc = lfsCrc(0xFFFFFFFF, bytes, 0, 4);
  }

  final Uint8List bytes;
  int _off = 4;
  int _ptag = 0xFFFFFFFF;
  late int _crc;

  void _word(int tag) {
    ByteData.sublistView(bytes).setUint32(_off, tag ^ _ptag);
    _crc = lfsCrc(_crc, bytes, _off, _off + 4);
    _ptag = tag;
    _off += 4;
  }

  void tag(int type, int id, List<int> data, {bool removed = false}) {
    _word(LfsTag.make(type, id, removed ? 0x3FF : data.length));
    if (removed) return;
    bytes.setRange(_off, _off + data.length, data);
    _crc = lfsCrc(_crc, bytes, _off, _off + data.length);
    _off += data.length;
  }

  /// Ends the commit. [flip] sets the CRC tag's low chunk bit, which inverts
  /// the valid bit expected of the next commit; [corrupt] stores a wrong CRC.
  void commit({int padding = 0, bool flip = false, bool corrupt = false}) {
    _word(LfsTag.make(LfsType.ccrc | (flip ? 1 : 0), 0x3FF, 4 + padding));
    ByteData.sublistView(bytes).setUint32(_off, corrupt ? _crc ^ 0x5A5A5A5A : _crc, Endian.little);
    _off += 4 + padding;
    _ptag ^= (flip ? 1 : 0) << 31;
    _crc = 0xFFFFFFFF;
  }

  void name(int id, int fileType, String name) => tag(fileType, id, utf8.encode(name));
  void inline(int id, List<int> data) => tag(LfsType.inlineStruct, id, data);
  void ctz(int id, int head, int size) => tag(LfsType.ctzStruct, id, [..._le32(head), ..._le32(size)]);
  void dir(int id, LfsPair pair) => tag(LfsType.dirStruct, id, _pair(pair));
  void tail(LfsPair pair, {bool hard = false}) => tag(hard ? LfsType.hardTail : LfsType.softTail, 0x3FF, _pair(pair));
  void create(int id) => tag(LfsType.create, id, []);
  void delete(int id) => tag(LfsType.delete, id, []);
  void moveState(int tag, LfsPair pair) => this.tag(LfsType.moveState, 0x3FF, [..._le32(tag), ..._pair(pair)]);

  void superblock({
    int blockSize = _blockSize,
    int blockCount = _blockCount,
    int nameMax = 64,
    int version = LfsLayout.diskVersion21,
  }) {
    name(0, LfsType.superblock, LfsLayout.magic);
    inline(
        0, [..._le32(version), ..._le32(blockSize), ..._le32(blockCount), ..._le32(nameMax), ..._le32(0), ..._le32(0)]);
  }

  void file(int id, String name, List<int> data) {
    this.name(id, LfsType.reg, name);
    inline(id, data);
  }
}

/// An image of erased blocks with [blocks] written in.
Uint8List _image(Map<int, Uint8List> blocks, {int blockSize = _blockSize, int blockCount = _blockCount}) {
  final image = Uint8List(blockSize * blockCount)..fillRange(0, blockSize * blockCount, 0xFF);
  blocks.forEach((index, block) => image.setRange(index * blockSize, (index + 1) * blockSize, block));
  return image;
}

/// A CTZ skip-list for [data] in consecutive blocks from [firstBlock].
/// Returns the blocks and the head (the block of the last index).
(Map<int, Uint8List>, int) _ctzList(List<int> data, int firstBlock, {int blockSize = _blockSize}) {
  final blocks = <int, Uint8List>{};
  var pos = 0;
  var index = 0;
  do {
    final pointers = index == 0 ? 0 : lfsCtz(index) + 1;
    final block = Uint8List(blockSize)..fillRange(0, blockSize, 0xFF);
    for (var k = 0; k < pointers; k++) {
      block.setRange(4 * k, 4 * k + 4, _le32(firstBlock + index - (1 << k)));
    }
    final capacity = blockSize - 4 * pointers;
    final chunk = data.sublist(pos, (pos + capacity).clamp(0, data.length));
    block.setRange(4 * pointers, 4 * pointers + chunk.length, chunk);
    blocks[firstBlock + index] = block;
    pos += capacity;
    index++;
  } while (pos < data.length);
  return (blocks, firstBlock + index - 1);
}

List<int> _pattern(int length, int seed) => List.generate(length, (i) => (i * 31 + seed + (i >> 8)) & 0xFF);

List<String> _paths(LittleFsVolume v) => v.entries.map((e) => e.isDir ? '${e.path}/' : e.path).toList();

void main() {
  group('a hand-built volume', () {
    late Uint8List image;
    late LittleFsVolume volume;
    setUpAll(() {
      final (ctzBlocks, head) = _ctzList(_pattern(9000, 1), 4);
      final root = _Log()
        ..superblock()
        ..file(1, 'a.txt', utf8.encode('inline a'))
        ..name(2, LfsType.dir, 'd')
        ..dir(2, (2, 3))
        ..name(3, LfsType.reg, 'big.bin')
        ..ctz(3, head, 9000)
        ..tail((2, 3))
        ..commit();
      final d = _Log()
        ..file(0, 'x', utf8.encode('x in d'))
        ..name(1, LfsType.reg, 'empty')
        ..inline(1, [])
        ..commit();
      image = _image({0: root.bytes, 2: d.bytes, ...ctzBlocks});
      volume = LittleFsVolume.mount(image, strict: true);
    });

    test('lists depth-first with directories recursed', () {
      expect(_paths(volume), ['a.txt', 'big.bin', 'd/', 'd/empty', 'd/x']);
      expect(volume.entries.map((e) => e.size), [8, 9000, 0, 0, 6]);
    });

    test('reads inline, empty and CTZ files', () {
      expect(utf8.decode(volume.read('a.txt')), 'inline a');
      expect(utf8.decode(volume.read('d/x')), 'x in d');
      expect(volume.read('d/empty'), isEmpty);
      expect(volume.read('big.bin'), _pattern(9000, 1));
      expect(volume.read('/big.bin'), _pattern(9000, 1));
    });

    test('reports the geometry with littlefs defaults for zero limits', () {
      expect(volume.geometry.blockSize, _blockSize);
      expect(volume.geometry.blockCount, _blockCount);
      expect(volume.geometry.nameMax, 64);
      expect(volume.geometry.fileMax, LfsLayout.defaultFileMax);
      expect(volume.geometry.attrMax, LfsLayout.defaultAttrMax);
      expect(volume.geometry.versionString, '2.1');
    });

    test('refuses to read directories and missing files', () {
      expect(() => volume.read('d'), throwsA(isA<LittleFsException>()));
      expect(() => volume.read('nope'), throwsA(isA<LittleFsException>()));
    });

    test('detect and sniff', () {
      expect(LittleFsVolume.detect(image), isTrue);
      expect(sniffSuperblock(image), (offset: 0, blockSize: _blockSize, blockCount: _blockCount, nameMax: 64));
      expect(LittleFsVolume.detect(Uint8List(0x10000)..fillRange(0, 0x10000, 0xFF)), isFalse);
      expect(LittleFsVolume.detect(Uint8List.fromList(_pattern(0x10000, 7))), isFalse);
      expect(LittleFsVolume.detect(Uint8List(0)), isFalse);
    });
  });

  group('log replay', () {
    test('the newest tag for an id wins, and a failed commit is ignored', () {
      final (ctzBlocks, head) = _ctzList(_pattern(5000, 2), 4);
      final root = _Log()
        ..superblock()
        ..file(1, 'a.txt', utf8.encode('old'))
        ..commit()
        ..inline(1, utf8.encode('new'))
        ..commit()
        ..name(2, LfsType.reg, 'b.bin')
        ..inline(2, utf8.encode('small'))
        ..commit()
        ..ctz(2, head, 5000) // inline -> CTZ
        ..commit()
        ..inline(1, utf8.encode('never committed'))
        ..commit(corrupt: true)
        ..inline(1, utf8.encode('after the bad commit'))
        ..commit();
      final volume = LittleFsVolume.mount(_image({0: root.bytes, ...ctzBlocks}), strict: true);
      expect(_paths(volume), ['a.txt', 'b.bin']);
      expect(utf8.decode(volume.read('a.txt')), 'new');
      expect(volume.read('b.bin'), _pattern(5000, 2));
    });

    test('DELETE closes the id and shifts later ids down', () {
      final root = _Log()
        ..superblock()
        ..file(1, 'a', [1])
        ..file(2, 'b', [2])
        ..file(3, 'c', [3])
        ..commit()
        ..delete(2)
        ..commit()
        ..inline(2, [33]) // id 2 is now c
        ..commit();
      final volume = LittleFsVolume.mount(_image({0: root.bytes}), strict: true);
      expect(_paths(volume), ['a', 'c']);
      expect(volume.read('c'), [33]);
    });

    test('CREATE opens a gap and shifts later ids up', () {
      final root = _Log()
        ..superblock()
        ..file(1, 'b', [2])
        ..file(2, 'c', [3])
        ..commit()
        ..create(1)
        ..file(1, 'a', [1])
        ..commit()
        ..inline(3, [33]) // c moved to id 3
        ..commit();
      final volume = LittleFsVolume.mount(_image({0: root.bytes}), strict: true);
      expect(_paths(volume), ['a', 'b', 'c']);
      expect(volume.read('a'), [1]);
      expect(volume.read('b'), [2]);
      expect(volume.read('c'), [33]);
    });

    test('a removed attribute (length 0x3FF) drops the struct, leaving a nameless-struct entry', () {
      final root = _Log()
        ..superblock()
        ..file(1, 'a', [1])
        ..file(2, 'b', [2])
        ..commit()
        ..tag(LfsType.inlineStruct, 1, [], removed: true)
        ..commit();
      final lenient = LittleFsVolume.mount(_image({0: root.bytes}));
      expect(_paths(lenient), ['b']);
      expect(lenient.errors, [contains("'a' has a name but no struct")]);
      expect(() => LittleFsVolume.mount(_image({0: root.bytes}), strict: true), throwsA(isA<LittleFsException>()));
    });

    test('unknown tag types are skipped by their length', () {
      final root = _Log()
        ..superblock()
        ..file(1, 'a', [1])
        ..tag(LfsType.userAttr | 0x42, 1, List.filled(300, 7))
        ..tag(0x7A1, 0x3FF, [1, 2, 3])
        ..tag(LfsType.fcrc, 0x3FF, [..._le32(64), ..._le32(0x12345678)])
        ..tag(0x1FE, 1, [9, 9])
        ..file(2, 'b', [2])
        ..commit();
      final volume = LittleFsVolume.mount(_image({0: root.bytes}), strict: true);
      expect(_paths(volume), ['a', 'b']);
      expect(volume.read('b'), [2]);
    });

    test('the CRC reset bit flips the valid bit expected of the next commit', () {
      final root = _Log()
        ..superblock()
        ..file(1, 'a', [1])
        ..commit(flip: true, padding: 12)
        ..file(2, 'b', [2])
        ..commit(padding: 3)
        ..file(3, 'c', [3])
        ..commit();
      final volume = LittleFsVolume.mount(_image({0: root.bytes}), strict: true);
      expect(_paths(volume), ['a', 'b', 'c']);
    });

    test('a truncated tag at the end of the block ends the log', () {
      final root = _Log()
        ..superblock()
        ..file(1, 'a', [1])
        ..commit(padding: _blockSize - 200);
      // A plausible tag header near the end of the block, claiming more data
      // than is left in it.
      final view = ByteData.sublistView(root.bytes);
      final off = root._off;
      expect(off + 4 + 0x3FE, greaterThan(_blockSize));
      view.setUint32(off, LfsTag.make(LfsType.inlineStruct, 1, 0x3FE) ^ root._ptag);
      root.bytes.fillRange(off + 4, root.bytes.length, 0x00);
      final volume = LittleFsVolume.mount(_image({0: root.bytes}), strict: true);
      expect(_paths(volume), ['a']);
    });
  });

  group('metadata pairs', () {
    test('the block with the newer revision wins', () {
      final old = _Log(rev: 5)
        ..superblock()
        ..file(1, 'old', [0])
        ..commit();
      final fresh = _Log(rev: 6)
        ..superblock()
        ..file(1, 'new', [1])
        ..commit();
      expect(_paths(LittleFsVolume.mount(_image({0: old.bytes, 1: fresh.bytes}), strict: true)), ['new']);
      expect(_paths(LittleFsVolume.mount(_image({0: fresh.bytes, 1: old.bytes}), strict: true)), ['new']);
    });

    test('revision counts compare as sequence numbers across the wrap', () {
      final old = _Log(rev: 0xFFFFFFFF)
        ..superblock()
        ..file(1, 'old', [0])
        ..commit();
      final fresh = _Log(rev: 0)
        ..superblock()
        ..file(1, 'new', [1])
        ..commit();
      expect(_paths(LittleFsVolume.mount(_image({0: old.bytes, 1: fresh.bytes}), strict: true)), ['new']);
    });

    test('a newer block with no valid commit falls back to the older one', () {
      final good = _Log(rev: 5)
        ..superblock()
        ..file(1, 'good', [0])
        ..commit();
      final bad = _Log(rev: 6)
        ..superblock()
        ..file(1, 'bad', [1])
        ..commit(corrupt: true);
      final volume = LittleFsVolume.mount(_image({0: bad.bytes, 1: good.bytes}), strict: true);
      expect(_paths(volume), ['good']);
      expect(sniffSuperblock(_image({0: bad.bytes, 1: good.bytes}))!.offset, 0);
    });

    test('a superblock only in block 1 is found by probing block sizes', () {
      for (final blockSize in [512, 4096, 8192]) {
        final fresh = _Log(rev: 2, blockSize: blockSize)
          ..superblock(blockSize: blockSize, blockCount: 32)
          ..file(1, 'only', [1])
          ..commit();
        final image = _image({1: fresh.bytes}, blockSize: blockSize, blockCount: 32);
        expect(LittleFsVolume.detect(image), isTrue, reason: 'block size $blockSize');
        final volume = LittleFsVolume.mount(image, strict: true);
        expect(volume.geometry.blockSize, blockSize);
        expect(_paths(volume), ['only']);
      }
    });

    test('an image with no superblock does not mount', () {
      expect(() => LittleFsVolume.mount(_image({})), throwsA(isA<LittleFsException>()));
      expect(() => LittleFsVolume.mount(_image({}), blockSize: _blockSize), throwsA(isA<LittleFsException>()));
      expect(() => LittleFsVolume.mount(Uint8List(0)), throwsA(isA<LittleFsException>()));
      final noMagic = _Log()
        ..file(1, 'a', [1])
        ..commit();
      expect(() => LittleFsVolume.mount(_image({0: noMagic.bytes}), blockSize: _blockSize),
          throwsA(isA<LittleFsException>()));
    });

    test('the root is the last pair in the chain that carries a superblock', () {
      final first = _Log(rev: 3)
        ..superblock()
        ..tail((2, 3))
        ..commit();
      final second = _Log()
        ..superblock()
        ..file(1, 'in-root', [1])
        ..tail((4, 5))
        ..commit();
      final other = _Log()
        ..file(0, 'orphan', [0])
        ..commit();
      final volume = LittleFsVolume.mount(_image({0: first.bytes, 2: second.bytes, 4: other.bytes}), strict: true);
      expect(_paths(volume), ['in-root']);
    });

    test('a hard tail continues the directory', () {
      final root = _Log()
        ..superblock()
        ..file(1, 'a', [1])
        ..tail((2, 3), hard: true)
        ..commit();
      final more = _Log()
        ..file(0, 'b', [2])
        ..file(1, 'c', [3])
        ..commit();
      final volume = LittleFsVolume.mount(_image({0: root.bytes, 2: more.bytes}), strict: true);
      expect(_paths(volume), ['a', 'b', 'c']);
      expect(volume.read('c'), [3]);
    });

    test('a cycle in the tail chain is reported, not followed forever', () {
      final root = _Log()
        ..superblock()
        ..file(1, 'a', [1])
        ..tail((2, 3), hard: true)
        ..commit();
      final loop = _Log()
        ..file(0, 'b', [2])
        ..tail((0, 1), hard: true)
        ..commit();
      final volume = LittleFsVolume.mount(_image({0: root.bytes, 2: loop.bytes}));
      expect(_paths(volume), ['a', 'b']);
      // Once from the mount's walk of the whole chain, once from the directory.
      expect(volume.errors, [contains('appears twice in the tail chain'), contains('already visited')]);
    });

    test('a corrupt directory pair is reported and skipped', () {
      final root = _Log()
        ..superblock()
        ..name(1, LfsType.dir, 'd')
        ..dir(1, (2, 3))
        ..file(2, 'z', [1])
        ..commit();
      final volume = LittleFsVolume.mount(_image({0: root.bytes}));
      expect(_paths(volume), ['d/', 'z']);
      expect(volume.errors, [contains('no valid commit')]);
    });
  });

  group('global state', () {
    test('a pending move hides the source id and only the source id', () {
      final root = _Log()
        ..superblock()
        ..name(1, LfsType.dir, 'dst')
        ..dir(1, (2, 3))
        ..name(2, LfsType.dir, 'src')
        ..dir(2, (4, 5))
        ..tail((2, 3))
        ..commit();
      final dst = _Log()
        ..file(0, 'moved', [1])
        ..moveState(LfsTag.make(LfsType.delete, 0, 0), (4, 5))
        ..tail((4, 5))
        ..commit();
      final src = _Log()
        ..file(0, 'moved', [1])
        ..file(1, 'stays', [2])
        ..file(2, 'zlast', [3])
        ..commit();
      final volume = LittleFsVolume.mount(_image({0: root.bytes, 2: dst.bytes, 4: src.bytes}), strict: true);
      expect(_paths(volume), ['dst/', 'dst/moved', 'src/', 'src/stays', 'src/zlast']);
      expect(volume.read('src/stays'), [2]);
    });

    test('move deltas cancel out across pairs', () {
      final root = _Log()
        ..superblock()
        ..name(1, LfsType.dir, 'd')
        ..dir(1, (2, 3))
        ..moveState(LfsTag.make(LfsType.delete, 0, 0), (2, 3))
        ..tail((2, 3))
        ..commit();
      final d = _Log()
        ..file(0, 'kept', [1])
        ..moveState(LfsTag.make(LfsType.delete, 0, 0), (2, 3)) // XOR back to zero
        ..commit();
      final volume = LittleFsVolume.mount(_image({0: root.bytes, 2: d.bytes}), strict: true);
      expect(_paths(volume), ['d/', 'd/kept']);
    });
  });

  group('geometry problems', () {
    test('a block count beyond the image is reported and clamped', () {
      final root = _Log()
        ..superblock(blockCount: 1000)
        ..file(1, 'a', [1])
        ..commit();
      final volume = LittleFsVolume.mount(_image({0: root.bytes}));
      expect(volume.errors, [contains('declares 1000 blocks')]);
      expect(volume.geometry.blockCount, _blockCount);
      expect(_paths(volume), ['a']);
      expect(() => LittleFsVolume.mount(_image({0: root.bytes}), strict: true), throwsA(isA<LittleFsException>()));
    });

    test('a block size that disagrees with the superblock is fatal', () {
      final root = _Log()
        ..superblock(blockSize: 8192)
        ..file(1, 'a', [1])
        ..commit();
      expect(() => LittleFsVolume.mount(_image({0: root.bytes}), blockSize: _blockSize),
          throwsA(isA<LittleFsException>()));
    });

    test('a CTZ pointer outside the image fails the read, not the mount', () {
      final root = _Log()
        ..superblock()
        ..name(1, LfsType.reg, 'big')
        ..ctz(1, 0x1234, 20000)
        ..commit();
      final volume = LittleFsVolume.mount(_image({0: root.bytes}), strict: true);
      expect(volume.entries.single.size, 20000);
      expect(() => volume.read('big'), throwsA(isA<LittleFsException>()));
    });

    test('a 2.0 superblock is accepted and a newer minor is only a warning', () {
      final v20 = _Log()
        ..superblock(version: LfsLayout.diskVersion20)
        ..file(1, 'a', [1])
        ..commit();
      expect(LittleFsVolume.mount(_image({0: v20.bytes}), strict: true).geometry.versionString, '2.0');
      final v22 = _Log()
        ..superblock(version: 0x00020002)
        ..file(1, 'a', [1])
        ..commit();
      final volume = LittleFsVolume.mount(_image({0: v22.bytes}));
      expect(volume.errors, [contains('newer than 2.1')]);
      expect(_paths(volume), ['a']);
      final v3 = _Log()
        ..superblock(version: 0x00030000)
        ..commit();
      expect(() => LittleFsVolume.mount(_image({0: v3.bytes})), throwsA(isA<LittleFsException>()));
    });
  });

  group('helpers', () {
    test('tag fields', () {
      final tag = LfsTag.make(LfsType.ctzStruct, 5, 8);
      expect(tag, 0x20201408);
      expect(LfsTag.type1(tag), LfsType.struct);
      expect(LfsTag.type3(tag), LfsType.ctzStruct);
      expect(LfsTag.chunk(tag), 0x02);
      expect(LfsTag.id(tag), 5);
      expect(LfsTag.size(tag), 8);
      expect(LfsTag.dsize(tag), 12);
      expect(LfsTag.isValid(tag), isTrue);
      expect(LfsTag.isValid(tag | 0x80000000), isFalse);
      expect(LfsTag.isDelete(LfsTag.make(LfsType.inlineStruct, 1, 0x3FF)), isTrue);
      expect(LfsTag.dsize(LfsTag.make(LfsType.inlineStruct, 1, 0x3FF)), 4);
      expect(LfsTag.dsize(0xFFFFFFFF), 4);
      expect(LfsTag.splice(LfsTag.make(LfsType.create, 0, 0)), 1);
      expect(LfsTag.splice(LfsTag.make(LfsType.delete, 0, 0)), -1);
      expect(LfsTag.type2(LfsTag.make(LfsType.fcrc, 0x3FF, 8)), isNot(LfsType.ccrc));
      expect(LfsTag.type2(LfsTag.make(LfsType.ccrc | 1, 0x3FF, 8)), LfsType.ccrc);
    });

    test('bit helpers', () {
      expect([1, 2, 3, 4, 5, 8, 9].map(lfsNpw2), [0, 1, 2, 2, 3, 3, 4]);
      expect([1, 2, 4, 6, 8, 12, 0x80000000].map(lfsCtz), [0, 1, 2, 1, 3, 2, 31]);
      expect([0, 1, 3, 0xFF, 0xFFFFFFFF].map(lfsPopc), [0, 1, 2, 8, 32]);
      expect(lfsSeqCompare(1, 0), greaterThan(0));
      expect(lfsSeqCompare(0, 0xFFFFFFFF), greaterThan(0));
      expect(lfsSeqCompare(0xFFFFFFFF, 0), lessThan(0));
      expect(lfsSeqCompare(7, 7), 0);
    });

    test('crc matches littlefs', () {
      // lfs_crc(0xffffffff, "123456789") is the standard CRC-32 check value
      // before the final inversion.
      expect(lfsCrc(0xFFFFFFFF, Uint8List.fromList(ascii.encode('123456789'))), 0xCBF43926 ^ 0xFFFFFFFF);
      expect(lfsCrc(0xFFFFFFFF, Uint8List(0)), 0xFFFFFFFF);
    });

    test('comparePaths orders depth-first', () {
      final paths = ['a-c', 'a/b', 'a', 'b', 'a/b/c', 'a/a'];
      paths.sort(comparePaths);
      expect(paths, ['a', 'a/a', 'a/b', 'a/b/c', 'a-c', 'b']);
    });
  });
}
