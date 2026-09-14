import 'dart:convert';
import 'dart:io';
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
      {'op': 'write-bootloader', 'file': 'bootloader.bin'},
      {'op': 'write', 'partition': 'storage', 'file': 'fs.bin'},
      {'op': 'erase', 'partition': 'nvs'},
      {'op': 'write-fs', 'partition': 'storage', 'file': 'fs.bin'},
      {'op': 'edit-fs', 'partition': 'storage', 'put': {'config.json': 'files/storage/config.json'}, 'delete': ['old.txt']},
      {'op': 'set-boot', 'partition': 'ota_1'},
      {'op': 'clear-boot'},
      {'op': 'set-nvs', 'partition': 'nvs', 'set': {'cfg:channel': 'string:stable'}, 'delete': ['cfg:old']},
    ])) as Map<String, dynamic>);
    expect(m.chip, EspChip.esp32s3);
    expect(m.steps.map((s) => s.op), [
      'write-bundle', 'factory', 'ota', 'write-table', 'write-bootloader', 'write', 'erase', 'write-fs', 'edit-fs', 'set-boot', 'clear-boot', 'set-nvs',
    ]);
    expect(m.isRecipe, isTrue);
    expect(m.steps.map((s) => s.describe()).join('\n'), contains('cfg:channel = string:stable, delete cfg:old'));
    expect((m.steps.last as SetNvsStep).edits.map((e) => e.qualified), ['cfg:channel', 'cfg:old']);
    expect(m.steps.expand((s) => s.files).toSet(), {'app.bin', 'partitions.csv', 'bootloader.bin', 'fs.bin', 'files/storage/config.json'});
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
    expect(() => FlashManifest.fromJson({'name': 'x', 'steps': [{'op': 'edit-fs', 'partition': 'storage'}]}),
        throwsA(predicate((e) => '$e'.contains('needs "put" and/or "delete"'))));
    expect(() => FlashManifest.fromJson({'name': 'x', 'steps': [{'op': 'frobnicate'}]}),
        throwsA(predicate((e) => '$e'.contains("unknown op 'frobnicate'"))));
    expect(() => FlashManifest.fromJson({'steps': [{'op': 'clear-boot'}], 'ops': [{'op': 'clear-boot'}]}),
        throwsA(predicate((e) => '$e'.contains('cannot both be present'))));
    expect(() => FlashManifest.fromJson({'name': ''}), throwsA(isA<IdfToolException>()));
  });

  test('extras manifest needs neither name nor steps', () {
    final m = FlashManifest.fromJson({'ops': [{'op': 'clear-boot'}]});
    expect(m.isRecipe, isFalse);
    expect(m.name, isNull);
    expect(m.ops.single, isA<ClearBootStep>());
    expect(FlashManifest.fromJson(m.toJson()).toJson(), m.toJson());
    expect(FlashManifest.fromJson({'name': 'n'}).toJson(), {'name': 'n'});
  });

  test('bundle checks referenced files exist', () {
    final ok = FlashBundle.fromZip(zipWith({
      'manifest.json': manifest([{'op': 'ota', 'file': 'app.bin'}]),
      'app.bin': Uint8List(16),
    }));
    expect(ok.name, 'Test');
    expect(ok.chip, EspChip.esp32s3);
    expect(ok.steps.single, isA<OtaStep>());
    expect(ok.file('app.bin').length, 16);

    expect(() => FlashBundle.fromZip(zipWith({'manifest.json': manifest([{'op': 'ota', 'file': 'missing.bin'}])})),
        throwsA(predicate((e) => '$e'.contains("file 'missing.bin' is not in the bundle"))));
    expect(() => FlashBundle.fromZip(zipWith({'manifest.json': manifest([{'op': 'write-bundle'}])})),
        throwsA(predicate((e) => '$e'.contains('no <partition>.bin files'))));
    expect(() => FlashBundle.fromZip(zipWith({'README.md': 'nothing'})),
        throwsA(predicate((e) => '$e'.contains('Nothing to flash'))));
    expect(() => FlashBundle.fromZip(Uint8List.fromList([1, 2, 3])), throwsA(isA<IdfToolException>()));
  });

  test('convention bundle resolves to steps in bundle order, then the extras', () {
    final b = FlashBundle.fromZip(
      zipWith({
        'nvs.bin': Uint8List(8),
        'manifest.json': jsonEncode({
          'description': 'd',
          'ops': [
            {'op': 'set-nvs', 'partition': 'nvs', 'set': {'cfg:channel': 'string:stable'}},
          ],
        }),
        'partition_table.csv': 'nvs, data, nvs, 0x9000, 0x6000\nfactory, app, factory, 0x20000, 0x100000\n',
        'bootloader.bin': Uint8List(4),
        '@factory.bin': Uint8List(4),
      }),
      source: 'ms5-v0.17.0.zip',
    );
    expect(b.name, 'ms5-v0.17.0');
    expect(b.description, 'd');
    expect(b.chip, isNull);
    expect(b.steps.map((s) => s.op), ['write-table', 'write-bootloader', 'factory', 'write', 'set-nvs']);
    expect((b.steps[3] as WritePartitionStep).file, 'nvs.bin');
    expect(b.contents.table, isNotNull);
  });

  test('a recipe manifest replaces the filename convention', () {
    final b = FlashBundle.fromZip(zipWith({
      'manifest.json': manifest([{'op': 'ota', 'file': 'app.bin'}, {'op': 'clear-boot'}]),
      'app.bin': Uint8List(16),
      'nvs.bin': Uint8List(8),
    }));
    expect(b.steps.map((s) => s.op), ['ota', 'clear-boot']);
  });

  test('the chip comes from the app image when the manifest is silent', () {
    final app = File('test/fixtures/app-v1.bin').readAsBytesSync();
    final b = FlashBundle.fromZip(zipWith({'@ota.bin': app}), source: 'x.zip');
    expect(b.chip, EspChip.esp32s3);
    expect(b.steps.single.describe(), contains('@ota.bin'));
  });
}
