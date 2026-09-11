import 'dart:typed_data';

import 'package:idftool/src/nvs/nvs.dart';
import 'package:test/test.dart';

import 'nvs_fixtures.dart';

Matcher specError(String fragment) =>
    throwsA(isA<NvsSpecError>().having((e) => e.message, 'message', contains(fragment)));

void main() {
  group('set specs', () {
    test('namespace:key:type=value', () {
      final edit = parseNvsSetSpec('ns:key:u16=0x10');
      expect((edit.namespace, edit.key, edit.type, edit.value), ('ns', 'key', NvsType.u16, 16));
      expect(parseNvsSetSpec('ns:s:string=a=b').value, 'a=b', reason: 'only the first = splits');
      expect(parseNvsSetSpec('ns:b:blob=de ad\tbe ef').value, [0xde, 0xad, 0xbe, 0xef]);
      expect(parseNvsSetSpec('ns:n:i8=-5').value, -5);
      expect(parseNvsSetSpec('ns:n:u64=18446744073709551615').value, -1);
    });

    test('untyped specs keep the raw text', () {
      final edit = parseNvsSetSpec('ns:key=42');
      expect(edit.type, isNull);
      expect(edit.value, '42');
      expect(edit.isDelete, isFalse);
    });

    test('default namespace', () {
      expect(parseNvsSetSpec('key=1', defaultNamespace: 'd').namespace, 'd');
      expect(parseNvsSetSpec(':key:u8=1', defaultNamespace: 'd').namespace, 'd');
      expect(parseNvsSetSpec('other:key=1', defaultNamespace: 'd').namespace, 'other');
      expect(() => parseNvsSetSpec('key=1'), specError('does not name a namespace'));
      expect(() => parseNvsSetSpec(':key:u8=1'), specError('does not name a namespace'));
    });

    test('errors', () {
      expect(() => parseNvsSetSpec('ns:key'), specError("has no '='"));
      expect(() => parseNvsSetSpec('a:u8=1'), specError('ambiguous'));
      expect(() => parseNvsSetSpec('a:string=1', defaultNamespace: 'd'), specError('(or :a:string=1)'));
      expect(() => parseNvsSetSpec('a:b:c:d=1'), specError('too many'));
      expect(() => parseNvsSetSpec('ns:=1'), specError('does not name a key'));
      expect(() => parseNvsSetSpec('ns:k:float=1'),
          throwsA(isA<NvsError>().having((e) => e.message, 'message', contains("Unknown type 'float'"))));
      expect(() => parseNvsSetSpec('ns:k:u8=abc'),
          throwsA(isA<NvsError>().having((e) => e.message, 'message', contains('not a valid u8'))));
      // Like python's int(text, 0), the range is only checked when the entry is packed.
      expect(parseNvsSetSpec('ns:k:u8=300').value, 300);
      expect(() => applyNvsEdits(fixtureBytes('basic.bin'), [parseNvsSetSpec('ns:k:u8=300')]),
          throwsA(isA<NvsError>().having((e) => e.message, 'message', contains('does not fit in u8'))));
      expect(() => parseNvsSetSpec('ns:k:blob=abc'), specError('must be hex'));
    });

    test('@file values', () {
      final files = {
        'b.bin': Uint8List.fromList([9, 8]),
        's.txt': Uint8List.fromList('text here\n'.codeUnits),
        'n.txt': Uint8List.fromList(' 77 \n'.codeUnits),
      };
      Uint8List? read(String p) => files[p];
      expect(parseNvsSetSpec('ns:k:blob=@b.bin', readFile: read).value, [9, 8]);
      expect(parseNvsSetSpec('ns:k:string=@s.txt', readFile: read).value, 'text here\n');
      expect(parseNvsSetSpec('ns:k:u8=@n.txt', readFile: read).value, 77);
      expect(() => parseNvsSetSpec('ns:k:u8=@missing', readFile: read), specError('Cannot read value file'));
      expect(() => parseNvsSetSpec('ns:k:u8=@n.txt'), specError('no file access'));
    });
  });

  group('delete and get specs', () {
    test('namespace:key or key with a default', () {
      expect(parseNvsDeleteSpec('ns:k').isDelete, isTrue);
      expect(parseNvsDeleteSpec('ns:k').qualified, 'ns:k');
      expect(parseNvsDeleteSpec('k', defaultNamespace: 'd').namespace, 'd');
      expect(parseNvsDeleteSpec(':k', defaultNamespace: 'd').namespace, 'd');
      expect(() => parseNvsDeleteSpec('k'), specError('--delete'));
      expect(() => parseNvsDeleteSpec('a:b:c'), specError('should be namespace:key'));
      expect(parseNvsGetSpec('ns:k'), ('ns', 'k'));
      expect(parseNvsGetSpec('k', defaultNamespace: 'd'), ('d', 'k'));
      expect(() => parseNvsGetSpec('k'), specError('does not name a namespace'));
      expect(() => parseNvsGetSpec('a:b:c'), specError('should be namespace:key'));
    });
  });

  group('resolveUntypedNvsEdits', () {
    test('takes the type from the existing entry', () {
      final image = parseNvs(fixtureBytes('types.bin'));
      final resolved = resolveUntypedNvsEdits(image, [
        parseNvsSetSpec('nums:u8_max=7'),
        parseNvsSetSpec('bin:big=0a0b'),
        parseNvsSetSpec('text:long=new text'),
        parseNvsSetSpec('nums:new:u8=1'),
        parseNvsDeleteSpec('nums:u8_max'),
      ]);
      expect(resolved.map((e) => e.type), [NvsType.u8, NvsType.blob, NvsType.string, NvsType.u8, null]);
      expect(resolved[0].value, 7);
      expect(resolved[1].value, [0x0a, 0x0b]);
      expect(resolved[2].value, 'new text');
      expect(() => resolveUntypedNvsEdits(image, [parseNvsSetSpec('nums:missing=1')]),
          throwsA(isA<NvsError>().having((e) => e.message, 'message', contains('cannot be inferred'))));
    });
  });

  group('contiguousNvsWrites', () {
    test('groups adjacent dirty pages into runs', () {
      final image = Uint8List(6 * NvsLayout.pageSize);
      for (var p = 0; p < 6; p++) {
        image.fillRange(p * NvsLayout.pageSize, (p + 1) * NvsLayout.pageSize, p);
      }
      final writes = contiguousNvsWrites(0x9000, image, [0, 1, 3, 4, 5]);
      expect(writes.map((w) => w.$1), [0x9000, 0x9000 + 3 * NvsLayout.pageSize]);
      expect(writes.map((w) => w.$2.length), [2 * NvsLayout.pageSize, 3 * NvsLayout.pageSize]);
      expect(writes[0].$2.first, 0);
      expect(writes[0].$2.last, 1);
      expect(writes[1].$2.first, 3);
      expect(writes[1].$2.last, 5);
      expect(contiguousNvsWrites(0, image, []), isEmpty);
      expect(contiguousNvsWrites(0x1000, image, [2]).single.$1, 0x3000);
    });
  });

  group('describe', () {
    test('one line per change', () {
      const edit = NvsEdit.set('ns', 'k', type: NvsType.u8, value: 1);
      expect(describeNvsChange(const NvsChange(edit, NvsChangeAction.unchanged, type: NvsType.u8)),
          '  = ns:k unchanged');
      expect(describeNvsChange(const NvsChange(edit, NvsChangeAction.deleted, type: NvsType.u8)),
          '  - ns:k (u8) deleted');
      expect(describeNvsChange(const NvsChange(edit, NvsChangeAction.added, type: NvsType.u8)),
          '  + ns:k (u8) = 1');
      final before = NvsEntry(namespace: 'ns', key: 'k', type: NvsType.u8, value: 0, size: 1, nsIndex: 1);
      expect(describeNvsChange(NvsChange(edit, NvsChangeAction.set, before: before, type: NvsType.u8)),
          '  ~ ns:k (u8): 0 -> 1');
      expect(shortNvsValue(blob(100, 0)), '${hex(blob(24, 0))}…');
      expect(shortNvsValue(-1, type: NvsType.u64), '18446744073709551615');
    });
  });

  group('looksLikeNvsBinary', () {
    test('accepts python-generated and Dart-edited images', () {
      for (final name in ['basic', 'types', 'bigblob', 'readonly', 'v1', 'edit-compact']) {
        expect(looksLikeNvsBinary(fixtureBytes('$name.bin')), isTrue, reason: name);
      }
    });

    test('rejects everything else', () {
      expect(looksLikeNvsBinary(Uint8List(0)), isFalse);
      expect(looksLikeNvsBinary(Uint8List.fromList('key,type,encoding,value\n'.codeUnits)), isFalse);
      expect(looksLikeNvsBinary(Uint8List(0x1000)), isFalse, reason: 'zeros: bad version byte');
      final blank = Uint8List(0x2000)..fillRange(0, 0x2000, 0xFF);
      expect(looksLikeNvsBinary(blank), isFalse, reason: 'no initialised page');
      final truncated = fixtureBytes('basic.bin').sublist(0, 0x1800);
      expect(looksLikeNvsBinary(truncated), isFalse);
      final corrupt = Uint8List.fromList(fixtureBytes('basic.bin'));
      corrupt[4] ^= 1;
      expect(looksLikeNvsBinary(corrupt), isFalse, reason: 'header CRC');
      final badVersion = Uint8List.fromList(fixtureBytes('basic.bin'));
      badVersion[8] = 0xFD;
      expect(looksLikeNvsBinary(badVersion), isFalse);
      // Other partition images in the fixture directory are not NVS.
      expect(looksLikeNvsBinary(Uint8List.fromList(fixtureBytes('../partition-table.bin'))), isFalse);
    });
  });

  group('fitNvsBinary', () {
    test('pads with erased flash and refuses oversize images', () {
      final data = fixtureBytes('readonly.bin');
      final fitted = fitNvsBinary(data, 0x3000);
      expect(fitted.length, 0x3000);
      expect(fitted.sublist(0, data.length), data);
      expect(fitted.sublist(data.length), everyElement(0xFF));
      expect(identical(fitNvsBinary(data, data.length), data), isTrue);
      expect(() => fitNvsBinary(data, 0x800), throwsA(isA<NvsError>()));
    });
  });
}
