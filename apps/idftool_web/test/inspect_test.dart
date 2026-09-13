import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idftool/idftool.dart';
import 'package:idftool_web/util/inspect.dart';

void main() {
  final fixtures = Directory('../../packages/idftool/test/fixtures');
  final tableCsv = File('${fixtures.path}/partitions.csv').readAsBytesSync();
  final nvsCsv = File('${fixtures.path}/nvs.csv').readAsBytesSync();

  Future<Inspected> inspect(String name, Uint8List bytes) => inspectFile((name: name, bytes: bytes));

  test('partition table CSV', () async {
    final i = await inspect('partitions.csv', tableCsv);
    expect(i.kind, FileKind.partitionTable);
    expect(i.table, isNotNull);
    expect(i.report, contains('nvs'));
  });

  test('partition table binary', () async {
    final table = parsePartitionTableCsv(String.fromCharCodes(tableCsv), source: 'x');
    final i = await inspect('partitions.bin', table.toBinary());
    expect(i.kind, FileKind.partitionTable);
    expect(i.table!.length, table.length);
  });

  test('NVS CSV and generated image', () async {
    final csv = await inspect('nvs.csv', nvsCsv);
    expect(csv.kind, FileKind.nvsCsv);
    final image = generateNvsImage(String.fromCharCodes(nvsCsv), 0x6000);
    final i = await inspect('nvs.bin', image);
    expect(i.kind, FileKind.nvsImage);
    expect(i.nvs!.entries, isNotEmpty);
  });

  test('bundle and plain zip', () async {
    final table = parsePartitionTableCsv(String.fromCharCodes(tableCsv), source: 'x');
    final bundle = Archive()
      ..add(ArchiveFile.string('partition_table.csv', table.toCsv()))
      ..add(ArchiveFile.bytes('nvs.bin', generateNvsImage(String.fromCharCodes(nvsCsv), 0x6000)));
    final b = await inspect('bundle.zip', ZipEncoder().encodeBytes(bundle));
    expect(b.kind, FileKind.bundle);
    expect(b.summary, contains('nvs.bin'));

    final files = Archive()..add(ArchiveFile.string('hello.txt', 'hi'));
    final z = await inspect('files.zip', ZipEncoder().encodeBytes(files));
    expect(z.kind, FileKind.fileZip);
  });

  test('flash image with table at 0x8000', () async {
    final table = parsePartitionTableCsv(String.fromCharCodes(tableCsv), source: 'x');
    final image = Uint8List(0x10000)..fillRange(0, 0x10000, 0xFF);
    image.setRange(0x8000, 0x8000 + table.toBinary().length, table.toBinary());
    final i = await inspect('flash.bin', image);
    expect(i.kind, FileKind.flashImage);
    expect(i.bootloader, isNull);
  });

  test('unknown bytes', () async {
    final i = await inspect('junk.bin', Uint8List.fromList([1, 2, 3, 4, 5]));
    expect(i.kind, FileKind.unknown);
  });
}
