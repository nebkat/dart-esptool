// Expectations in this file were generated with the Python original
// (`esp_idf_defs.partitions`), which is the reference implementation.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:idftool/src/otadata.dart';
import 'package:idftool/src/partition_table.dart';
import 'package:idftool/src/partition_table_files.dart';
import 'package:test/test.dart';

Uint8List fixtureBytes(String name) => File('test/fixtures/$name').readAsBytesSync();
String fixtureText(String name) => File('test/fixtures/$name').readAsStringSync();

Uint8List fromHex(String hex) =>
    Uint8List.fromList([for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)]);

String toHex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Matcher throwsTableError(String message) =>
    throwsA(isA<PartitionTableException>().having((e) => e.message, 'message', message));

Matcher throwsValidationError(String message) =>
    throwsA(isA<PartitionValidationException>().having((e) => e.message, 'message', message));

const fixtureCsv = '# ESP-IDF Partition Table\n'
    '# Name, Type, SubType, Offset, Size, Flags\n'
    'nvs,data,nvs,0x9000,24K,\n'
    'otadata,data,ota,0xf000,8K,\n'
    'phy_init,data,phy,0x11000,4K,\n'
    'factory,app,factory,0x20000,192K,\n'
    'ota_0,app,ota_0,0x50000,192K,\n'
    'ota_1,app,ota_1,0x80000,192K,\n'
    'storage,data,spiffs,0xb0000,64K,\n';

const fixtureCsvSimple = '# ESP-IDF Partition Table\n'
    '# Name, Type, SubType, Offset, Size, Flags\n'
    'nvs,1,2,0x9000,0x6000,\n'
    'otadata,1,0,0xf000,0x2000,\n'
    'phy_init,1,1,0x11000,0x1000,\n'
    'factory,0,0,0x20000,0x30000,\n'
    'ota_0,0,16,0x50000,0x30000,\n'
    'ota_1,0,17,0x80000,0x30000,\n'
    'storage,1,130,0xb0000,0x10000,\n';

const fixtureFormatted = '| Name     | Type | Subtype | Offset  | Size |\n'
    '|----------|------|---------|---------|------|\n'
    '| nvs      | data | nvs     | 0x9000  | 24K  |\n'
    '| otadata  | data | ota     | 0xf000  | 8K   |\n'
    '| phy_init | data | phy     | 0x11000 | 4K   |\n'
    '| factory  | app  | factory | 0x20000 | 192K |\n'
    '| ota_0    | app  | ota_0   | 0x50000 | 192K |\n'
    '| ota_1    | app  | ota_1   | 0x80000 | 192K |\n'
    '| storage  | data | spiffs  | 0xb0000 | 64K  |';

void main() {
  group('fixtures', () {
    late PartitionTable fromCsv;
    late PartitionTable fromBinary;
    setUp(() {
      fromCsv = PartitionTable.fromCsv(fixtureText('partitions.csv'));
      fromBinary = PartitionTable.fromBinary(fixtureBytes('partition-table.bin'));
    });

    test('CSV fixture encodes byte-identically to the ESP-IDF build output', () {
      expect(fromCsv.toBinary(), equals(fixtureBytes('partition-table.bin')));
    });

    test('binary fixture decodes to the expected entries', () {
      expect(fromBinary.map((p) => p.name), ['nvs', 'otadata', 'phy_init', 'factory', 'ota_0', 'ota_1', 'storage']);
      final ota1 = fromBinary.findByName('ota_1')!;
      expect(ota1.type, PartitionType.app.value);
      expect(ota1.subtype, AppSubtype.ota1.value);
      expect(ota1.offset, 0x80000);
      expect(ota1.size, 0x30000);
      expect(ota1.encrypted, isFalse);
      expect(ota1.readonly, isFalse);
      expect(ota1.isOtaApp, isTrue);
      expect(fromBinary.findByName('otadata')!.isOtadata, isTrue);
      expect(fromBinary.otadataPartition, same(fromBinary[1]));
      expect(fromBinary.otaAppCount, 2);
    });

    test('binary fixture → toCsv matches python to_csv()', () {
      expect(fromBinary.toCsv(), fixtureCsv);
      expect(fromBinary.toCsv(simple: true), fixtureCsvSimple);
    });

    test('round trips', () {
      expect(fromBinary, equals(fromCsv));
      expect(PartitionTable.fromCsv(fromCsv.toCsv()), equals(fromCsv));
      expect(PartitionTable.fromCsv(fromCsv.toCsv(simple: true)), equals(fromCsv));
      expect(PartitionTable.fromBinary(fromBinary.toBinary()), equals(fromBinary));
      expect(PartitionTable.fromBinary(fromBinary.toBinary(md5sum: false)), equals(fromBinary));
    });

    test('parse auto-detects the format', () {
      final bin = PartitionTable.parse(fixtureBytes('partition-table.bin'));
      expect(bin.isBinary, isTrue);
      expect(bin.table, equals(fromCsv));
      final csv = PartitionTable.parse(fixtureBytes('partitions.csv'));
      expect(csv.isBinary, isFalse);
      expect(csv.table, equals(fromCsv));
    });

    test('verify, flashSize, verifySizeFits', () {
      fromCsv.verify(partitionTableOffset: 0x8000);
      expect(fromCsv.flashSize, 786432);
      fromCsv.verifySizeFits(0x100000);
      expect(
          () => fromCsv.verifySizeFits(0x80000),
          throwsTableError('Partitions tables occupies 0.8MB of flash (786432 bytes) which does not fit in '
              'available flash size 0MB.'));
    });

    test('format', () {
      expect(fromCsv.format(), fixtureFormatted);
    });

    test('findByType accepts keywords, numbers or enums', () {
      expect(fromCsv.findByType('app', 'ota_0').single.name, 'ota_0');
      expect(fromCsv.findByType(0, 0x11).single.name, 'ota_1');
      expect(fromCsv.findByType(PartitionType.data, DataSubtype.nvs).single.name, 'nvs');
      expect(fromCsv.findByType(PartitionType.app, AppSubtype.factory).single.name, 'factory');
      expect(() => fromCsv.findByType(1.5, 0), throwsArgumentError);
      expect(fromCsv.findByType('data', 'spiffs').single.name, 'storage');
      expect(fromCsv.findByType('data', 'fat'), isEmpty);
      expect(fromCsv.findByName('nope'), isNull);
    });
  });

  group('bootloader-template.csv', () {
    const csvWithOffsets = '# ESP-IDF Partition Table\n'
        '# Name, Type, SubType, Offset, Size, Flags\n'
        'bootloader,bootloader,primary,0x0,32K,\n'
        'part_table,partition_table,primary,0x8000,4K,\n'
        'nvs,data,nvs,0x9000,24K,\n'
        'factory,app,factory,0x20000,1M,\n';
    const binaryPrefix = 'aa5002000000000000800000626f6f746c6f6164657200000000000000000000'
        'aa5003000080000000100000706172745f7461626c6500000000000000000000'
        'aa50010200900000006000006e76730000000000000000000000000000000000'
        'aa5000000000020000001000666163746f727900000000000000000000000000'
        'ebebffffffffffffffffffffffffffffbbfc50988db913ecd4fa74fd9c60c3be';

    test('parses with an explicit primary bootloader offset', () {
      final table = PartitionTable.fromCsv(fixtureText('bootloader-template.csv'), primaryBootloaderOffset: 0x0);
      expect(table.toCsv(), csvWithOffsets);
      expect(table[0].isPrimaryBootloader, isTrue);
      expect(table[0].size, 0x8000, reason: 'bootloader spans up to the table');
      expect(table[1].isPrimaryPartitionTable, isTrue);
      expect(table[1].size, PartitionTable.size);
      final binary = table.toBinary();
      expect(toHex(binary.sublist(0, 0xa0)), binaryPrefix);
      expect(binary.sublist(0xa0).every((b) => b == 0xFF), isTrue);
      table.verify(partitionTableOffset: 0x8000);
      expect(
          table.format(),
          '| Name       | Type            | Subtype | Offset  | Size |\n'
          '|------------|-----------------|---------|---------|------|\n'
          '| bootloader | bootloader      | primary | 0x0     | 32K  |\n'
          '| part_table | partition_table | primary | 0x8000  | 4K   |\n'
          '| nvs        | data            | nvs     | 0x9000  | 24K  |\n'
          '| factory    | app             | factory | 0x20000 | 1M   |');
    });

    test('fails without a bootloader offset', () {
      expect(() => PartitionTable.fromCsv(fixtureText('bootloader-template.csv')),
          throwsTableError('Error at line 4: Primary bootloader offset is not provided'));
    });

    test('parsePartitionTableCsv explains the missing offset', () {
      expect(
          () => parsePartitionTableCsv(fixtureText('bootloader-template.csv'), source: "file 'tpl.csv'"),
          throwsTableError("The primary bootloader entry in file 'tpl.csv' (line 4) has no offset. Add the offset to "
              'the CSV, or pass --primary-bootloader-offset (an address or a chip name, e.g. esp32s3).'));
      expect(
          () => parsePartitionTableCsv('rb,bootloader,recovery,,\n', source: 'bundle', primaryBootloaderOffset: 0),
          throwsTableError('The recovery bootloader entry in bundle (line 1) has no offset. Add the offset to the '
              'CSV, or pass --recovery-bootloader-offset.'));
    });

    test('parsePartitionTableCsv recovers offsets written into the CSV', () {
      final table = parsePartitionTableCsv(csvWithOffsets, source: 'dump');
      expect(table.toCsv(), csvWithOffsets);
      // Explicit offsets win over the CSV.
      final moved = parsePartitionTableCsv(csvWithOffsets, source: 'dump', primaryBootloaderOffset: 0x1000);
      expect(moved[0].offset, 0x1000);
      expect(moved[0].size, 0x7000);
    });

    test('extractCsvBootloaderOffsets', () {
      expect(extractCsvBootloaderOffsets(fixtureText('bootloader-template.csv')), (primary: null, recovery: null));
      expect(
          extractCsvBootloaderOffsets('bootloader,bootloader,primary,0x1000,0x7000\n'
              'rb,bootloader,recovery,0x200000,0x7000\n'
              '# x,bootloader,primary,0x5,\n'
              'bl2,bootloader,primary,0x2000,\n'
              'z,bootloader,recovery,zz,'),
          (primary: 4096, recovery: 2097152));
    });

    test('bootloader/partition_table rows of other subtypes', () {
      expect(() => PartitionTable.fromCsv('a,bootloader,ota,0x9000,0x6000\n'),
          throwsTableError('Error at line 1: Primary bootloader offset is not provided'));
      expect(PartitionTable.fromCsv('a,bootloader,ota,0x9000,0x6000\n', primaryBootloaderOffset: 0x1000).toCsv(),
          endsWith('a,bootloader,ota,0x9000,28K,\n'));
      expect(() => PartitionTable.fromCsv('a,bootloader,recovery,,0x6000\n', primaryBootloaderOffset: 0x1000),
          throwsTableError('Error at line 1: Recovery bootloader offset is not provided'));
      expect(
          PartitionTable.fromCsv('a,bootloader,recovery,,0x6000\n',
                  primaryBootloaderOffset: 0x1000, recoveryBootloaderOffset: 0x200000)
              .toCsv(),
          endsWith('a,bootloader,recovery,0x200000,28K,\n'));
      expect(
          PartitionTable.fromCsv('a,partition_table,ota,,\n').toCsv(), endsWith('a,partition_table,ota,0x9000,4K,\n'));
      expect(PartitionTable.fromCsv('a,partition_table,ota,0x10000,\n').toCsv(),
          endsWith('a,partition_table,ota,0x10000,4K,\n'));
      final primaries = PartitionTable.fromCsv('a,partition_table,primary,,\nb,bootloader,primary,,\n',
          primaryBootloaderOffset: 0x1000, recoveryBootloaderOffset: 0x200000);
      expect(primaries.toCsv(), endsWith('a,partition_table,primary,0x8000,4K,\nb,bootloader,primary,0x1000,28K,\n'));
      primaries.verify(partitionTableOffset: 0x8000);
    });
  });

  group('fromCsv', () {
    test('fills in blank offsets, resolves negative sizes and flags', () {
      final table = PartitionTable.fromCsv('a,data,nvs,0x9000,0x1000\n'
          'b,data,nvs,,-0x20000\n'
          'c,app,factory,,64K\n'
          'd,data,,,0x1000,encrypted:readonly\n');
      expect(
          table.toCsv(),
          '# ESP-IDF Partition Table\n'
          '# Name, Type, SubType, Offset, Size, Flags\n'
          'a,data,nvs,0x9000,4K,\n'
          'b,data,nvs,0xa000,88K,\n'
          'c,app,factory,0x20000,64K,\n'
          'd,data,undefined,0x30000,4K,encrypted:readonly\n');
      expect(
          toHex(table.toBinary().sublist(0, 0x80)),
          'aa50010200900000001000006100000000000000000000000000000000000000'
          'aa50010200a00000006001006200000000000000000000000000000000000000'
          'aa50000000000200000001006300000000000000000000000000000000000000'
          'aa50010600000300001000006400000000000000000000000000000003000000');
      expect(table[3].lineNumber, 4);
      expect(table[3].flagNames, ['encrypted', 'readonly']);
      expect(
          table.format(),
          '| Name | Type | Subtype   | Offset  | Size | Flags              |\n'
          '|------|------|-----------|---------|------|--------------------|\n'
          '| a    | data | nvs       | 0x9000  | 4K   |                    |\n'
          '| b    | data | nvs       | 0xa000  | 88K  |                    |\n'
          '| c    | app  | factory   | 0x20000 | 64K  |                    |\n'
          '| d    | data | undefined | 0x30000 | 4K   | encrypted:readonly |');
    });

    test('numeric types and subtypes, K/M suffixes', () {
      final table = PartitionTable.fromCsv('a,data,0x42,0x9000,1k\nb,0x1,0x03,,2M\n');
      expect(table.toCsv(), endsWith('a,data,66,0x9000,1K,\nb,data,coredump,0xa000,2M,\n'));
      expect(table.flashSize, 2138112);
      expect(
          () => table.verifySizeFits(0x100000),
          throwsTableError('Partitions tables occupies 2.0MB of flash (2138112 bytes) which does not fit in '
              'available flash size 1MB.'));
      table.verifySizeFits(0x400000);
      expect(PartitionTable().flashSize, 0);
    });

    test('line-level errors', () {
      final cases = {
        'a,data,nvs,0x8000,0x6000\n': 'CSV Error at line 1: Partitions overlap. Partition sets offset 0x8000. '
            'But partition table occupies the whole sector 0x8000. Use a free offset 0x9000 or higher.',
        'a,data,nvs,0x9000,0x6000\nb,data,nvs,0xa000,0x6000\n':
            'CSV Error at line 2: Partitions overlap. Partition sets offset 0xa000. Previous partition ends 0xf000',
        'a,data,nvs,0x9000,\n': "Error at line 1: Size field can't be empty",
        'a,,nvs,0x9000,0x1000\n': "Error at line 1: Field 'type' can't be left empty.",
        'a,app,,0x10000,0x10000\n': 'Error at line 1: App partition cannot have an empty subtype',
        'a,data,nvs,0x9000,0x1000,foo\n': "Error at line 1: CSV flag column contains unknown flag 'foo'",
        'a,data,bogus,0x9000,0x1000\n': "Error at line 1: Value 'bogus' is not valid. Known keywords: ota, phy, "
            'nvs, coredump, nvs_keys, efuse, undefined, esphttpd, fat, spiffs, littlefs, tee_ota',
        'a,bogus,nvs,0x9000,0x1000\n':
            "Error at line 1: Value 'bogus' is not valid. Known keywords: bootloader, partition_table, app, data",
        'a,data,nvs,0x9000,zz\n': 'Error at line 1: Invalid field value zz',
        'a,0x40,bogus,0x9000,0x1000\n': 'Error at line 1: Invalid field value bogus',
        // Deviation: the original only reported unknown variables at the very
        // start of a line (re.match) and otherwise failed on the raw `$FOO`.
        'a,data,nvs,0x9000,0x1000\nb,data,nvs,\$FOO,0x1000\n': "Error at line 2: unknown variable 'FOO'",
      };
      cases.forEach((csv, message) {
        expect(() => PartitionTable.fromCsv(csv), throwsTableError(message), reason: csv);
      });
    });

    test('variable substitution', () {
      final table = PartitionTable.fromCsv('a,data,nvs,\$OFF,\${SIZE}\n', variables: {'OFF': '0x9000', 'SIZE': '24K'});
      expect(table.single.offset, 0x9000);
      expect(table.single.size, 0x6000);
    });

    test('accepts CRLF, comments, blank lines and whitespace', () {
      final table = PartitionTable.fromCsv('# c\r\n\r\n  nvs , data , NVS , 0x9000 , 24K \r\n');
      expect(table.single,
          PartitionDefinition(name: 'nvs', type: 1, subtype: 2, offset: 0x9000, size: 0x6000, lineNumber: 3));
    });

    test('empty table', () {
      expect(PartitionTable.fromCsv('# nothing\n'), isEmpty);
      expect(() => PartitionTable.fromCsv('# nothing\n').requireNotEmpty('x'),
          throwsTableError('Partition table from x is empty (no partitions defined)'));
      expect(() => parsePartitionTableCsv('# nothing\n', source: 'x'),
          throwsTableError('Partition table from x is empty (no partitions defined)'));
    });
  });

  group('parseIntField', () {
    test('literals and suffixes', () {
      expect(parseIntField('1M'), 1048576);
      expect(parseIntField('1mk'), 1073741824);
      expect(parseIntField('0x10'), 16);
      expect(parseIntField('0X10'), 16);
      expect(parseIntField('0o10'), 8);
      expect(parseIntField('0b10'), 2);
      expect(parseIntField('-0x10'), -16);
      expect(parseIntField(' 16 '), 16);
      expect(parseIntField('1_000'), 1000);
      expect(() => parseIntField('010'), throwsTableError('Invalid field value 010'));
      expect(() => parseIntField('0x'), throwsTableError('Invalid field value 0x'));
      expect(() => parseIntField('1__0'), throwsTableError('Invalid field value 1__0'));
    });

    test('keywords are case-insensitive', () {
      expect(parseIntField('NVS', subtypeKeywords(PartitionType.data.value)), 2);
      expect(
          () => parseIntField('', subtypeKeywords(PartitionType.data.value)),
          throwsTableError(
              "Value '' is not valid. Known keywords: ota, phy, nvs, coredump, nvs_keys, efuse, undefined, "
              'esphttpd, fat, spiffs, littlefs, tee_ota'));
    });
  });

  group('verify', () {
    PartitionDefinition part(String name, int type, int subtype, int offset, int size, {bool readonly = false}) =>
        PartitionDefinition(name: name, type: type, subtype: subtype, offset: offset, size: size, readonly: readonly);

    test('duplicate names', () {
      expect(() => PartitionTable.fromCsv('a,data,nvs,0x9000,0x6000\na,data,nvs,0x10000,0x6000\n').verify(),
          throwsTableError('Partition names must be unique'));
    });

    test('overlap', () {
      final table = PartitionTable([part('a', 1, 2, 0x1000, 0x3000), part('b', 1, 2, 0x2000, 0x3000)]);
      expect(() => table.verify(), throwsTableError('Partition at 0x2000 overlaps 0x1000-0x3fff'));
      // Sorted by offset, not table order.
      final reversed = PartitionTable([part('b', 1, 2, 0x2000, 0x3000), part('a', 1, 2, 0x1000, 0x3000)]);
      expect(() => reversed.verify(), throwsTableError('Partition at 0x2000 overlaps 0x1000-0x3fff'));
      PartitionTable([part('a', 1, 2, 0x1000, 0x3000), part('b', 1, 2, 0x4000, 0x3000)]).verify();
    });

    test('below the partition table', () {
      final table = PartitionTable([part('a', 1, 2, 0x1000, 0x3000)]);
      table.verify();
      expect(() => table.verify(partitionTableOffset: 0x8000),
          throwsTableError('Partition offset 0x1000 is below 0x9000'));
      PartitionTable([PartitionDefinition.bootloader(offset: 0x1000, size: 0x7000)])
          .verify(partitionTableOffset: 0x8000);
    });

    test('alignment', () {
      expect(() => PartitionTable.fromCsv('a,data,nvs,0x9100,0x6000\n').verify(),
          throwsValidationError('Partition a invalid: Offset 0x9100 is not aligned to 0x1000'));
      expect(() => PartitionTable.fromCsv('a,app,factory,0x10000,0x30100\n').verify(),
          throwsValidationError('Partition a invalid: Size 0x30100 is not aligned to 0x1000'));
      expect(() => PartitionTable.fromCsv('a,app,factory,0x10100,0x30000\n').verify(),
          throwsValidationError('Partition a invalid: Offset 0x10100 is not aligned to 0x10000'));
      expect(() => PartitionTable.fromCsv('a,app,factory,0x10000,0x30800\n').verify(secure: SecureBoot.v1),
          throwsValidationError('Partition a invalid: Size 0x30800 is not aligned to 0x10000'));
      expect(() => PartitionTable.fromCsv('a,app,factory,0x10000,0x30800\n').verify(secure: SecureBoot.v2),
          throwsValidationError('Partition a invalid: Size 0x30800 is not aligned to 0x1000'));
      PartitionTable.fromCsv('a,app,factory,0x10000,0x30000\n').verify(secure: SecureBoot.v2);
    });

    test('flags', () {
      expect(
          () => PartitionTable.fromCsv('a,data,nvs,0x9000,0x2000\n').verify(),
          throwsValidationError("Partition a invalid: 'a' partition of type 1 and subtype 2 of this size (0x2000) "
              "must be flagged as 'readonly' (the size of read/write NVS has to be at least 0x3000)"));
      PartitionTable.fromCsv('a,data,nvs,0x9000,0x2000,readonly\n').verify();
      expect(
          () => PartitionTable.fromCsv('a,data,ota,0x9000,0x2000,readonly\n').verify(),
          throwsValidationError(
              "Partition a invalid: 'a' partition of type 1 and subtype 0 is always read-write and cannot be read-only"));
      expect(
          () => PartitionTable([part('cd', 1, 3, 0x9000, 0x10000, readonly: true)]).verify(),
          throwsValidationError(
              "Partition cd invalid: 'cd' partition of type 1 and subtype 3 is always read-write and cannot be read-only"));
    });

    test('otadata', () {
      expect(
          () => PartitionTable.fromCsv('a,data,ota,0x9000,0x2000\nb,data,ota,0xb000,0x2000\n').verify(),
          throwsTableError('Found multiple otadata partitions. Only one partition can be defined with type="data"(1) '
              'and subtype="ota"(0).'));
      expect(() => PartitionTable.fromCsv('a,data,ota,0x9000,0x3000\n').verify(),
          throwsTableError('otadata partition must have size = 0x2000'));
      expect(() => PartitionTable.fromCsv('a,data,tee_ota,0x9000,0x3000\n').verify(),
          throwsTableError('TEE otadata partition must have size = 0x2000'));
      expect(
          () => PartitionTable.fromCsv('a,data,tee_ota,0x9000,0x2000\nb,data,tee_ota,0xb000,0x2000\n').verify(),
          throwsTableError('Found multiple TEE otadata partitions. Only one partition can be defined with '
              'type="data"(1) and subtype="tee_ota"(0x90).'));
    });
  });

  group('binary', () {
    final good = PartitionTable.fromCsv('a,data,nvs,0x9000,0x6000\n').toBinary();

    test('malformed input', () {
      expect(() => PartitionTable.fromBinary(Uint8List(31)),
          throwsTableError('Partition table length must be a multiple of 32 bytes'));
      expect(() => PartitionTable.fromBinary(Uint8List(32)),
          throwsTableError("Invalid magic bytes (b'\\x00\\x00') for partition definition"));
      expect(() => PartitionTable.fromBinary(Uint8List(0)),
          throwsTableError('Partition table is missing an end-of-table marker'));
      expect(() => PartitionTable.fromBinary(good.sublist(0, 0x40)),
          throwsTableError('Partition table is missing an end-of-table marker'));
    });

    test('MD5 row', () {
      final corrupted = Uint8List.fromList(good)..[0x30] ^= 1;
      expect(
          () => PartitionTable.fromBinary(corrupted),
          throwsTableError("MD5 checksums don't match! (computed: 0x75f230f27e169091703d2e6a131c7dc9, "
              'parsed: 0x74f230f27e169091703d2e6a131c7dc9)'));
      // Without checking, the MD5 row is just an entry with the wrong magic.
      expect(() => PartitionTable.fromBinary(corrupted, md5sum: false),
          throwsTableError("Invalid magic bytes (b'\\xeb\\xeb') for partition definition"));
      final noMd5 = PartitionTable.fromCsv('a,data,nvs,0x9000,0x6000\n').toBinary(md5sum: false);
      expect(
          toHex(noMd5.sublist(0, 0x40)),
          'aa50010200900000006000006100000000000000000000000000000000000000'
          'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff');
      expect(noMd5.length, PartitionTable.maxBinaryLength);
      expect(PartitionTable.fromBinary(noMd5).toCsv(), endsWith('a,data,nvs,0x9000,24K,\n'));
      // Truncated right after the entry: no MD5, but the end marker is there.
      expect(PartitionTable.fromBinary(Uint8List.fromList([...good.sublist(0, 0x40), ...List.filled(32, 0xFF)])).length,
          1);
    });

    test('full-length name and unknown flag bits', () {
      final raw = fromHex('aa50010200900000001000003031323334353637383961626364656607000000'
          'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff');
      final entry = PartitionTable.fromBinary(raw, md5sum: false).single;
      expect(entry.toCsv(), '0123456789abcdef,data,nvs,0x9000,4K,encrypted:readonly');
      expect(toHex(entry.toBinary()), 'aa50010200900000001000003031323334353637383961626364656603000000');
    });

    test('names longer than 16 bytes are truncated on encode', () {
      final entry =
          PartitionDefinition(name: 'abcdefghijklmnopqrstu', type: 1, subtype: 6, offset: 0x9000, size: 0x1000);
      expect(toHex(entry.toBinary()), 'aa50010600900000001000006162636465666768696a6b6c6d6e6f7000000000');
      expect(PartitionDefinition.fromBinary(entry.toBinary()).name, 'abcdefghijklmnop');
    });

    test('size limit', () {
      PartitionTable ofSize(int n) =>
          PartitionTable.fromCsv([for (var i = 0; i < n; i++) 'p$i,data,0x40,,0x1000'].join('\n'));
      expect(() => ofSize(96).toBinary(), throwsTableError('Binary partition table length (3104) longer than max'));
      expect(() => ofSize(95).toBinary(), throwsTableError('Binary partition table length (3072) longer than max'));
      expect(ofSize(95).toBinary(md5sum: false).length, 3072);
      expect(() => ofSize(96).toBinary(md5sum: false),
          throwsTableError('Binary partition table length (3072) longer than max'));
    });
  });

  group('decodeCsv', () {
    const text = 'nvs,data,nvs,0x9000,24K\n';
    test('byte order marks', () {
      expect(PartitionTable.decodeCsv(Uint8List.fromList(utf8.encode(text))), text);
      expect(PartitionTable.decodeCsv(Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(text)])), text);
      final utf16le = Uint8List.fromList([
        0xFF,
        0xFE,
        for (final c in text.codeUnits) ...[c, 0]
      ]);
      expect(PartitionTable.decodeCsv(utf16le), text);
      final utf16be = Uint8List.fromList([
        0xFE,
        0xFF,
        for (final c in text.codeUnits) ...[0, c]
      ]);
      expect(PartitionTable.decodeCsv(utf16be), text);
      final utf32le = Uint8List.fromList([
        0xFF,
        0xFE,
        0,
        0,
        for (final c in text.codeUnits) ...[c, 0, 0, 0]
      ]);
      expect(PartitionTable.decodeCsv(utf32le), text);
      final utf32be = Uint8List.fromList([
        0,
        0,
        0xFE,
        0xFF,
        for (final c in text.codeUnits) ...[0, 0, 0, c]
      ]);
      expect(PartitionTable.decodeCsv(utf32be), text);
    });
  });

  group('format', () {
    final table = PartitionTable.fromCsv(fixtureText('partitions.csv'));

    test('marks the live otadata copy', () {
      final params =
          OtaDataParameters(entry: OtaDataSelectEntry(4, OtaImageState.valid), copy: OtaDataCopy.a, appCount: 2);
      expect(table.format(otadata: params), fixtureFormatted.replaceAll('ota     |', 'ota (A) |'));
      expect(
          table.format(otadata: OtaDataParameters(entry: null, copy: null, appCount: 2)),
          '| Name     | Type | Subtype       | Offset  | Size |\n'
          '|----------|------|---------------|---------|------|\n'
          '| nvs      | data | nvs           | 0x9000  | 24K  |\n'
          '| otadata  | data | ota (invalid) | 0xf000  | 8K   |\n'
          '| phy_init | data | phy           | 0x11000 | 4K   |\n'
          '| factory  | app  | factory       | 0x20000 | 192K |\n'
          '| ota_0    | app  | ota_0         | 0x50000 | 192K |\n'
          '| ota_1    | app  | ota_1         | 0x80000 | 192K |\n'
          '| storage  | data | spiffs        | 0xb0000 | 64K  |');
    });

    test('app description column and active slot marker', () {
      final params = OtaDataParameters(entry: OtaDataSelectEntry(4), copy: OtaDataCopy.b, appCount: 2);
      expect(params.slot, 1);
      expect(
          table.format(otadata: params, appDescription: (p) => p.name == 'ota_1' ? 'fw 1.2' : ''),
          '| Name     | Type | Subtype | Offset  | Size | App description |\n'
          '|----------|------|---------|---------|------|-----------------|\n'
          '| nvs      | data | nvs     | 0x9000  | 24K  |                 |\n'
          '| otadata  | data | ota (B) | 0xf000  | 8K   |                 |\n'
          '| phy_init | data | phy     | 0x11000 | 4K   |                 |\n'
          '| factory  | app  | factory | 0x20000 | 192K |                 |\n'
          '| ota_0    | app  | ota_0   | 0x50000 | 192K |                 |\n'
          '| ota_1    | app  | ota_1   | 0x80000 | 192K | fw 1.2 *        |\n'
          '| storage  | data | spiffs  | 0xb0000 | 64K  |                 |');
      final slot0 = OtaDataParameters(entry: OtaDataSelectEntry(3), copy: OtaDataCopy.a, appCount: 2);
      expect(table.format(otadata: slot0, appDescription: (_) => ''),
          contains('| ota_0    | app  | ota_0   | 0x50000 | 192K | *               |'));
    });

    test('empty table', () {
      expect(PartitionTable().format(),
          '| Name | Type | Subtype | Offset | Size |\n|------|------|---------|--------|------|');
    });
  });

  group('OTA helpers', () {
    test('otaAppCount counts only ota_N slots', () {
      // Deviation: the Python `read_otadata` range check also counted the
      // `test` (0x20) subtype; esp_ota_get_app_partition_count does not.
      final table = PartitionTable.fromCsv('a,app,factory,0x10000,0x10000\n'
          'b,app,ota_0,,0x10000\n'
          'c,app,ota_1,,0x10000\n'
          'd,app,test,,0x10000\n'
          'e,app,tee_0,,0x10000\n');
      expect(table.otaAppCount, 2);
      expect(table.otadataPartition, isNull);
    });
  });

  group('PartitionTableFormat.resolve', () {
    test('explicit, extension, default', () {
      expect(PartitionTableFormat.resolve(outputFile: 'x.bin', explicit: PartitionTableFormat.csv),
          PartitionTableFormat.csv);
      expect(PartitionTableFormat.resolve(outputFile: 'dir.d/x.CSV'), PartitionTableFormat.csv);
      expect(PartitionTableFormat.resolve(outputFile: 'x.bin'), PartitionTableFormat.bin);
      expect(PartitionTableFormat.resolve(outputFile: 'x.img'), PartitionTableFormat.bin);
      expect(PartitionTableFormat.resolve(), PartitionTableFormat.csv);
      for (final bad in ['x.txt', 'x', 'dir.csv/x', '.csv']) {
        expect(
            () => PartitionTableFormat.resolve(outputFile: bad),
            throwsTableError("Cannot infer partition table format from '$bad'; pass --format csv|bin or use a "
                '.csv/.bin extension'),
            reason: bad);
      }
    });
  });

  group('PartitionDefinition', () {
    test('toString and equality', () {
      const a = PartitionDefinition(name: 'a', type: 1, subtype: 2, offset: 0x9000, size: 0x6000);
      expect(a.toString(), "Part 'a' 1/2 @ 0x9000 size 0x6000");
      expect(a, a.copyWith(lineNumber: 3));
      expect(a, isNot(a.copyWith(readonly: true)));
      expect(a.end, 0xf000);
      expect(a.typeName, 'data');
      expect(a.subtypeName, 'nvs');
      expect(a.copyWith(type: 0x40, subtype: 0x41).typeName, '64');
      expect(a.copyWith(type: 0x40, subtype: 0x41).subtypeName, '65');
      expect(a.copyWith(type: 0x40, subtype: 0x41).knownType, isNull);
    });

    test('virtual entries', () {
      const bootloader = PartitionDefinition.bootloader(offset: 0x1000, size: 0x7000);
      expect(bootloader.toCsv(), 'bootloader,bootloader,primary,0x1000,28K,');
      expect(bootloader.isPrimaryBootloader, isTrue);
      const table = PartitionDefinition.partitionTable(offset: 0x8000, size: 0x1000);
      expect(table.toCsv(), 'partition_table,partition_table,primary,0x8000,4K,');
      expect(table.isPrimaryPartitionTable, isTrue);
    });
  });
}
