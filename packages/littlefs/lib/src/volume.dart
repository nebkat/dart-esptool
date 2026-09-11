/// Mounting a littlefs image and reading its files.
///
/// The layout walked here is documented in `common.dart`. The reader follows
/// `lfs_dir_fetchmatch` for the log of a metadata pair, replays that log into
/// a table of entries instead of searching it backwards per query the way
/// `lfs_dir_getslice` does, and reads CTZ files with `lfs_ctz_find`.
///
/// The mount is deliberately forgiving: a corrupt pair, a dangling entry or a
/// bad superblock field is recorded in [LittleFsVolume.errors] and skipped,
/// because an image read off a live device can legitimately end in a commit
/// that lost power — the firmware ignores those too. Pass `strict: true` to
/// turn them into [LittleFsException]s. Damage that makes a file unreadable
/// always throws from [LittleFsVolume.read], since there is no partial answer.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'common.dart';

/// A superblock found by [sniffSuperblock].
typedef LfsSuperblockSniff = ({int offset, int blockSize, int blockCount, int nameMax});

/// Look for the superblock without parsing any log, mirroring python
/// idftool: the magic is at offset 8 of a block whose first tag is the
/// superblock name, and that block is either block 0 or — when block 0 is the
/// stale half of the pair — block 1, which is only reachable by guessing the
/// block size.
LfsSuperblockSniff? sniffSuperblock(Uint8List image) {
  final magic = ascii.encode(LfsLayout.magic);
  for (final offset in [0, ...LfsLayout.candidateBlockSizes]) {
    final base = offset + LfsLayout.superblockOffset;
    if (image.length < base + LfsLayout.superblockSize) continue;
    var matches = true;
    for (var i = 0; i < magic.length && matches; i++) {
      matches = image[offset + LfsLayout.magicOffset + i] == magic[i];
    }
    if (!matches) continue;

    // Make sure the magic sits in a superblock name tag: the first tag is
    // chained from 0xFFFFFFFF.
    final view = ByteData.sublistView(image);
    final nameTag = view.getUint32(offset + 4) ^ 0xFFFFFFFF;
    if (LfsTag.type3(nameTag) != LfsType.superblock || LfsTag.id(nameTag) != 0 || LfsTag.size(nameTag) != 8) {
      continue;
    }

    final blockSize = view.getUint32(base + 4, Endian.little);
    final blockCount = view.getUint32(base + 8, Endian.little);
    final nameMax = view.getUint32(base + 12, Endian.little);
    // A candidate offset that isn't this image's block size is a coincidence.
    if (offset != 0 && offset != blockSize) continue;
    if (blockSize >= LfsLayout.minBlockSize && blockSize <= image.length) {
      return (offset: offset, blockSize: blockSize, blockCount: blockCount, nameMax: nameMax);
    }
  }
  return null;
}

/// A mounted littlefs image: its geometry, the entries it holds and their
/// contents.
class LittleFsVolume {
  LittleFsVolume._(this._image, this.geometry, this._entries, this._files, this.errors);

  /// Mount [image], taking the geometry from the superblock.
  ///
  /// [blockSize] overrides the sniffed block size when the superblock is
  /// somewhere the sniff does not look. Problems are collected in [errors]
  /// unless [strict] is set, in which case they throw [LittleFsException];
  /// an image with no superblock throws either way.
  static LittleFsVolume mount(Uint8List image, {int? blockSize, bool strict = false}) =>
      _Mounter(image, blockSize: blockSize, strict: strict).mount();

  /// Whether [image] looks like a littlefs image: a cheap superblock sniff,
  /// no log parsing.
  static bool detect(Uint8List image) => sniffSuperblock(image) != null;

  final Uint8List _image;
  final List<LittleFsEntry> _entries;
  final Map<String, _FileRef> _files;

  final LittleFsGeometry geometry;

  /// Everything the mount skipped over.
  final List<String> errors;

  /// All files and directories, depth-first with siblings sorted by name.
  List<LittleFsEntry> get entries => List.unmodifiable(_entries);

  /// The contents of the file at [path] (as in [LittleFsEntry.path]).
  Uint8List read(String path) {
    final ref = _files[path];
    if (ref == null) {
      final normalized = path.startsWith('/') ? path.substring(1) : path;
      if (normalized != path && _files.containsKey(normalized)) return read(normalized);
      if (_entries.any((e) => e.path == normalized && e.isDir)) {
        throw LittleFsException("'$path' is a directory");
      }
      throw LittleFsException("No such file '$path'");
    }
    return switch (ref.structType) {
      LfsType.inlineStruct => Uint8List.fromList(ref.data),
      LfsType.ctzStruct => _CtzReader(_image, geometry).read(ByteData.sublistView(ref.data).getUint32(0, Endian.little),
          ByteData.sublistView(ref.data).getUint32(4, Endian.little), path),
      _ => throw LittleFsException("'$path' has an unreadable struct type 0x${ref.structType.toRadixString(16)}"),
    };
  }
}

/// Where a file's data lives: the newest STRUCT tag of its entry.
class _FileRef {
  _FileRef(this.structType, this.data);
  final int structType;
  final Uint8List data;
}

/// One id in a directory's entry table, holding the newest of each tag kind.
class _Slot {
  Uint8List? name;
  int nameType = 0;
  int? structType;
  Uint8List? structData;
}

/// A metadata pair after replaying the newest valid log: `lfs_mdir_t` plus
/// the entry table it describes.
class _Mdir {
  _Mdir({
    required this.pair,
    required this.rev,
    required this.slots,
    required this.tail,
    required this.split,
    required this.moveState,
  });

  /// The pair with the block that won first.
  final LfsPair pair;
  final int rev;
  final List<_Slot> slots;
  final LfsPair? tail;

  /// Whether [tail] is a hard tail — more of the same directory.
  final bool split;

  /// The newest MOVESTATE delta in this pair: `{tag, pair}`.
  final (int, int, int)? moveState;
}

/// Parses metadata pairs and walks the volume once; [LittleFsVolume] keeps
/// the results.
class _Mounter {
  _Mounter(this.image, {int? blockSize, required this.strict}) : _blockSize = blockSize;

  final Uint8List image;
  final bool strict;
  final errors = <String>[];

  int? _blockSize;
  int get blockSize => _blockSize!;
  late int blockCount;

  /// The pending move from the global state, applied to its pair on read.
  int _moveTag = 0;
  LfsPair _movePair = (0, 0);

  final _entries = <LittleFsEntry>[];
  final _files = <String, _FileRef>{};
  final _visitedDirPairs = <LfsPair>{};

  void _fail(String message) {
    if (strict) throw LittleFsException(message);
    errors.add(message);
  }

  LittleFsVolume mount() {
    if (image.isEmpty) throw LittleFsException('littlefs image is empty');
    if (_blockSize == null) {
      final sniff = sniffSuperblock(image);
      if (sniff == null) throw LittleFsException('Not a littlefs image (no superblock found)');
      _blockSize = sniff.blockSize;
    }
    if (blockSize < LfsLayout.minBlockSize) {
      throw LittleFsException('Block size $blockSize is below the ${LfsLayout.minBlockSize}-byte minimum');
    }
    if (image.length < 2 * blockSize) {
      throw LittleFsException('Image of ${image.length} bytes is too small for a $blockSize-byte block pair');
    }
    blockCount = image.length ~/ blockSize;

    final (root, geometry) = _findRoot();
    _visitedDirPairs.add(root.pair);
    _listDirectory(root, '');
    _entries.sort((a, b) => comparePaths(a.path, b.path));
    return LittleFsVolume._(image, geometry, _entries, _files, errors);
  }

  /// `lfs_mount`: follow the tail chain from pair {0, 1}, remembering the
  /// last pair with a superblock — that is the root — and XORing together
  /// every pair's MOVESTATE delta into the global state.
  (_Mdir, LittleFsGeometry) _findRoot() {
    _Mdir? root;
    LittleFsGeometry? geometry;
    var gstate = (0, 0, 0);
    final visited = <LfsPair>{};

    LfsPair? tail = (0, 1);
    while (tail != null && !lfsPairIsNull(tail)) {
      if (visited.any((p) => lfsPairSame(p, tail!))) {
        _fail('metadata pair ${lfsPairString(tail)} appears twice in the tail chain');
        break;
      }
      visited.add(tail);

      final dir = _fetch(tail);
      if (dir == null) {
        _fail('metadata pair ${lfsPairString(tail)}: no valid commit in either block');
        break;
      }

      final superblock = dir.slots.isEmpty ? null : dir.slots[0];
      if (superblock != null &&
          superblock.nameType == LfsType.superblock &&
          superblock.name != null &&
          latin1.decode(superblock.name!) == LfsLayout.magic) {
        root = dir;
        geometry = _readGeometry(dir, superblock) ?? geometry;
      }

      final delta = dir.moveState;
      if (delta != null) {
        gstate = (gstate.$1 ^ delta.$1, gstate.$2 ^ delta.$2, gstate.$3 ^ delta.$3);
      }
      tail = dir.tail;
    }

    if (root == null) {
      throw LittleFsException('No superblock found in the metadata pair chain from {0, 1}'
          '${errors.isEmpty ? '' : ' (${errors.last})'}');
    }
    if (geometry == null) {
      _fail('superblock in pair ${lfsPairString(root.pair)} has no inline struct; assuming the image size');
      geometry = LittleFsGeometry(
        blockSize: blockSize,
        blockCount: blockCount,
        nameMax: LfsLayout.defaultNameMax,
        fileMax: LfsLayout.defaultFileMax,
        attrMax: LfsLayout.defaultAttrMax,
        diskVersion: LfsLayout.diskVersion21,
      );
    }

    // A pending move means the entry exists in its destination and the source
    // must be read as if the DELETE had already been committed.
    _moveTag = gstate.$1;
    _movePair = (gstate.$2, gstate.$3);
    return (root, geometry);
  }

  LittleFsGeometry? _readGeometry(_Mdir dir, _Slot superblock) {
    final data = superblock.structData;
    if (superblock.structType != LfsType.inlineStruct || data == null || data.length < LfsLayout.superblockSize) {
      return null;
    }
    final view = ByteData.sublistView(data);
    final version = view.getUint32(0, Endian.little);
    final size = view.getUint32(4, Endian.little);
    final count = view.getUint32(8, Endian.little);
    final nameMax = view.getUint32(12, Endian.little);
    final fileMax = view.getUint32(16, Endian.little);
    final attrMax = view.getUint32(20, Endian.little);

    if (size != blockSize) {
      // Nothing parsed with the wrong block size can be trusted, so this is
      // fatal even when lenient.
      throw LittleFsException('superblock block size $size does not match the block size $blockSize used to parse '
          'the image');
    }
    final major = (version >>> 16) & 0xFFFF;
    final minor = version & 0xFFFF;
    if (major != 2) {
      throw LittleFsException('Unsupported littlefs disk version $major.$minor (only 2.x is supported)');
    }
    if (minor > 1) _fail('littlefs disk version $major.$minor is newer than 2.1; reading it as 2.1');

    if (count * blockSize > image.length) {
      _fail('superblock declares $count blocks but the image only holds ${image.length ~/ blockSize}');
    } else if (count > 0) {
      blockCount = count;
    }
    return LittleFsGeometry(
      blockSize: blockSize,
      blockCount: blockCount,
      nameMax: nameMax == 0 ? LfsLayout.defaultNameMax : nameMax,
      fileMax: fileMax == 0 ? LfsLayout.defaultFileMax : fileMax,
      attrMax: attrMax == 0 ? LfsLayout.defaultAttrMax : attrMax,
      diskVersion: version,
    );
  }

  // --------------------------------------------------------------------------
  // Metadata pairs
  // --------------------------------------------------------------------------

  bool _blockReadable(int block) => block < blockCount && (block + 1) * blockSize <= image.length;

  Uint8List _block(int block) => Uint8List.sublistView(image, block * blockSize, (block + 1) * blockSize);

  /// `lfs_dir_fetchmatch`: read the newer block of a pair, falling back to
  /// the other if it holds no valid commit.
  _Mdir? _fetch(LfsPair pair) {
    final blocks = [pair.$1, pair.$2];
    final revs = [0, 0];
    for (var i = 0; i < 2; i++) {
      if (_blockReadable(blocks[i])) revs[i] = ByteData.sublistView(_block(blocks[i])).getUint32(0, Endian.little);
    }
    var r = 0;
    for (var i = 0; i < 2; i++) {
      if (_blockReadable(blocks[i]) && lfsSeqCompare(revs[i], revs[(i + 1) % 2]) > 0) r = i;
    }
    for (var attempt = 0; attempt < 2; attempt++) {
      final first = blocks[(r + attempt) % 2];
      final second = blocks[(r + attempt + 1) % 2];
      if (!_blockReadable(first)) continue;
      final dir = _parseLog(first, (first, second), revs[(r + attempt) % 2]);
      if (dir != null) return dir;
    }
    return null;
  }

  /// Walk one block's log, replaying each commit that passes its CRC into
  /// the entry table. Returns null when the block holds no valid commit.
  _Mdir? _parseLog(int block, LfsPair pair, int rev) {
    final data = _block(block);
    final view = ByteData.sublistView(data);

    final slots = <_Slot>[];
    LfsPair? tail;
    var split = false;
    (int, int, int)? moveState;
    var committed = false;

    // Tags of the commit being scanned; only applied once its CRC checks out.
    final pending = <(int, int)>[];

    var crc = lfsCrc(0xFFFFFFFF, data, 0, 4);
    var off = 0;
    var ptag = 0xFFFFFFFF;
    while (true) {
      off += LfsTag.dsize(ptag);
      if (off + 4 > blockSize) break;
      crc = lfsCrc(crc, data, off, off + 4);
      final tag = view.getUint32(off) ^ ptag;

      // Erased space, or a commit that was never finished.
      if (!LfsTag.isValid(tag)) break;
      if (off + LfsTag.dsize(tag) > blockSize) break;
      ptag = tag;

      if (LfsTag.type2(tag) == LfsType.ccrc) {
        final stored = view.getUint32(off + 4, Endian.little);
        if (crc != stored) break;
        // The CRC tag's low chunk bit says which valid-bit state the next
        // commit must have, so that whatever is on disk after this commit
        // reads as invalid until it is really written.
        ptag ^= (LfsTag.chunk(tag) & 1) << 31;

        for (final (t, dataOff) in pending) {
          final result = _applyTag(slots, t, data, dataOff, tail, split, moveState);
          tail = result.$1;
          split = result.$2;
          moveState = result.$3;
        }
        pending.clear();
        committed = true;
        crc = 0xFFFFFFFF;
        continue;
      }

      crc = lfsCrc(crc, data, off + 4, off + LfsTag.dsize(tag));
      pending.add((tag, off + 4));
    }

    if (!committed) return null;
    return _Mdir(pair: pair, rev: rev, slots: slots, tail: tail, split: split, moveState: moveState);
  }

  /// Apply one committed tag to the entry table. Unknown types are skipped —
  /// their length is in the tag, so nothing else depends on knowing them.
  (LfsPair?, bool, (int, int, int)?) _applyTag(
      List<_Slot> slots, int tag, Uint8List block, int dataOff, LfsPair? tail, bool split, (int, int, int)? move) {
    final id = LfsTag.id(tag);
    final size = LfsTag.isDelete(tag) ? 0 : LfsTag.size(tag);
    final payload = Uint8List.sublistView(block, dataOff, dataOff + size);

    _Slot slot() {
      while (slots.length <= id) {
        slots.add(_Slot());
      }
      return slots[id];
    }

    switch (LfsTag.type1(tag)) {
      case LfsType.name:
        if (id == 0x3FF) break;
        final s = slot();
        if (LfsTag.isDelete(tag)) {
          s.name = null;
        } else {
          s.name = payload;
          s.nameType = LfsTag.type3(tag);
        }
      case LfsType.struct:
        if (id == 0x3FF) break;
        final s = slot();
        if (LfsTag.isDelete(tag)) {
          s.structType = null;
          s.structData = null;
        } else {
          s.structType = LfsTag.type3(tag);
          s.structData = payload;
        }
      case LfsType.splice:
        // CREATE opens a gap at id for the entry about to be written; DELETE
        // closes the one at id. Either shifts every later id.
        final shift = LfsTag.splice(tag);
        if (shift > 0) {
          while (slots.length < id) {
            slots.add(_Slot());
          }
          for (var i = 0; i < shift; i++) {
            slots.insert(id, _Slot());
          }
        } else if (shift < 0) {
          for (var i = 0; i < -shift && id < slots.length; i++) {
            slots.removeAt(id);
          }
        }
      case LfsType.tail:
        if (size >= 8) {
          final view = ByteData.sublistView(payload);
          tail = (view.getUint32(0, Endian.little), view.getUint32(4, Endian.little));
          split = LfsTag.chunk(tag) & 1 == 1;
        }
      case LfsType.globals:
        if (LfsTag.type3(tag) == LfsType.moveState) {
          if (LfsTag.isDelete(tag)) {
            move = null;
          } else if (size >= 12) {
            final view = ByteData.sublistView(payload);
            move = (
              view.getUint32(0, Endian.little),
              view.getUint32(4, Endian.little),
              view.getUint32(8, Endian.little),
            );
          }
        }
      default:
        // USERATTR, FCRC, FROM and anything newer: nothing a reader needs.
        break;
    }
    return (tail, split, move);
  }

  // --------------------------------------------------------------------------
  // Directories
  // --------------------------------------------------------------------------

  /// `lfs_dir_read` over every pair of a directory: ids in order, following
  /// hard tails.
  void _listDirectory(_Mdir first, String prefix) {
    var dir = first;
    while (true) {
      final slots = List.of(dir.slots);
      if (LfsTag.type1(_moveTag) != 0 && lfsPairSame(_movePair, dir.pair)) {
        // The source of a pending move reads as if already deleted
        // (`lfs_gstate_hasmovehere` in `lfs_dir_getslice`).
        final moveId = LfsTag.id(_moveTag);
        if (moveId < slots.length) slots.removeAt(moveId);
      }

      for (final slot in slots) {
        _addEntry(slot, dir, prefix);
      }

      final tail = dir.tail;
      if (!dir.split || tail == null || lfsPairIsNull(tail)) break;
      if (_visitedDirPairs.any((p) => lfsPairSame(p, tail))) {
        _fail("directory '${prefix.isEmpty ? '/' : prefix}': tail ${lfsPairString(tail)} was already visited");
        break;
      }
      _visitedDirPairs.add(tail);
      final next = _fetch(tail);
      if (next == null) {
        _fail("directory '${prefix.isEmpty ? '/' : prefix}': metadata pair ${lfsPairString(tail)} has no valid "
            'commit in either block');
        break;
      }
      dir = next;
    }
  }

  void _addEntry(_Slot slot, _Mdir dir, String prefix) {
    // An id without a name, or the superblock entry (type 0xFF is outside
    // the 0x780 mask `lfs_dir_getinfo` uses), is not a directory entry.
    final nameBytes = slot.name;
    if (nameBytes == null || slot.nameType & 0x80 != 0) return;

    final name = utf8.decode(nameBytes, allowMalformed: true);
    final where = 'pair ${lfsPairString(dir.pair)}';
    if (name.isEmpty || name.contains('/')) {
      _fail("$where: entry with an invalid name '$name'");
      return;
    }
    final path = '$prefix$name';
    final structType = slot.structType;
    final structData = slot.structData;
    if (structType == null || structData == null) {
      // littlefs skips these too (NOENT from lfs_dir_getinfo).
      _fail("$where: '$path' has a name but no struct");
      return;
    }
    if (_files.containsKey(path) || _entries.any((e) => e.path == path)) {
      _fail("$where: '$path' is listed twice");
      return;
    }

    switch (slot.nameType) {
      case LfsType.dir:
        if (structType != LfsType.dirStruct || structData.length < 8) {
          _fail("$where: directory '$path' has struct type 0x${structType.toRadixString(16)} instead of a pair");
          return;
        }
        _entries.add(LittleFsEntry(path: path, isDir: true, size: 0));
        final view = ByteData.sublistView(structData);
        final child = (view.getUint32(0, Endian.little), view.getUint32(4, Endian.little));
        if (_visitedDirPairs.any((p) => lfsPairSame(p, child))) {
          _fail("directory '$path': pair ${lfsPairString(child)} belongs to another directory too");
          return;
        }
        _visitedDirPairs.add(child);
        final childDir = _fetch(child);
        if (childDir == null) {
          _fail("directory '$path': metadata pair ${lfsPairString(child)} has no valid commit in either block");
          return;
        }
        _listDirectory(childDir, '$path/');
      case LfsType.reg:
        final int size;
        switch (structType) {
          case LfsType.inlineStruct:
            size = structData.length;
          case LfsType.ctzStruct:
            if (structData.length < 8) {
              _fail("$where: file '$path' has a truncated CTZ struct");
              return;
            }
            size = ByteData.sublistView(structData).getUint32(4, Endian.little);
          default:
            _fail("$where: file '$path' has unknown struct type 0x${structType.toRadixString(16)}");
            return;
        }
        _entries.add(LittleFsEntry(path: path, isDir: false, size: size));
        _files[path] = _FileRef(structType, structData);
      default:
        _fail("$where: '$path' has unknown file type 0x${slot.nameType.toRadixString(16)}");
    }
  }
}

/// Reads the blocks of a CTZ skip-list.
class _CtzReader {
  _CtzReader(this.image, this.geometry);
  final Uint8List image;
  final LittleFsGeometry geometry;

  int get blockSize => geometry.blockSize;

  Uint8List read(int head, int size, String path) {
    final out = Uint8List(size);
    var pos = 0;
    while (pos < size) {
      final (block, off) = _find(head, size, pos, path);
      if (block >= geometry.blockCount || (block + 1) * blockSize > image.length) {
        throw LittleFsException("'$path': CTZ block 0x${block.toRadixString(16)} is outside the image");
      }
      final n = (size - pos).clamp(0, blockSize - off);
      out.setRange(pos, pos + n, image, block * blockSize + off);
      pos += n;
    }
    return out;
  }

  /// `lfs_ctz_index`: which block of the list holds byte [pos], and where in
  /// that block it is, accounting for the pointers at the start of every
  /// block but the first.
  (int, int) _index(int pos) {
    final b = blockSize - 2 * 4;
    var i = pos ~/ b;
    if (i == 0) return (0, pos);
    i = (pos - 4 * (lfsPopc(i - 1) + 2)) ~/ b;
    return (i, pos - b * i - 4 * lfsPopc(i));
  }

  /// `lfs_ctz_find`: walk back from the head along the largest skip that
  /// doesn't overshoot.
  (int, int) _find(int head, int size, int pos, String path) {
    var (current, _) = _index(size - 1);
    final (target, off) = _index(pos);
    while (current > target) {
      final skip = [lfsNpw2(current - target + 1) - 1, lfsCtz(current)].reduce((a, b) => a < b ? a : b);
      if (head >= geometry.blockCount || (head + 1) * blockSize > image.length) {
        throw LittleFsException("'$path': CTZ block 0x${head.toRadixString(16)} is outside the image");
      }
      head = ByteData.sublistView(image).getUint32(head * blockSize + 4 * skip, Endian.little);
      current -= 1 << skip;
    }
    return (head, off);
  }
}

/// Order paths depth-first with siblings sorted by name — `a`, `a/b`, `a-c`
/// rather than the plain string order `a`, `a-c`, `a/b`.
int comparePaths(String a, String b) {
  final pa = a.split('/');
  final pb = b.split('/');
  for (var i = 0; i < pa.length && i < pb.length; i++) {
    final c = pa[i].compareTo(pb[i]);
    if (c != 0) return c;
  }
  return pa.length - pb.length;
}
