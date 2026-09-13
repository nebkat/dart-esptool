import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:idftool/idftool.dart';
import 'package:test/test.dart';

void main() {
  final table = parsePartitionTableCsv('''
nvs,      data, nvs,     0x9000,  0x6000
otadata,  data, ota,     0xf000,  0x2000
factory,  app,  factory, 0x20000, 0x100000
ota_0,    app,  ota_0,   ,        0x100000
ota_1,    app,  ota_1,   ,        0x100000
''', source: 'test');

  Uint8List zip(Map<String, Object> entries) {
    final a = Archive();
    entries.forEach((k, v) => a.add(v is String ? ArchiveFile.string(k, v) : ArchiveFile.bytes(k, v as List<int>)));
    return ZipEncoder().encodeBytes(a);
  }

  test('reads every kind of entry by name', () {
    final b = readBundle(zip({
      'partition_table.csv': table.toCsv(),
      'bootloader.bin': [1, 2, 3],
      '@ota.bin': [4],
      'nvs.bin': [5, 6],
      'README.md': 'hi',
      'sub/ota_1.bin': [7],
    }));
    expect(b.table!.length, table.length);
    expect(b.tableFile, 'partition_table.csv');
    expect(b.bootloader, [1, 2, 3]);
    expect(b.otaApp, [4]);
    expect(b.factoryApp, isNull);
    expect(b.partitions.keys, ['nvs']);
    expect(b.ignored, ['README.md', 'sub/ota_1.bin']);
    expect(b.needsDeviceTable, isFalse);
  });

  test('name-based bundle needs a device table', () {
    expect(readBundle(zip({'ota_1.bin': [1]})).needsDeviceTable, isTrue);
  });

  test('both roles and unknown roles are errors', () {
    expect(() => readBundle(zip({'@factory.bin': [1], '@ota.bin': [2]})), throwsA(isA<IdfToolException>()));
    expect(() => readBundle(zip({'@boot.bin': [1]})), throwsA(isA<IdfToolException>()));
  });

  test('conflicts between roles and named writes', () {
    expect(bundleConflicts(table: table, namedPartitions: ['factory'], hasFactory: true, hasOta: false), hasLength(1));
    expect(bundleConflicts(table: table, namedPartitions: ['ota_1'], hasFactory: false, hasOta: true), hasLength(1));
    expect(bundleConflicts(table: table, namedPartitions: ['nvs', 'ota_1'], hasFactory: true, hasOta: false), isEmpty);
    expect(bundleConflicts(table: table, namedPartitions: const [], hasFactory: true, hasOta: true), hasLength(1));
  });

  test('round trip through encodeBundle', () {
    final b = readBundle(encodeBundle(table: table, factoryApp: Uint8List.fromList([9]), partitions: {'nvs': Uint8List.fromList([1])}));
    expect(b.factoryApp, [9]);
    expect(b.partitions['nvs'], [1]);
    expect(b.table, isNotNull);
    expect(b.manifest, isNull);
  });

  test('@ is a reserved name prefix', () {
    expect(() => parsePartitionTableCsv('@ota, app, factory, 0x20000, 0x100000', source: 'test'), throwsA(isA<PartitionTableException>()));
  });
}
