// Expectations generated with the Python original (`idftool.partitions`).
import 'dart:io';

import 'package:idftool/src/partition_slice.dart';
import 'package:idftool/src/partition_table.dart';
import 'package:test/test.dart';

Matcher throwsLookup(String message) =>
    throwsA(isA<PartitionLookupException>().having((e) => e.message, 'message', message));

void main() {
  final table = PartitionTable.fromCsv(File('test/fixtures/partitions.csv').readAsStringSync());
  // Virtual entries: the table sector at 0x8000 and a bootloader at 0x0.
  final resolver = PartitionResolver.forTable(table, primaryBootloaderOffset: 0x0);
  // No bootloader offset known: no bootloader entry.
  final noBootloader = PartitionResolver.forTable(table);

  group('forTable', () {
    test('creates virtual entries when the table has none', () {
      expect(resolver.partitionTableEntry, const PartitionDefinition.partitionTable(offset: 0x8000, size: 0x1000));
      expect(resolver.bootloaderEntry, const PartitionDefinition.bootloader(offset: 0x0, size: 0x8000));
      expect(noBootloader.bootloaderEntry, isNull);
      final moved = PartitionResolver.forTable(table, partitionTableOffset: 0x10000, primaryBootloaderOffset: 0x1000);
      expect(moved.partitionTableEntry.offset, 0x10000);
      expect(moved.bootloaderEntry, const PartitionDefinition.bootloader(offset: 0x1000, size: 0xf000));
    });

    test('uses the table rows when present', () {
      final withRows = PartitionTable.fromCsv(File('test/fixtures/bootloader-template.csv').readAsStringSync(),
          primaryBootloaderOffset: 0x0);
      final r = PartitionResolver.forTable(withRows);
      expect(r.partitionTableEntry, same(withRows[1]));
      expect(r.bootloaderEntry, same(withRows[0]));
      expect(r.slice('part_table'), (partition: withRows[1], address: 0x8000, length: 0x1000));
      expect(r.slice('bootloader[0x1000:]'), (partition: withRows[0], address: 0x1000, length: 0x7000));
    });
  });

  group('slice', () {
    final ok = <String, (String, int, int)>{
      'nvs': ('nvs', 0x9000, 0x6000),
      'nvs[0x100:0x200]': ('nvs', 0x9100, 0x100),
      'nvs[-0x1000:]': ('nvs', 0xe000, 0x1000),
      'factory[+0x100]': ('factory', 0x20100, 0x2ff00),
      'factory[0x100:+0x100]': ('factory', 0x20100, 0x100),
      'factory[:+0x100]': ('factory', 0x20000, 0x100),
      'factory[0x1000]': ('factory', 0x21000, 0x2f000),
      'nvs[:]': ('nvs', 0x9000, 0x6000),
      'nvs[]': ('nvs', 0x9000, 0x6000),
      '0x9000': ('nvs', 0x9000, 0x6000),
      '0xf000[0x10:0x20]': ('otadata', 0xf010, 0x10),
      '36864': ('nvs', 0x9000, 0x6000),
      'partition_table': ('partition_table', 0x8000, 0x1000),
      'bootloader': ('bootloader', 0x0, 0x8000),
      'bootloader[0x1000:]': ('bootloader', 0x1000, 0x7000),
      'nvs[+0x100:0x200]': ('nvs', 0x9100, 0x100),
      'ota_0[:-0x100]': ('ota_0', 0x50000, 0x2ff00),
      'nvs[:0]': ('nvs', 0x9000, 0x0),
      'nvs[0x6000:]': ('nvs', 0xf000, 0x0),
      'nvs[100:200]': ('nvs', 0x9064, 0x64),
      'nvs[0x100:-0x100]': ('nvs', 0x9100, 0x5e00),
      'nvs[-0x100:-0x50]': ('nvs', 0xef00, 0xb0),
      'nvs[-0x100:+0x50]': ('nvs', 0xef00, 0x50),
    };
    ok.forEach((spec, expected) {
      test(spec, () {
        final (name, address, length) = expected;
        final result = resolver.slice(spec);
        expect(result.partition.name, name);
        expect(result.address, address);
        expect(result.length, length);
      });
    });

    final errors = {
      'nvs[0x7000:]': 'Invalid slice range [0x7000:0x6000] for partition nvs of size 0x6000',
      'nvs[0x100:0x50]': 'Invalid slice range [0x100:0x50] for partition nvs of size 0x6000',
      'nvs[-0x7000:]': 'Invalid slice range [-0x1000:0x6000] for partition nvs of size 0x6000',
      'nvs[0x100:-0x7000]': 'Invalid slice range [0x100:-0x1000] for partition nvs of size 0x6000',
      'nvs[0x100:-0x6000]': 'Invalid slice range [0x100:0x0] for partition nvs of size 0x6000',
      'bogus': "No partition named 'bogus'",
      'nvs[0x1:0x2:0x3]': "No partition named 'nvs[0x1:0x2:0x3]'",
      'nvs[': "No partition named 'nvs['",
      '[0x100]': "No partition named '[0x100]'",
      'nvs[0X100:]': "No partition named 'nvs[0X100:]'",
      '0x9001': 'No partition at offset 0x9001',
      // Virtual entries aren't addressable by offset.
      '0x8000': 'No partition at offset 0x8000',
      // Deviation: Python let int() raise on bare hex digits the regex admits.
      'nvs[ff:]': "Invalid slice bound 'ff' in nvs[ff:]",
    };
    errors.forEach((spec, message) {
      test('$spec fails', () => expect(() => resolver.slice(spec), throwsLookup(message)));
    });

    test('bootloader without an offset', () {
      expect(() => noBootloader.slice('bootloader'), throwsLookup("No partition named 'bootloader'"));
    });
  });

  group('address', () {
    final ok = <String, (String, int)>{
      'nvs': ('nvs', 0x9000),
      'factory[+0x100]': ('factory', 0x20100),
      'factory[0x1000]': ('factory', 0x21000),
      'nvs[]': ('nvs', 0x9000),
      '0x9000': ('nvs', 0x9000),
      '36864': ('nvs', 0x9000),
      'partition_table': ('partition_table', 0x8000),
      'nvs[-0x1000]': ('nvs', 0xe000),
      'nvs[0x6000]': ('nvs', 0xf000),
    };
    ok.forEach((spec, expected) {
      test(spec, () {
        final (name, address) = expected;
        final result = noBootloader.address(spec);
        expect(result.partition.name, name);
        expect(result.address, address);
      });
    });

    final errors = {
      // Ranges aren't accepted here, so the suffix is taken as part of the name.
      'nvs[0x100:0x200]': "No partition named 'nvs[0x100:0x200]'",
      'nvs[:]': "No partition named 'nvs[:]'",
      'bootloader': "No partition named 'bootloader'",
      'nvs[0x7000]': 'Invalid offset [0x7000] for partition nvs of size 0x6000',
      'nvs[-0x7000]': 'Invalid offset [-0x1000] for partition nvs of size 0x6000',
      '0x9001': 'No partition at offset 0x9001',
    };
    errors.forEach((spec, message) {
      test('$spec fails', () => expect(() => noBootloader.address(spec), throwsLookup(message)));
    });

    test('bootloader with an offset', () {
      expect(resolver.address('bootloader[0x1000]'), (partition: resolver.bootloaderEntry!, address: 0x1000));
    });
  });
}
