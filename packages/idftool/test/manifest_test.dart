import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:esptool/esptool.dart';
import 'package:idftool/idftool.dart';
import 'package:test/test.dart';

Uint8List zipWith(Map<String, Object> files) {
  final archive = Archive();
  files.forEach((name, content) {
    archive.add(content is String ? ArchiveFile.string(name, content) : ArchiveFile.bytes(name, content as Uint8List));
  });
  return ZipEncoder().encodeBytes(archive);
}

String manifest(List<Map<String, Object>> steps, {String? chip = 'esp32s3'}) =>
    jsonEncode({'name': 'Test', 'description': 'd', if (chip != null) 'chip': chip, 'steps': steps});

void main() {
  test('parses every op and describes it', () {
    final m = FlashManifest.fromJson(jsonDecode(manifest([
      {'op': 'write-bundle'},
      {'op': 'factory', 'file': 'app.bin'},
      {'op': 'ota', 'file': 'app.bin'},
      {'op': 'write-table', 'file': 'partitions.csv', 'force': true},
      {'op': 'write', 'partition': 'storage', 'file': 'fs.bin'},
      {'op': 'erase', 'partition': 'nvs'},
      {'op': 'write-fs', 'partition': 'storage', 'file': 'fs.bin'},
      {'op': 'set-boot', 'partition': 'ota_1'},
      {'op': 'clear-boot'},
      {'op': 'set-nvs', 'partition': 'nvs', 'set': {'cfg:channel': 'string:stable'}, 'delete': ['cfg:old']},
    ])) as Map<String, dynamic>);
    expect(m.chip, EspChip.esp32s3);
    expect(m.steps.map((s) => s.op), [
      'write-bundle', 'factory', 'ota', 'write-table', 'write', 'erase', 'write-fs', 'set-boot', 'clear-boot', 'set-nvs',
    ]);
    expect(m.steps.map((s) => s.describe()).join('\n'), contains('cfg:channel = string:stable, delete cfg:old'));
    expect((m.steps.last as SetNvsStep).edits.map((e) => e.qualified), ['cfg:channel', 'cfg:old']);
    expect(m.steps.expand((s) => s.files).toSet(), {'app.bin', 'partitions.csv', 'fs.bin'});
    // Round-trips through JSON.
    expect(FlashManifest.fromJson(m.toJson()).toJson(), m.toJson());
  });

  test('rejects bad manifests with the step number', () {
    expect(() => FlashManifest.fromJson({'name': 'x', 'steps': []}), throwsA(isA<IdfToolException>()));
    expect(() => FlashManifest.fromJson({'name': 'x', 'chip': 'esp99', 'steps': [{'op': 'clear-boot'}]}),
        throwsA(predicate((e) => '$e'.contains("unknown chip 'esp99'"))));
    expect(() => FlashManifest.fromJson({'name': 'x', 'steps': [{'op': 'clear-boot'}, {'op': 'ota'}]}),
        throwsA(predicate((e) => '$e'.contains('step 2') && '$e'.contains('"file" is required'))));
    expect(() => FlashManifest.fromJson({'name': 'x', 'steps': [{'op': 'set-nvs'}]}),
        throwsA(predicate((e) => '$e'.contains('needs "set" and/or "delete"'))));
    expect(() => FlashManifest.fromJson({'name': 'x', 'steps': [{'op': 'frobnicate'}]}),
        throwsA(predicate((e) => '$e'.contains("unknown op 'frobnicate'"))));
  });

  test('bundle checks referenced files exist', () {
    final ok = FlashBundle.fromZip(zipWith({
      'manifest.json': manifest([{'op': 'ota', 'file': 'app.bin'}]),
      'app.bin': Uint8List(16),
    }));
    expect(ok.manifest.name, 'Test');
    expect(ok.file('app.bin').length, 16);

    expect(() => FlashBundle.fromZip(zipWith({'manifest.json': manifest([{'op': 'ota', 'file': 'missing.bin'}])})),
        throwsA(predicate((e) => '$e'.contains("file 'missing.bin' is not in the bundle"))));
    expect(() => FlashBundle.fromZip(zipWith({'manifest.json': manifest([{'op': 'write-bundle'}])})),
        throwsA(predicate((e) => '$e'.contains('no <partition>.bin files'))));
    expect(() => FlashBundle.fromZip(zipWith({'app.bin': Uint8List(1)})),
        throwsA(predicate((e) => '$e'.contains('no manifest.json'))));
    expect(() => FlashBundle.fromZip(Uint8List.fromList([1, 2, 3])), throwsA(isA<IdfToolException>()));
  });
}
