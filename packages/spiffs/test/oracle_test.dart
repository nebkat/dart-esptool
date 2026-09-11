@TestOn('vm')
library;

// Cross-checks against the python idftool CLI on trees built here rather than
// stored as fixtures. Skipped when the CLI is not on PATH.
import 'dart:io';
import 'dart:typed_data';

import 'package:spiffs/spiffs.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('spiffs_oracle_'));
  tearDown(() => temp.deleteSync(recursive: true));

  /// Build [files] with both tools and check python reads the Dart image back.
  void check(String name, Map<String, Uint8List> files, int size, {List<String> options = const []}) {
    test(name, () {
      final src = Directory('${temp.path}/src');
      writeTree(src, files);
      final config = configFromOptions(options);
      final dartImage = spiffsCreate(collectOrder(files), size, config: config);

      final pythonImage = File('${temp.path}/python.bin');
      idftool(['create-fs', src.path, '-o', pythonImage.path, '--size', '0x${size.toRadixString(16)}', '--type', 'spiffs', ...options]);
      expect(dartImage, pythonImage.readAsBytesSync(), reason: 'byte-identical images');

      final dartFile = File('${temp.path}/dart.bin')..writeAsBytesSync(dartImage);
      final listing = idftool(['print-fs', '-f', dartFile.path, '--type', 'spiffs', ...options]);
      for (final MapEntry(key: path, value: bytes) in files.entries) {
        expect(listing, contains(RegExp('\\| ${RegExp.escape(path)}\\s+\\|\\s+${bytes.length} \\|')));
      }
      final out = Directory('${temp.path}/out');
      idftool(['extract-fs', '-f', dartFile.path, '--type', 'spiffs', ...options, out.path]);
      expect(readTree(out), files);
    });
  }

  group('python idftool agrees', () {
    final sizes = [0, 1, 250, 251, 252, 1000, 25 * 251, 103 * 251 + 1, 40000];
    check('assorted sizes', {for (final (i, n) in sizes.indexed) 'f$i-$n.bin': pattern(n, i)}, 0x40000);
    check('nested and long names', {
      'a/b/c/d/e/f/g.bin': pattern(3000, 1),
      'a/b/x.txt': Uint8List.fromList('hello'.codeUnits),
      'abcdefghijklmnopqrstuvwxyz01234': pattern(10, 2),
    }, 0x10000);
    check('page 1024, block 8192, name 48, meta 8', {
      'one.bin': pattern(5000, 3),
      'two.bin': pattern(1019, 4),
      'a-fairly-long-name-that-needs-48-chars.bin': pattern(1, 5),
    }, 0x20000, options: ['--spiffs-page-size', '1024', '--spiffs-block-size', '8192', '--spiffs-obj-name-len', '48', '--spiffs-meta-len', '8']);
    check('no magic', {'a.bin': pattern(700, 6)}, 0x10000, options: ['--no-spiffs-use-magic']);
    check('fills every usable page', {
      // 16 blocks x 15 usable pages = 240; big.bin needs two index pages (103 + 97 entries)
      // and rest.bin one, leaving 237 data pages.
      'big.bin': pattern(200 * 251, 7),
      'rest.bin': pattern(37 * 251, 8),
    }, 0x10000);
  }, skip: haveIdftool ? false : 'python idftool not on PATH');
}
