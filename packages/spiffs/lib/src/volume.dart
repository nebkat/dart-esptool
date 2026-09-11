/// Reading a SPIFFS image back into files.
///
/// ESP-IDF ships a generator but no parser, so this walks the on-flash
/// structures directly (documented in `layout.dart`): every block's object
/// lookup table says which pages are in use, the pages' own headers say what
/// they are, and a file is put back together from its data pages.
///
/// Data pages are found the way the firmware finds them — through the page
/// table on the file's index pages — with a fallback to the data pages' own
/// span numbers when a table entry is missing or stale. A rewritten file leaves
/// its old pages flagged deleted, so only live pages ever take part; where a
/// crash left two live pages for the same span, the index table decides.
///
/// Damage is recorded in [SpiffsVolume.errors] and worked around unless
/// `strict` is set, in which case it throws [SpiffsException].
library;

import 'dart:convert';
import 'dart:typed_data';

import 'layout.dart';

/// One file found in an image. SPIFFS is flat: [path] may contain `/` but it
/// is just part of the name, so [isDir] is always false.
class SpiffsEntry {
  const SpiffsEntry({required this.path, required this.size, required this.objId});

  /// The name as stored, minus its leading `/`.
  final String path;
  final int size;

  /// The object id the file's pages are tagged with.
  final int objId;

  bool get isDir => false;

  @override
  String toString() => 'SpiffsEntry($path, $size bytes, obj 0x${objId.toRadixString(16)})';
}

/// A live page as found through a block's lookup table.
typedef _Page = ({int index, int objId, int spanIx});

/// A file's pages once resolved: [pages] holds the image page index of each
/// data span, or `null` where none could be found.
class _File {
  _File({required this.objId, required this.name, required this.size, required this.pages});
  final int objId;
  final String name;
  final int size;
  final List<int?> pages;

  String get path => name.replaceFirst(RegExp('^/+'), '');
}

/// A mounted SPIFFS image.
class SpiffsVolume {
  SpiffsVolume._(this.image, this.config, this._files, this.errors);

  final Uint8List image;
  final SpiffsConfig config;
  final List<_File> _files;

  /// Anything that did not parse cleanly. Empty unless the image is damaged.
  final List<String> errors;

  /// Parse [image], which must be a whole number of blocks of [config]'s size.
  ///
  /// Throws [SpiffsException] if the image cannot be SPIFFS at all — wrong
  /// size, or no files and no volume magic — and, with [strict], on any
  /// inconsistency that would otherwise just be listed in [errors].
  static SpiffsVolume mount(Uint8List image, {SpiffsConfig config = SpiffsConfig.defaults, bool strict = false}) {
    config.validate();
    if (image.isEmpty || image.length % config.blockSize != 0) {
      throw SpiffsException('SPIFFS image size 0x${image.length.toRadixString(16)} is not a whole number of '
          '0x${config.blockSize.toRadixString(16)}-byte blocks');
    }

    final errors = <String>[];
    final files = _Scanner(image, config, errors, strict).scan();
    if (files.isEmpty && config.useMagic && !detect(image, config: config)) {
      // An empty volume is legitimate, so only reject images with no SPIFFS structure at all.
      throw SpiffsException('Not a readable SPIFFS image');
    }
    files.sort((a, b) => _comparePaths(a.path, b.path));
    return SpiffsVolume._(image, config, files, errors);
  }

  /// Whether [image] carries the per-block volume magic.
  ///
  /// With no [config] the usual page sizes are tried against a 4 KiB block,
  /// with and without the block position folded in, like the python tool. An
  /// image built without `CONFIG_SPIFFS_USE_MAGIC` cannot be identified this
  /// way and has to be mounted on trust.
  static bool detect(Uint8List image, {SpiffsConfig? config}) {
    final blockSize = config?.blockSize ?? SpiffsConfig.defaults.blockSize;
    if (blockSize <= 0 || image.length < blockSize || image.length % blockSize != 0) return false;
    final blocks = image.length ~/ blockSize;
    final view = ByteData.sublistView(image);

    for (final pageSize in config != null ? [config.pageSize] : SpiffsConfig.candidatePageSizes) {
      if (pageSize <= 0 || pageSize & (pageSize - 1) != 0 || blockSize % pageSize != 0) continue;
      for (final useMagicLen in const [true, false]) {
        final candidate = SpiffsConfig(pageSize: pageSize, blockSize: blockSize, useMagicLen: useMagicLen);
        if (candidate.lookupPagesPerBlock >= candidate.pagesPerBlock) continue;
        var found = true;
        for (var block = 0; block < blocks && found; block++) {
          final stored = view.getUint16(block * blockSize + candidate.magicOffset, Endian.little);
          found = stored == candidate.magic(blocks, block);
        }
        if (found) return true;
      }
    }
    return false;
  }

  /// The files in the image, sorted by path.
  List<SpiffsEntry> get entries =>
      [for (final f in _files) SpiffsEntry(path: f.path, size: f.size, objId: f.objId)];

  /// The contents of the file at [path] (with or without a leading `/`).
  ///
  /// Throws [SpiffsException] if there is no such file or one of its data
  /// pages is missing.
  Uint8List read(String path) {
    final wanted = path.replaceFirst(RegExp('^/+'), '');
    final file = _files.where((f) => f.path == wanted).firstOrNull;
    if (file == null) throw SpiffsException("No file '$wanted' in the SPIFFS image");

    final contentLen = config.dataContentLen;
    final out = Uint8List(file.size);
    for (var span = 0; span < file.pages.length; span++) {
      final page = file.pages[span];
      if (page == null) throw SpiffsException("File '${file.path}' is missing data page $span");
      final start = page * config.pageSize + SpiffsConfig.dataHeaderLen;
      final offset = span * contentLen;
      final length = (file.size - offset).clamp(0, contentLen);
      out.setRange(offset, offset + length, image, start);
    }
    return out;
  }
}

/// Walks the lookup tables once and resolves every file's pages.
class _Scanner {
  _Scanner(this.image, this.config, this.errors, this.strict) : view = ByteData.sublistView(image);

  final Uint8List image;
  final ByteData view;
  final SpiffsConfig config;
  final List<String> errors;
  final bool strict;

  /// Live index pages by object id, then span.
  final Map<int, Map<int, int>> _indexPages = {};

  /// Live data pages by object id, then span. Where two live pages claim one
  /// span only the later survives here, so [_liveDataPages] keeps them all.
  final Map<int, Map<int, int>> _dataPages = {};
  final Set<int> _liveDataPages = {};

  void _fail(String message) {
    if (strict) throw SpiffsException(message);
    errors.add(message);
  }

  List<_File> scan() {
    for (var block = 0; block < image.length ~/ config.blockSize; block++) {
      _scanBlock(block);
    }

    final files = <_File>[];
    for (final MapEntry(key: objId, value: indexes) in _indexPages.entries) {
      final head = indexes[0];
      if (head == null) {
        _fail('object 0x${objId.toRadixString(16)}: index pages without a head (span 0) page');
        continue;
      }
      files.add(_resolve(objId, head, indexes));
    }
    for (final objId in _dataPages.keys) {
      if (!_indexPages.containsKey(objId)) {
        _fail('object 0x${objId.toRadixString(16)}: data pages without any index page');
      }
    }

    final names = <String>{};
    for (final file in files) {
      if (!names.add(file.path)) _fail("name '${file.path}' is used by more than one object");
    }
    return files;
  }

  /// Index every live page of [block] from its object lookup table.
  void _scanBlock(int block) {
    final base = block * config.blockSize;
    final firstPage = block * config.pagesPerBlock + config.lookupPagesPerBlock;
    for (var slot = 0; slot < config.usablePagesPerBlock; slot++) {
      // Lookup pages are contiguous, so the slots simply run on across them.
      final luObjId = view.getUint16(base + slot * SpiffsConfig.objIdLen, Endian.little);
      if (luObjId == SpiffsConfig.objIdFree || luObjId == SpiffsConfig.objIdDeleted) continue;

      final index = firstPage + slot;
      final page = _header(index);
      // The lookup table and the page header must agree; where they don't, the slot
      // holds something else (or the page was only half written).
      if (page.objId != luObjId) continue;
      final flags = image[index * config.pageSize + 4];
      if (!SpiffsFlags.isLive(flags)) continue;

      final isIndex = luObjId & SpiffsConfig.objIdIndexFlag != 0;
      if (isIndex != (flags & SpiffsFlags.index == 0)) {
        _fail('page $index: lookup says ${isIndex ? 'index' : 'data'} but the header flags disagree');
        continue;
      }
      final objId = luObjId & ~SpiffsConfig.objIdIndexFlag;
      if (!isIndex) _liveDataPages.add(index);
      final pages = (isIndex ? _indexPages : _dataPages).putIfAbsent(objId, () => {});
      if (pages.containsKey(page.spanIx)) {
        // Two live pages for one span: the firmware crashed between writing the new
        // one and deleting the old. Keep the later page, as the python reader does;
        // for data pages the index table gets the final say anyway.
        _fail('object 0x${objId.toRadixString(16)}: ${isIndex ? 'index' : 'data'} span ${page.spanIx} '
            'is live on both page ${pages[page.spanIx]} and page $index');
      }
      pages[page.spanIx] = index;
    }
  }

  _Page _header(int index) {
    final offset = index * config.pageSize;
    return (
      index: index,
      objId: view.getUint16(offset, Endian.little),
      spanIx: view.getUint16(offset + SpiffsConfig.objIdLen, Endian.little),
    );
  }

  /// Read the object header on [head] and find every data page of [objId].
  _File _resolve(int objId, int head, Map<int, int> indexes) {
    final base = head * config.pageSize + SpiffsConfig.dataHeaderLenAligned;
    var size = view.getUint32(base, Endian.little);
    final nameStart = base + 5;
    final nameBytes = Uint8List.sublistView(image, nameStart, nameStart + config.objNameLen);
    final nul = nameBytes.indexOf(0);
    final name = utf8.decode(nul < 0 ? nameBytes : Uint8List.sublistView(nameBytes, 0, nul), allowMalformed: true);
    final label = "'$name' (object 0x${objId.toRadixString(16)})";

    final spans = _dataPages[objId] ?? const {};
    if (size == SpiffsConfig.undefinedSize) {
      // The file was never closed, so its length was never written. Everything up to the
      // first gap in its data pages is the best that can be recovered.
      var count = 0;
      while (spans.containsKey(count)) {
        count++;
      }
      size = count * config.dataContentLen;
      _fail('$label: size was never written; recovering $size bytes from its data pages');
    }

    final pageCount = (size + config.dataContentLen - 1) ~/ config.dataContentLen;
    final pages = List<int?>.filled(pageCount, null);
    for (var span = 0; span < pageCount; span++) {
      final (indexSpan, slot) = config.tableSlot(span);
      final indexPage = indexes[indexSpan];
      int? page;
      if (indexPage == null) {
        if (slot == 0) _fail('$label: index page $indexSpan is missing');
      } else {
        final tableOffset = indexSpan == 0 ? config.headTableOffset : SpiffsConfig.dataHeaderLenAligned;
        final entry = view.getUint16(indexPage * config.pageSize + tableOffset + slot * SpiffsConfig.pageIxLen,
            Endian.little);
        if (entry != SpiffsConfig.pageIxFree) {
          if (_isLiveDataPage(entry, objId, span)) {
            page = entry;
          } else {
            _fail('$label: index entry for data page $span points at page $entry, which is not a live data page of it');
          }
        }
      }
      // Fall back to the page's own claim of where it belongs, as the python reader
      // does throughout.
      page ??= spans[span];
      if (page == null) {
        _fail('$label: data page $span is missing');
      }
      pages[span] = page;
    }
    return _File(objId: objId, name: name, size: size, pages: pages);
  }

  /// Whether page [index] is a live data page of [objId] at [span]: the lookup
  /// table listed it, and its header agrees.
  bool _isLiveDataPage(int index, int objId, int span) {
    if (!_liveDataPages.contains(index)) return false;
    final page = _header(index);
    return page.objId == objId && page.spanIx == span;
  }
}

/// Order paths by code point, like python sorts `str`, rather than by UTF-16 unit.
int _comparePaths(String a, String b) {
  final ai = a.runes.iterator, bi = b.runes.iterator;
  while (true) {
    final an = ai.moveNext(), bn = bi.moveNext();
    if (!an || !bn) return an == bn ? 0 : (an ? 1 : -1);
    if (ai.current != bi.current) return ai.current.compareTo(bi.current);
  }
}
