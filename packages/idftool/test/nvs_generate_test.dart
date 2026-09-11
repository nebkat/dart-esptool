import 'dart:convert';
import 'dart:typed_data';

import 'package:idftool/src/nvs/nvs.dart';
import 'package:test/test.dart';

import 'nvs_fixtures.dart';

/// CSV fixture → (size the python tool was given, version).
const generated = {
  'basic': (0x6000, NvsVersion.v2),
  'types': (0x6000, NvsVersion.v2),
  'bigblob': (0x8000, NvsVersion.v2),
  'readonly': (0x2000, NvsVersion.v2),
  'nearfull': (0x3000, NvsVersion.v2),
  'v1': (0x4000, NvsVersion.v1),
};

void main() {
  group('generate reads back like the python image', () {
    for (final MapEntry(key: name, value: (size, version)) in generated.entries) {
      test(name, () {
        final image = generateNvsImage(fixtureText('$name.csv'), size, version: version);
        expect(image.length, size);
        // For a read-only size the python tool emits only the pages it wrote, so its page
        // map is shorter; the Dart image is padded to the partition with erased flash.
        final pythonLength = fixtureBytes('$name.bin').length;
        expect(describeImage(image.sublist(0, pythonLength)), fixtureText('$name.pages.txt'));
        expect(nvsToCsv(parseNvs(image).entries), fixtureText('$name.extract.csv'));
      });
    }
  });

  group('generate is byte-identical to nvs_partition_gen', () {
    for (final MapEntry(key: name, value: (size, version)) in generated.entries) {
      test(name, () {
        final python = fixtureBytes('$name.bin');
        final dart = generateNvsImage(fixtureText('$name.csv'), size, version: version);
        // For a read-only size the python tool emits only the pages it wrote; the Dart
        // image is padded to the partition with erased flash.
        expect(dart.sublist(0, python.length), sameBytesAs(python));
        expect(dart.sublist(python.length), everyElement(0xFF));
      });
    }
  });

  group('python idftool reads Dart-generated images', () {
    for (final MapEntry(key: name, value: (size, version)) in generated.entries) {
      test(name, () {
        final image = generateNvsImage(fixtureText('$name.csv'), size, version: version);
        // Python's own rendering of the Dart image must agree with Dart's (and, page
        // padding aside, with what python rendered for its own image).
        expect(pythonDescribe(image), describeImage(image));
        expect(pythonDescribe(image.sublist(0, fixtureBytes('$name.bin').length)), fixtureText('$name.pages.txt'));
      }, skip: havePythonIdftool ? false : 'python idftool not on PATH');
    }
  });

  group('csv round trip', () {
    test('extract → generate → extract is stable', () {
      final csv = nvsToCsv(parseNvs(fixtureBytes('types.bin')).entries);
      final again = nvsToCsv(parseNvs(generateNvsImage(csv, 0x6000)).entries);
      expect(again, csv);
    });

    test('quotes only what python csv.writer would', () {
      final entries = [
        NvsEntry(namespace: 'ns', key: 'plain', type: NvsType.string, value: 'a b', size: 4, nsIndex: 1),
        NvsEntry(namespace: 'ns', key: 'comma', type: NvsType.string, value: 'a,b', size: 4, nsIndex: 1),
        NvsEntry(namespace: 'ns', key: 'quote', type: NvsType.string, value: 'say "hi"', size: 9, nsIndex: 1),
        NvsEntry(namespace: 'ns', key: 'nl', type: NvsType.string, value: 'a\nb', size: 4, nsIndex: 1),
      ];
      expect(nvsToCsv(entries), 'key,type,encoding,value\n'
          'ns,namespace,,\n'
          'comma,data,string,"a,b"\n'
          'nl,data,string,"a\nb"\n'
          'plain,data,string,a b\n'
          'quote,data,string,"say ""hi"""\n');
      final rows = parseNvsCsv(nvsToCsv(entries));
      expect(rows.map((r) => r.value), ['', 'a,b', 'a\nb', 'a b', 'say "hi"']);
    });
  });

  group('csv parsing', () {
    test('accepts columns in any order, comments and blank lines', () {
      final rows = parseNvsCsv('# leading comment\nvalue,encoding,type,key\n\n,,namespace,ns\n# mid\n5,u8,data,k\n');
      expect(rows.length, 2);
      expect(rows[0].type, 'namespace');
      expect(rows[0].key, 'ns');
      expect(rows[1].key, 'k');
      expect(rows[1].value, '5');
      expect(rows[1].line, 6);
    });

    test('rejects a header without the four columns', () {
      expect(() => parseNvsCsv('key,type,value\nns,namespace,\n'), throwsA(isA<NvsError>()));
      expect(() => parseNvsCsv(''), throwsA(isA<NvsError>()));
      expect(() => parseNvsCsv('key,type,encoding,value\nk,data\n'), throwsA(isA<NvsError>()));
      expect(() => parseNvsCsv('key,type,encoding,value\nk,data,string,"open\n'), throwsA(isA<NvsError>()));
    });
  });

  group('generate semantics', () {
    Uint8List gen(String rows, {int size = 0x4000, Uint8List? Function(String)? readFile}) =>
        generateNvsImage('key,type,encoding,value\n$rows', size, readFile: readFile);

    test('a re-opened namespace receives the rows that follow', () {
      // nvs_partition_gen files late_u8 under `second` (a bug); we follow the CSV.
      final image = parseNvs(gen(fixtureText('reopen.csv').split('\n').skip(1).join('\n'), size: 0x3000));
      expect(image.get('first', 'late_u8')!.value, 3);
      expect(image.get('second', 'late_u8'), isNull);
      expect(image.namespaces, {1: 'first', 2: 'second'}, reason: 'no duplicate namespace entry');
    });

    test('rejects data before a namespace, bad rows and long keys', () {
      expect(() => gen('k,data,u8,1\n'), throwsA(isA<NvsError>().having((e) => e.message, 'message', contains('before any namespace'))));
      expect(() => gen('ns,namespace,,\nk,thing,u8,1\n'), throwsA(isA<NvsError>()));
      expect(() => gen('ns,namespace,,\nk,data,float,1\n'), throwsA(isA<NvsError>()));
      expect(() => gen('ns,namespace,,\nk,data,u8,300\n'), throwsA(isA<NvsError>()));
      expect(() => gen('ns,namespace,,\nk,data,u8,abc\n'), throwsA(isA<NvsError>()));
      expect(() => gen('ns,namespace,,\nk,data,hex2bin,abc\n'), throwsA(isA<NvsError>()));
      expect(() => gen('ns,namespace,,\nk,data,base64,!!!\n'), throwsA(isA<NvsError>()));
      expect(() => gen('ns,namespace,,\n${'k' * 16},data,u8,1\n'), throwsA(isA<NvsError>()));
      expect(() => gen('${'n' * 16},namespace,,\n'), throwsA(isA<NvsError>()));
    });

    test('file rows need a reader', () {
      const rows = 'ns,namespace,,\nblob,file,binary,payload.bin\ntxt,file,string,hello.txt\nnum,file,u16,n.txt\n'
          'hx,file,hex2bin,h.txt\n';
      expect(() => gen(rows), throwsA(isA<NvsError>().having((e) => e.message, 'message', contains('file reader'))));
      final files = {
        'payload.bin': Uint8List.fromList([1, 2, 3]),
        'hello.txt': Uint8List.fromList(utf8.encode('hello')),
        'n.txt': Uint8List.fromList(utf8.encode('300\n')),
        'h.txt': Uint8List.fromList(utf8.encode('cafe\n')),
      };
      final image = parseNvs(gen(rows, readFile: (path) => files[path]));
      expect(image.get('ns', 'blob')!.value, [1, 2, 3]);
      expect(image.get('ns', 'txt')!.value, 'hello');
      expect(image.get('ns', 'num')!.value, 300);
      expect(image.get('ns', 'hx')!.value, [0xca, 0xfe]);
      expect(() => gen(rows, readFile: (_) => null), throwsA(isA<NvsError>()));
    });

    test('binary data rows and fill encodings', () {
      final image = parseNvs(gen('ns,namespace,,\nraw,data,binary,abc\nfill,data,blob_fill(6;0xAA),hi\n'
          'szfill,data,blob_sz_fill(4;0x00),ab\n'));
      expect(image.get('ns', 'raw')!.value, 'abc'.codeUnits);
      expect(image.get('ns', 'fill')!.value, [0x68, 0x69, 0xAA, 0xAA, 0xAA, 0xAA]);
      expect(image.get('ns', 'szfill')!.value, [2, 0, 0, 0, 0x61, 0x62, 0, 0]);
      expect(() => gen('ns,namespace,,\nfill,data,blob_fill(1;0xAA),hi\n'), throwsA(isA<NvsError>()));
    });

    test('an empty CSV still opens the first page, like the generator', () {
      final image = parseNvs(gen(''));
      expect(image.pages[0].pageState, NvsPageState.active);
      expect(image.entries, isEmpty);
    });

    test('size rules', () {
      expect(() => gen('', size: 0x800), throwsA(isA<NvsError>()));
      expect(() => gen('', size: 0x1800), throwsA(isA<NvsError>()));
      expect(generatorSize(0x1000), 0x1000);
      expect(generatorSize(0x2000), 0x2000);
      expect(generatorSize(0x3000), 0x2000);
      expect(generatorSize(0x6000), 0x5000);
      expect(() => generatorSize(0x800), throwsA(isA<NvsError>()));

      // 0x3000 keeps one page in reserve: 2 usable pages = 252 entries.
      final rows = StringBuffer('ns,namespace,,\n');
      for (var i = 0; i < 251; i++) {
        rows.write('k$i,data,u8,1\n');
      }
      final full = parseNvs(gen(rows.toString(), size: 0x3000));
      expect(full.pages[1].usedEntries, 126);
      expect(full.pages[2].isUninit, isTrue);
      expect(full.entries.length, 251);
      // A read-only 0x2000 partition has no reserve: both of its pages are usable.
      final ro = parseNvs(gen(rows.toString(), size: 0x2000));
      expect(ro.entries.length, 251);
      expect(ro.pages[1].pageState, NvsPageState.active);
      rows.write('one_more,data,u8,1\n');
      expect(() => gen(rows.toString(), size: 0x3000), throwsA(isA<NoSpaceError>()));
      expect(() => gen(rows.toString(), size: 0x2000), throwsA(isA<NoSpaceError>()));
      expect(parseNvs(gen(rows.toString(), size: 0x4000)).entries.length, 252);
    });

    test('string limits per version', () {
      // NVS takes a 4000-byte string (3999 chars + NUL); the generator itself cannot.
      final v2 = parseNvs(gen('ns,namespace,,\ns,data,string,${'x' * 3999}\n'));
      expect(v2.get('ns', 's')!.size, 4000);
      expect(v2.get('ns', 's')!.raw.single.span, 126);
      expect(() => gen('ns,namespace,,\ns,data,string,${'x' * 4000}\n'), throwsA(isA<NvsError>()));
      expect(() => generateNvsImage('key,type,encoding,value\nns,namespace,,\ns,data,string,${'x' * 1984}\n', 0x4000,
          version: NvsVersion.v1), throwsA(isA<NvsError>()));
      expect(() => generateNvsImage('key,type,encoding,value\nns,namespace,,\nb,data,hex2bin,${'00' * 1985}\n', 0x4000,
          version: NvsVersion.v1), throwsA(isA<NvsError>()));
    });

    test('a blob chunk header on the last entry of a page mirrors the generator', () {
      // 124 primitives + namespace = 125 entries; the blob's first chunk then gets a
      // header with no data on page 0, and the data continues on page 1.
      final rows = StringBuffer('ns,namespace,,\n');
      for (var i = 0; i < 124; i++) {
        rows.write('k$i,data,u8,1\n');
      }
      rows.write('b,data,hex2bin,${hex(blob(100, 1))}\n');
      final image = parseNvs(gen(rows.toString()), strict: true);
      final entry = image.get('ns', 'b')!;
      expect(entry.value, blob(100, 1));
      final chunks = entry.raw.where((r) => r.type == NvsType.blobData).toList();
      expect(chunks.map((c) => c.payload!.length), [0, 100]);
      expect(chunks.map((c) => c.page), [0, 1]);
    });
  });
}
