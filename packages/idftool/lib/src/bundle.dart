/// The bundle format: a flat ZIP whose filenames decide the operations.
///
/// | File | Operation |
/// |---|---|
/// | `partition_table.csv` / `.bin` | Replace the table (written first; later names resolve against it) |
/// | `bootloader.bin` | Write at the chip's bootloader offset |
/// | `@factory.bin` | Factory flash: the factory partition (or `ota_0`), then clear otadata |
/// | `@ota.bin` | OTA: the next slot, then switch boot to it |
/// | `<name>.bin` | Write to the partition called `name` |
///
/// Anything else is ignored, except an optional `manifest.json` (see
/// [FlashManifest]) for what a file cannot express. The `@` prefix is
/// reserved: the table parser rejects partition names starting with it, so
/// role files can never collide with a partition (`factory.bin` and
/// `ota.bin` still mean the partitions of those names).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'device.dart';
import 'manifest.dart';
import 'partition_table.dart';
import 'partition_table_files.dart';


/// Marks a role file rather than a partition name.
const bundleRolePrefix = '@';

/// Fixed order in which a bundle's parts are written.
enum BundlePart { table, bootloader, factory, ota, partition }

/// What a bundle ZIP contains, by role.
class BundleContents {
  BundleContents({
    this.table,
    this.tableFile,
    this.bootloader,
    this.factoryApp,
    this.otaApp,
    Map<String, Uint8List>? partitions,
    this.manifest,
    List<String>? ignored,
  })  : partitions = partitions ?? {},
        ignored = ignored ?? [];

  /// The table to write first, if the bundle carries one.
  final PartitionTable? table;

  /// The entry [table] came from (`partition_table.csv` or `.bin`).
  final String? tableFile;
  final Uint8List? bootloader;
  final Uint8List? factoryApp;
  final Uint8List? otaApp;

  /// Named writes, by partition name.
  final Map<String, Uint8List> partitions;
  final FlashManifest? manifest;

  /// Entries that mean nothing to a bundle (a README, say).
  final List<String> ignored;

  bool get isEmpty => table == null && bootloader == null && factoryApp == null && otaApp == null && partitions.isEmpty;

  /// Whether the bundle addresses partitions by name against a table it
  /// does not carry — it then needs a device whose table has those names.
  bool get needsDeviceTable => table == null && partitions.isNotEmpty;
}

/// Read [zip] by the filename convention. Throws [IdfToolException] for a
/// bad ZIP, both role files at once, or an unknown `@` file.
BundleContents readBundle(
  Uint8List zip, {
  int partitionTableOffset = PartitionTable.defaultOffset,
  int? primaryBootloaderOffset,
}) {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(zip, verify: true);
  } catch (e) {
    throw IdfToolException('Not a valid ZIP archive: $e');
  }
  PartitionTable? table;
  String? tableFile;
  Uint8List? bootloader, factoryApp, otaApp;
  final partitions = <String, Uint8List>{};
  FlashManifest? manifest;
  final ignored = <String>[];
  for (final entry in archive.files.where((f) => f.isFile)) {
    final name = entry.name.split('/').last;
    if (name != entry.name) {
      ignored.add(entry.name); // nothing in subdirectories
      continue;
    }
    final bytes = entry.readBytes()!;
    final dot = name.lastIndexOf('.');
    final stem = dot < 0 ? name : name.substring(0, dot);
    final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
    if (name == FlashManifest.fileName) {
      manifest = FlashManifest.fromJson(jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>);
    } else if (stem == 'partition_table' && (ext == 'csv' || ext == 'bin')) {
      table = PartitionTable.isBinary(bytes)
          ? PartitionTable.fromBinary(bytes)
          : parsePartitionTableCsv(PartitionTable.decodeCsv(bytes),
              source: name, partitionTableOffset: partitionTableOffset, primaryBootloaderOffset: primaryBootloaderOffset);
      tableFile = name;
    } else if (ext != 'bin') {
      ignored.add(name);
    } else if (stem == 'bootloader') {
      bootloader = bytes;
    } else if (stem.startsWith(bundleRolePrefix)) {
      switch (stem.substring(1)) {
        case 'factory':
          factoryApp = bytes;
        case 'ota':
          otaApp = bytes;
        default:
          throw IdfToolException("Unknown role file '$name' (only ${bundleRolePrefix}factory.bin and ${bundleRolePrefix}ota.bin)");
      }
    } else {
      partitions[stem] = bytes;
    }
  }
  if (factoryApp != null && otaApp != null) {
    throw IdfToolException('A bundle cannot carry both ${bundleRolePrefix}factory.bin and ${bundleRolePrefix}ota.bin');
  }
  return BundleContents(
    table: table,
    tableFile: tableFile,
    bootloader: bootloader,
    factoryApp: factoryApp,
    otaApp: otaApp,
    partitions: partitions,
    manifest: manifest,
    ignored: ignored,
  );
}

/// The partition a factory flash of [table] would write.
PartitionDefinition? factoryTarget(PartitionTable table) =>
    table.findByType(PartitionType.app, AppSubtype.factory).firstOrNull ?? table.findByType(PartitionType.app, AppSubtype.ota0).firstOrNull;

/// Named writes or erases that collide with a role file, given the table
/// they resolve against: a factory flash owns [factoryTarget], an OTA flash
/// may pick any `ota_N`.
List<String> bundleConflicts({
  required PartitionTable table,
  required Iterable<String> namedPartitions,
  required bool hasFactory,
  required bool hasOta,
}) {
  final problems = <String>[];
  if (hasFactory && hasOta) problems.add('${bundleRolePrefix}factory and ${bundleRolePrefix}ota cannot both be present');
  final factory = factoryTarget(table)?.name;
  for (final name in namedPartitions) {
    final p = table.findByName(name);
    if (p == null) continue;
    if (hasFactory && name == factory) problems.add("'$name' is written by name and by ${bundleRolePrefix}factory");
    if (hasOta && p.isOtaApp) problems.add("'$name' is written by name while ${bundleRolePrefix}ota may pick it");
  }
  return problems;
}

/// Encode a bundle by the same convention. [manifest] is written only when
/// given; a bundle with no extras needs none.
Uint8List encodeBundle({
  PartitionTable? table,
  Uint8List? bootloader,
  Uint8List? factoryApp,
  Uint8List? otaApp,
  Map<String, Uint8List> partitions = const {},
  FlashManifest? manifest,
}) {
  final archive = Archive();
  if (table != null) archive.add(ArchiveFile.string('partition_table.csv', table.toCsv()));
  if (bootloader != null) archive.add(ArchiveFile.bytes('bootloader.bin', bootloader));
  if (factoryApp != null) archive.add(ArchiveFile.bytes('${bundleRolePrefix}factory.bin', factoryApp));
  if (otaApp != null) archive.add(ArchiveFile.bytes('${bundleRolePrefix}ota.bin', otaApp));
  for (final MapEntry(key: name, value: bytes) in partitions.entries) {
    archive.add(ArchiveFile.bytes('$name.bin', bytes));
  }
  if (manifest != null) archive.add(ArchiveFile.string(FlashManifest.fileName, const JsonEncoder.withIndent('  ').convert(manifest.toJson())));
  return ZipEncoder().encodeBytes(archive);
}
