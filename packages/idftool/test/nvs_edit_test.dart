import 'dart:typed_data';

import 'package:idftool/src/nvs/nvs.dart';
import 'package:test/test.dart';

import 'nvs_fixtures.dart';

/// The python `set-nvs` runs in `generate.py`, replayed through the same spec
/// parser a CLI would use.
class EditCase {
  const EditCase(this.name, this.source, this.specs, {this.deletes = const [], this.rewrite = false});
  final String name;
  final String source;
  final List<String> specs;
  final List<String> deletes;
  final bool rewrite;
}

final editCases = [
  EditCase('edit-append', 'types', ['nums:new_u8:u8=200', 'other:hello:string=world', 'bin:more:blob=0102030405']),
  EditCase('edit-replace', 'types',
      ['nums:u8_max=1', 'text:long=changed', 'bin:big:blob=${hex(blob(700, 5))}', 'nums:i64_pos=1234567890123']),
  EditCase('edit-delete', 'types', [], deletes: ['nums:u8_max', 'text:long', 'bin:big', 'nums:missing']),
  EditCase('edit-bigblob', 'bigblob', ['blobs:first:blob=${hex(blob(5000, 6))}']),
  EditCase('edit-bigblob2', 'edit-bigblob', ['blobs:first:blob=${hex(blob(4100, 7))}'], deletes: ['blobs:second']),
  EditCase('edit-rewrite', 'types', ['nums:u8_max=2', 'zzz:k:u32=1'], deletes: ['text:short'], rewrite: true),
  EditCase('edit-compact', 'nearfull', ['f:k000=100', 'f:k001=101', 'f:k002=102', 'f:k003=103']),
  EditCase('edit-v1', 'v1', ['v1:blob:blob=${hex(blob(50, 9))}', 'v1:new:string=added']),
];

/// Parse specs the way `set-nvs` does and apply them.
(NvsEditResult, Uint8List) replay(EditCase c) {
  final data = fixtureBytes('${c.source}.bin');
  final edits = [
    ...c.specs.map((s) => parseNvsSetSpec(s)),
    ...c.deletes.map((s) => parseNvsDeleteSpec(s)),
  ];
  final resolved = resolveUntypedNvsEdits(parseNvs(data), edits);
  return (applyNvsEdits(data, resolved, forceRewrite: c.rewrite), data);
}

/// The lines `set-nvs` prints for a result, matching the `.log` fixtures.
String report(NvsEditResult result, int pageCount) {
  final lines = result.changes.map(describeNvsChange).toList();
  if (result.dirtyPages.isEmpty) {
    lines.add('Nothing changed.');
  } else if (result.compacted) {
    lines.add('No room left to append — the image was compacted and rewritten in full.');
  } else {
    final dirty = result.dirtyPages;
    lines.add('Appended in place; ${dirty.length} of $pageCount page${dirty.length == 1 ? '' : 's'} '
        'changed (${dirty.join(', ')}).');
  }
  return '${lines.join('\n')}\n';
}

void main() {
  group('edits match python set-nvs', () {
    for (final c in editCases) {
      test(c.name, () {
        final (result, data) = replay(c);
        expect(report(result, data.length ~/ NvsLayout.pageSize), fixtureText('${c.name}.log'));
        expect(describeImage(result.image), fixtureText('${c.name}.pages.txt'));
        expect(result.image, sameBytesAs(fixtureBytes('${c.name}.bin')));
      });
    }

    test('edit-nospace: even compaction cannot fit', () {
      final data = fixtureBytes('nearfull.bin');
      final edits = [for (var i = 0; i < 10; i++) NvsEdit.set('f', 'n$i', type: NvsType.u8, value: 1)];
      expect(() => applyNvsEdits(data, edits), throwsA(isA<NoSpaceError>()));
    });
  });

  group('python idftool reads Dart-edited images', () {
    for (final c in editCases) {
      test(c.name, () {
        final (result, _) = replay(c);
        expect(pythonDescribe(result.image), fixtureText('${c.name}.pages.txt'));
      }, skip: havePythonIdftool ? false : 'python idftool not on PATH');
    }

    test('images only Dart can write', () {
      // A page-filling string and a compaction that renumbers namespaces.
      final huge = applyNvsEdits(
          fixtureBytes('basic.bin'), [NvsEdit.set('storage', 'huge', type: NvsType.string, value: 'y' * 3999)]).image;
      expect(pythonDescribe(huge), describeImage(huge));
      final compacted = applyNvsEdits(fixtureBytes('edit-delete.bin'), [], forceRewrite: true).image;
      expect(pythonDescribe(compacted), describeImage(compacted));
    }, skip: havePythonIdftool ? false : 'python idftool not on PATH');
  });

  group('apply', () {
    test('touches only the pages it wrote and leaves the rest byte-identical', () {
      final data = fixtureBytes('bigblob.bin');
      final result = applyNvsEdits(data, [NvsEdit.set('blobs', 'tail', type: NvsType.u8, value: 10)]);
      expect(result.compacted, isFalse);
      expect(result.dirtyPages, [4]);
      for (var i = 0; i < data.length ~/ NvsLayout.pageSize; i++) {
        if (i == 4) continue;
        expect(result.image.sublist(i * 0x1000, (i + 1) * 0x1000), data.sublist(i * 0x1000, (i + 1) * 0x1000));
      }
      final image = parseNvs(result.image);
      expect(image.get('blobs', 'tail')!.value, 10);
      expect(image.pages[4].entryStates.where((s) => s == NvsEntryState.erased).length, 1);
    });

    test('an identical value is not rewritten', () {
      final data = fixtureBytes('types.bin');
      final result = applyNvsEdits(data, [
        NvsEdit.set('nums', 'u8_max', type: NvsType.u8, value: 255),
        NvsEdit.set('bin', 'big', type: NvsType.blob, value: blob(500, 2)),
        const NvsEdit.delete('nums', 'missing'),
      ]);
      expect(result.changes.map((c) => c.action), everyElement(NvsChangeAction.unchanged));
      expect(result.dirtyPages, isEmpty);
      expect(result.image, sameBytesAs(data));
    });

    test('a type change replaces the entry', () {
      final data = fixtureBytes('types.bin');
      final result = applyNvsEdits(data, [NvsEdit.set('nums', 'u8_max', type: NvsType.string, value: 'now text')]);
      expect(result.changes.single.action, NvsChangeAction.set);
      final image = parseNvs(result.image);
      expect(image.get('nums', 'u8_max')!.type, NvsType.string);
      expect(image.get('nums', 'u8_max')!.value, 'now text');
    });

    test('a set followed by a delete of the same key in one batch leaves nothing behind', () {
      final data = fixtureBytes('basic.bin');
      final result = applyNvsEdits(data, [
        NvsEdit.set('storage', 'temp', type: NvsType.string, value: 'gone soon'),
        const NvsEdit.delete('storage', 'temp'),
        NvsEdit.set('storage', 'counter', type: NvsType.u16, value: 8),
        NvsEdit.set('storage', 'counter', type: NvsType.u16, value: 9),
      ]);
      expect(result.changes.map((c) => c.action),
          [NvsChangeAction.added, NvsChangeAction.deleted, NvsChangeAction.set, NvsChangeAction.set]);
      final image = parseNvs(result.image, strict: true);
      expect(image.get('storage', 'temp'), isNull);
      expect(image.get('storage', 'counter')!.value, 9);
      expect(image.pages[0].entryStates.where((s) => s == NvsEntryState.written).length, 4 + 1);
    });

    test('an untyped edit of a missing key is an error', () {
      final data = fixtureBytes('basic.bin');
      expect(() => applyNvsEdits(data, [const NvsEdit('storage', 'nope', value: '1')]),
          throwsA(isA<NvsError>().having((e) => e.message, 'message', contains('no type to infer'))));
      expect(() => applyNvsEdits(data, [NvsEdit.set('storage', 'x' * 16, type: NvsType.u8, value: 1)]),
          throwsA(isA<NvsError>().having((e) => e.message, 'message', contains('15-character'))));
      expect(() => applyNvsEdits(data, [NvsEdit.set('storage', 'x', type: NvsType.u8, value: 'text')]),
          throwsA(isA<NvsError>()));
    });

    test('forceRewrite compacts and renumbers namespaces in index order', () {
      final data = fixtureBytes('edit-delete.bin');
      final result = applyNvsEdits(data, [], forceRewrite: true);
      expect(result.compacted, isTrue);
      expect(result.dirtyPages, [0, 1, 2, 3, 4, 5]);
      final before = parseNvs(data), after = parseNvs(result.image, strict: true);
      expect(nvsToCsv(after.entries), nvsToCsv(before.entries));
      expect(after.pages[0].entryStates.where((s) => s == NvsEntryState.erased), isEmpty);
      expect(after.namespaces, {1: 'nums', 2: 'text', 3: 'bin'});
    });

    test('a new namespace gets the next index', () {
      final data = fixtureBytes('types.bin');
      final result = applyNvsEdits(data, [NvsEdit.set('fresh', 'k', type: NvsType.i32, value: -7)]);
      final image = parseNvs(result.image);
      expect(image.namespaces[4], 'fresh');
      expect(image.get('fresh', 'k')!.value, -7);
    });

    test('a page-filling string goes through the edit path', () {
      final data = fixtureBytes('basic.bin');
      final result = applyNvsEdits(data, [NvsEdit.set('storage', 'huge', type: NvsType.string, value: 'y' * 3999)]);
      final image = parseNvs(result.image, strict: true);
      expect(image.get('storage', 'huge')!.raw.single.span, 126);
      expect(image.get('storage', 'huge')!.page, 1);
      expect(() => applyNvsEdits(data, [NvsEdit.set('storage', 'huge', type: NvsType.string, value: 'y' * 4000)]),
          throwsA(isA<NvsError>()));
    });

    test('compaction falls back when a blob no longer fits in the free pages', () {
      final data = fixtureBytes('edit-bigblob2.bin'); // one free page, lots of erased entries
      final result = applyNvsEdits(data, [NvsEdit.set('blobs', 'first', type: NvsType.blob, value: blob(4200, 1))]);
      expect(result.compacted, isTrue);
      final image = parseNvs(result.image, strict: true);
      expect(image.get('blobs', 'first')!.value, blob(4200, 1));
      expect(image.get('blobs', 'maxstr')!.size, 3968);
      expect(image.get('blobs', 'tail')!.value, 9);
    });
  });

  group('writer', () {
    test('encoders produce the bytes of the python fixture', () {
      final data = fixtureBytes('types.bin');
      final image = parseNvs(data);
      Uint8List at(RawEntry raw, int entries) => Uint8List.sublistView(data, raw.offset, raw.offset + entries * 32);

      final ns = image.pages[0].entries.first;
      expect(encodePrimitive(0, 'nums', NvsType.u8, 1), at(ns, 1));
      final u64 = image.get('nums', 'u64_max')!.raw.single;
      expect(encodePrimitive(1, 'u64_max', NvsType.u64, -1), at(u64, 1));
      final long = image.get('text', 'long')!.raw.single;
      final payload = [...('The quick brown fox jumps over the lazy dog. ' * 3).codeUnits, 0];
      expect(encodeVarlen(2, 'long', NvsType.string, payload), at(long, long.span));
      final big = image.get('bin', 'big')!;
      final chunk = big.raw.last;
      expect(encodeVarlen(3, 'big', NvsType.blobData, blob(500, 2), chunkIndex: 0), at(chunk, chunk.span));
      expect(encodeBlobIndex(3, 'big', 500, 1, 0), at(big.raw.first, 1));
    });

    test('blank writer refuses bad sizes', () {
      expect(() => NvsWriter.blank(0x800), throwsA(isA<NvsError>()));
      expect(() => NvsWriter.blank(0x1234), throwsA(isA<NvsError>()));
      expect(NvsWriter.blank(0x2000).usable, 2);
      expect(NvsWriter.blank(0x3000).usable, 2);
      expect(NvsWriter.blank(0x8000).usable, 7);
    });
  });
}
