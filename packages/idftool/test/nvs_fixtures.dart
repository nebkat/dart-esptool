/// Shared helpers for the NVS tests: the python-generated fixtures under
/// `test/fixtures/nvs/` (see `generate.py` there) and the python `idftool`
/// oracle, when it is installed.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:idftool/src/nvs/nvs.dart';
import 'package:test/test.dart';

final fixtureDir = Directory('test/fixtures/nvs');

Uint8List fixtureBytes(String name) => File('${fixtureDir.path}/$name').readAsBytesSync();

String fixtureText(String name) => File('${fixtureDir.path}/$name').readAsStringSync();

/// The deterministic blob `generate.py` uses: byte `i` is `(i * 7 + seed) & 0xFF`.
Uint8List blob(int length, int seed) => Uint8List.fromList([for (var i = 0; i < length; i++) (i * 7 + seed) & 0xFF]);

String hex(List<int> bytes) => hexEncode(bytes);

/// What `idftool print-nvs --pages` prints after its first line.
String describeImage(Uint8List data) {
  final image = parseNvs(data);
  return '${formatNvsPages(image)}\n\n${formatNvsEntries(image.entries)}\n';
}

/// Whether the python `idftool` is on PATH; tests that need it as an oracle
/// skip otherwise.
final bool havePythonIdftool = () {
  try {
    return Process.runSync('idftool', ['--help']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}();

/// Run `idftool print-nvs --pages` over [data] through a temp file and return
/// everything after the first line, i.e. what the `.pages.txt` fixtures hold.
String pythonDescribe(Uint8List data) {
  final dir = Directory.systemTemp.createTempSync('nvs_test');
  try {
    final file = File('${dir.path}/image.bin')..writeAsBytesSync(data);
    final result = Process.runSync('idftool', ['print-nvs', '--pages', '-f', file.path]);
    expect(result.exitCode, 0, reason: 'python idftool failed: ${result.stdout}${result.stderr}');
    final out = result.stdout as String;
    return out.substring(out.indexOf('\n') + 1);
  } finally {
    dir.deleteSync(recursive: true);
  }
}

/// Index of the first byte where [a] and [b] differ, or -1.
int firstDifference(List<int> a, List<int> b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    if (a[i] != b[i]) return i;
  }
  return a.length == b.length ? -1 : n;
}

/// A matcher for byte-identical images that reports where they diverge.
Matcher sameBytesAs(List<int> expected) => predicate<List<int>>((actual) {
      final at = firstDifference(actual, expected);
      if (at < 0) return true;
      final page = at ~/ NvsLayout.pageSize, offset = at % NvsLayout.pageSize;
      final entry = offset >= NvsLayout.firstEntryOffset ? (offset - NvsLayout.firstEntryOffset) ~/ NvsLayout.entrySize : -1;
      fail('images differ at byte 0x${at.toRadixString(16)} (page $page, offset 0x${offset.toRadixString(16)}'
          '${entry >= 0 ? ', entry $entry' : ''}); lengths ${actual.length} vs ${expected.length}');
    }, 'byte-identical image');
