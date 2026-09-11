import 'package:archive/archive.dart';
import 'package:esptool/esptool.dart';
import 'package:flutter/foundation.dart';
import 'package:idftool/idftool.dart';

import '../util/files.dart';
import 'device_session.dart';

enum OpKind { write, erase }

/// One queued change to a partition: a file to write there, or an erase.
class PlannedOp {
  const PlannedOp.write(this.partition, PickedFile this.file, {this.warning}) : kind = OpKind.write;
  const PlannedOp.erase(this.partition, {this.warning})
      : kind = OpKind.erase,
        file = null;

  final OpKind kind;
  final PartitionDefinition partition;
  final PickedFile? file;

  /// Something that doesn't block the operation but the user should see.
  final String? warning;

  bool get isWrite => kind == OpKind.write;

  String get summary => switch (kind) {
        OpKind.write => 'Write ${file!.name} (${file!.bytes.length.bytesString})',
        OpKind.erase => 'Erase ${partition.size.bytesString}',
      };
}

/// The changes queued for the connected device: optionally a replacement
/// partition table, plus one write or erase per partition. Everything is
/// resolved against [table] — the staged table if there is one, else the
/// device's — with the bootloader and the table's own sector present as
/// virtual rows so they can be dumped and written like any partition.
///
/// Nothing here touches the device; the page flashes the plan.
class FlashPlan extends ChangeNotifier {
  EspChip? _chip;
  int _partitionTableOffset = PartitionTable.defaultOffset;
  int _partitionTableSize = PartitionTable.size;
  int? _primaryBootloaderOffset;

  PartitionTable? _deviceTable;
  PartitionTable? _stagedTable;
  String? _stagedTableSource;
  String? _stagedTableProblem;
  final _ops = <String, PlannedOp>{};

  /// Where the device's ROM looks for the bootloader, per chip.
  int? get primaryBootloaderOffset => _primaryBootloaderOffset;
  int get partitionTableOffset => _partitionTableOffset;

  /// The table last read from the device.
  PartitionTable? get deviceTable => _deviceTable;

  /// A replacement table waiting to be flashed, and where it came from.
  PartitionTable? get stagedTable => _stagedTable;
  String? get stagedTableSource => _stagedTableSource;

  /// Why the staged table failed verification, if it did.
  String? get stagedTableProblem => _stagedTableProblem;

  /// The table everything is planned against.
  PartitionTable? get table => _stagedTable ?? _deviceTable;

  Iterable<PlannedOp> get ops => _ops.values;
  PlannedOp? opFor(String partitionName) => _ops[partitionName];
  bool get isEmpty => _stagedTable == null && _ops.isEmpty;
  int get length => _ops.length + (_stagedTable == null ? 0 : 1);
  int get bytesToWrite => _ops.values.fold(0, (n, op) => n + (op.file?.bytes.length ?? 0));
  int get warningCount => _ops.values.where((op) => op.warning != null).length + (_stagedTableProblem == null ? 0 : 1);

  /// Ops in [rows] order, as they will be flashed.
  List<PlannedOp> get orderedOps => [
        for (final p in rows)
          if (_ops[p.name] != null) _ops[p.name]!
      ];

  /// The rows to show and address: the bootloader and partition-table
  /// sectors (virtual unless the table itself lists them) then the table.
  List<PartitionDefinition> get rows => _rowsOf(table);

  List<PartitionDefinition> _rowsOf(PartitionTable? table) {
    if (table == null) return const [];
    final r = _resolverFor(table);
    return [
      if (r.bootloaderEntry case final b? when !table.any((p) => identical(p, b))) b,
      if (!table.any((p) => identical(p, r.partitionTableEntry))) r.partitionTableEntry,
      ...table,
    ];
  }

  /// The device's rows, virtual entries included, for dumping what is there.
  List<PartitionDefinition> get deviceRows => _rowsOf(_deviceTable);

  PartitionResolver _resolverFor(PartitionTable table) =>
      PartitionResolver.forTable(table, partitionTableOffset: _partitionTableOffset, partitionTableSize: _partitionTableSize, primaryBootloaderOffset: _primaryBootloaderOffset);

  PartitionDefinition? row(String name) => rows.where((p) => p.name == name).firstOrNull;

  /// Called on connect with the device's geometry; discards any old plan.
  void attach({required EspChip chip, required int partitionTableOffset, required int partitionTableSize, int? primaryBootloaderOffset}) {
    _chip = chip;
    _partitionTableOffset = partitionTableOffset;
    _partitionTableSize = partitionTableSize;
    _primaryBootloaderOffset = primaryBootloaderOffset;
    _deviceTable = null;
    clear();
  }

  void detach() {
    _chip = null;
    _deviceTable = null;
    clear();
  }

  void clear() {
    _stagedTable = null;
    _stagedTableSource = null;
    _stagedTableProblem = null;
    _ops.clear();
    notifyListeners();
  }

  /// Record the table read from the device. Ops are re-checked against it
  /// unless a staged table is what they are planned on. Returns notes about
  /// anything dropped.
  List<String> setDeviceTable(PartitionTable table) {
    _deviceTable = table;
    final notes = _stagedTable == null ? _reconcile() : const <String>[];
    notifyListeners();
    return notes;
  }

  // --------------------------------------------------------------------------
  // Staging
  // --------------------------------------------------------------------------

  /// Queue [file] for [p]. Returns a message if it can't be, else `null`;
  /// a write that goes through may carry a warning.
  String? stageWrite(PartitionDefinition p, PickedFile file) {
    if (p.isPrimaryPartitionTable) return 'Use "Replace table" to stage a new partition table';
    if (file.bytes.isEmpty) return '${file.name} is empty';
    if (file.bytes.length > p.size) {
      return '${file.name} (${file.bytes.length.bytesString}) does not fit in ${p.name} (${p.size.bytesString})';
    }
    _ops[p.name] = PlannedOp.write(p, file, warning: _imageWarning(p, file.bytes));
    notifyListeners();
    return null;
  }

  String? stageErase(PartitionDefinition p) {
    if (p.isPrimaryPartitionTable) return 'The partition table sector is replaced, not erased';
    _ops[p.name] = PlannedOp.erase(p, warning: p.isPrimaryBootloader ? 'The device will not boot until a bootloader is written' : null);
    notifyListeners();
    return null;
  }

  void unstage(String partitionName) {
    if (_ops.remove(partitionName) != null) notifyListeners();
  }

  /// Plan around [table] instead of the device's. Ops are carried over
  /// where their partition still exists with the same geometry (or a write
  /// still fits); the rest are dropped, and the returned notes say which.
  List<String> stageTable(PartitionTable table, {required String source}) {
    _stagedTable = table;
    _stagedTableSource = source;
    _stagedTableProblem = null;
    try {
      table.verify(partitionTableOffset: _partitionTableOffset);
    } catch (e) {
      _stagedTableProblem = '$e';
    }
    final notes = _reconcile();
    notifyListeners();
    return notes;
  }

  List<String> unstageTable() {
    _stagedTable = null;
    _stagedTableSource = null;
    _stagedTableProblem = null;
    final notes = _reconcile();
    notifyListeners();
    return notes;
  }

  /// The staged table is now on the device.
  void tableFlashed() {
    _deviceTable = _stagedTable ?? _deviceTable;
    _stagedTable = null;
    _stagedTableSource = null;
    _stagedTableProblem = null;
    notifyListeners();
  }

  List<String> _reconcile() {
    final notes = <String>[];
    final current = {for (final p in rows) p.name: p};
    for (final name in _ops.keys.toList()) {
      final op = _ops[name]!;
      final now = current[name];
      if (now == null) {
        notes.add('Dropped ${op.summary.toLowerCase()} for $name: no such partition any more');
        _ops.remove(name);
        continue;
      }
      if (now.offset == op.partition.offset && now.size == op.partition.size) continue;
      if (op.isWrite) {
        final problem = stageWrite(now, op.file!);
        if (problem != null) {
          notes.add('Dropped write for $name: $problem');
          _ops.remove(name);
        }
      } else {
        _ops[name] = PlannedOp.erase(now, warning: op.warning);
      }
    }
    return notes;
  }

  /// A warning when an app or bootloader partition is getting something
  /// that doesn't parse as an image for this chip.
  String? _imageWarning(PartitionDefinition p, Uint8List bytes) {
    if (!p.isApp && !p.isPrimaryBootloader) return null;
    final ImageMetadata image;
    try {
      image = ImageMetadata.fromBytes(bytes, appRequired: p.isApp);
    } catch (e) {
      return p.isApp ? 'Not a valid app image: $e' : 'Not a valid bootloader image: $e';
    }
    final chip = _chip;
    final imageChip = image.header.chipId;
    if (chip != null && imageChip?.value != chip.imageChipId) {
      return 'Built for ${imageChip?.name ?? 'an unknown chip'}, device is ${chip.name}';
    }
    return null;
  }

  // --------------------------------------------------------------------------
  // Bundles (python idftool's format: `<name>.bin` each + partition_table.csv)
  // --------------------------------------------------------------------------

  /// The plan as a bundle: every staged write plus the table it is planned
  /// against. Erases have no representation and are left out.
  Uint8List toBundle() {
    final archive = Archive();
    for (final op in orderedOps.where((op) => op.isWrite)) {
      archive.add(ArchiveFile.bytes('${op.partition.name}.bin', op.file!.bytes));
    }
    archive.add(ArchiveFile.string('partition_table.csv', table!.toCsv()));
    return ZipEncoder().encodeBytes(archive);
  }

  /// Stage everything in a bundle: its table, if any, then each
  /// `<name>.bin` onto the matching row. Throws [FormatException] for a bad
  /// ZIP; returns notes about entries that could not be staged.
  List<String> loadBundle(Uint8List zip, {required String source}) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(zip, verify: true);
    } catch (e) {
      throw FormatException('$source is not a valid ZIP archive: $e');
    }
    final notes = <String>[];
    final csv = archive.find('partition_table.csv');
    if (csv != null) {
      final table = PartitionTable.fromCsv(
        PartitionTable.decodeCsv(csv.readBytes()!),
        partitionTableOffset: _partitionTableOffset,
        primaryBootloaderOffset: _primaryBootloaderOffset,
      );
      notes.addAll(stageTable(table, source: '$source/partition_table.csv'));
    }
    if (table == null) {
      notes.add('No table to plan against; read the device first');
      return notes;
    }
    for (final entry in archive.files.where((f) => f.isFile && f.name.endsWith('.bin'))) {
      final name = entry.name.substring(0, entry.name.length - 4);
      final target = row(name);
      if (target == null) {
        notes.add('${entry.name}: no partition named "$name"');
        continue;
      }
      final problem = stageWrite(target, (name: entry.name, bytes: entry.readBytes()!));
      if (problem != null) notes.add('${entry.name}: $problem');
    }
    notifyListeners();
    return notes;
  }
}
