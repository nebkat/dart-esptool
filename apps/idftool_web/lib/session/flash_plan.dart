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

/// An app flashed by role rather than to a named partition — the bundle's
/// `@factory.bin` and `@ota.bin`.
enum FlashRole {
  factory('Factory', '${bundleRolePrefix}factory', 'Write the factory partition (or ota_0) and clear the OTA selection so it boots'),
  ota('OTA', '${bundleRolePrefix}ota', 'Write the next OTA slot and switch boot to it');

  const FlashRole(this.label, this.fileStem, this.description);
  final String label;

  /// The bundle filename without `.bin`.
  final String fileStem;
  final String description;
}

/// An app queued for a [FlashRole].
class PlannedRole {
  const PlannedRole(this.role, this.file, {this.warning});
  final FlashRole role;
  final PickedFile file;
  final String? warning;
  String get summary => '${role.label} flash ${file.name} (${file.bytes.length.bytesString})';
}

/// The changes queued for the connected device, in the bundle's terms:
/// optionally a replacement partition table, a bootloader, an app for
/// factory or OTA, and one write or erase per named partition. Named
/// partitions resolve against [table] — the staged table if there is one,
/// else the device's — with the bootloader and the table's own sector
/// present as virtual rows so they can be dumped and written like any
/// partition. The bootloader and the roles need no table at all.
///
/// Nothing here touches the device; the page flashes the plan.
class FlashPlan extends ChangeNotifier {
  EspChip? _chip;
  int _partitionTableOffset = PartitionTable.defaultOffset;
  int _partitionTableSize = PartitionTable.size;
  int? _primaryBootloaderOffset;

  PartitionTable? _deviceTable;
  Map<int, AppDescription> _deviceApps = const {};
  OtaDataParameters? _otadata;
  PartitionTable? _stagedTable;
  String? _stagedTableSource;
  String? _stagedTableProblem;
  final _ops = <String, PlannedOp>{};
  final _roles = <FlashRole, PlannedRole>{};

  bool _connected = false;

  /// The chip being planned for: the connected one, or the one chosen for
  /// offline planning (it fixes the bootloader offset).
  EspChip? get chip => _chip;

  /// Whether the geometry came from a connected device.
  bool get connected => _connected;

  /// Where the device's ROM looks for the bootloader, per chip.
  int? get primaryBootloaderOffset => _primaryBootloaderOffset;
  int get partitionTableOffset => _partitionTableOffset;

  /// The table last read from the device.
  PartitionTable? get deviceTable => _deviceTable;

  /// App descriptors read from the device, by partition offset.
  Map<int, AppDescription> get deviceApps => _deviceApps;

  /// The device's OTA selection, if its table has one.
  OtaDataParameters? get otadata => _otadata;

  /// A replacement table waiting to be flashed, and where it came from.
  PartitionTable? get stagedTable => _stagedTable;
  String? get stagedTableSource => _stagedTableSource;

  /// Why the staged table failed verification, if it did.
  String? get stagedTableProblem => _stagedTableProblem;

  /// The table named partitions are planned against.
  PartitionTable? get table => _stagedTable ?? _deviceTable;

  Iterable<PlannedOp> get ops => _ops.values;
  PlannedOp? opFor(String partitionName) => _ops[partitionName];
  PlannedRole? roleFor(FlashRole role) => _roles[role];
  Iterable<PlannedRole> get roles => [
        for (final r in FlashRole.values)
          if (_roles[r] != null) _roles[r]!
      ];

  bool get isEmpty => _stagedTable == null && _ops.isEmpty && _roles.isEmpty;
  int get length => _ops.length + _roles.length + (_stagedTable == null ? 0 : 1);
  int get bytesToWrite => _ops.values.fold(0, (n, op) => n + (op.file?.bytes.length ?? 0)) + _roles.values.fold(0, (n, r) => n + r.file.bytes.length);
  int get warningCount => _ops.values.where((op) => op.warning != null).length + _roles.values.where((r) => r.warning != null).length + (_stagedTableProblem == null ? 0 : 1);

  /// Named ops in [rows] order.
  List<PlannedOp> get orderedOps => [
        for (final p in rows)
          if (_ops[p.name] != null) _ops[p.name]!
      ];

  /// The bootloader write, which goes before the roles and named writes.
  PlannedOp? get bootloaderOp => _ops.values.where((op) => op.partition.isPrimaryBootloader).firstOrNull;

  /// One line saying what named partitions resolve against, and so whether
  /// a bundle of this plan carries a table or relies on the device's.
  String get addressing => _stagedTable != null
      ? 'Partitions are addressed by name against the staged table from $_stagedTableSource, which is written first and included in the bundle.'
      : _deviceTable != null
          ? "Partitions are addressed by name against the device's own table; a bundle of this plan carries no table."
          : 'No partition table yet: only the bootloader, Factory and OTA can be planned until one is read or opened.';

  /// The rows to show and address: the bootloader and partition-table
  /// sectors (virtual unless the table itself lists them) then the table.
  /// Without a table only the bootloader row exists (if the chip is known).
  List<PartitionDefinition> get rows => rowsOf(table);

  /// [table]'s rows with the virtual bootloader and partition-table entries
  /// for the current geometry, for showing any table the way [rows] is.
  List<PartitionDefinition> rowsOf(PartitionTable? table) {
    if (table == null) {
      final offset = _primaryBootloaderOffset;
      return [if (offset != null) PartitionDefinition.bootloader(offset: offset, size: _partitionTableOffset - offset)];
    }
    final r = _resolverFor(table);
    return [
      if (r.bootloaderEntry case final b? when !table.any((p) => identical(p, b))) b,
      if (!table.any((p) => identical(p, r.partitionTableEntry))) r.partitionTableEntry,
      ...table,
    ];
  }

  /// The device's rows, virtual entries included, for dumping what is there.
  List<PartitionDefinition> get deviceRows => _deviceTable == null ? const [] : rowsOf(_deviceTable);

  PartitionResolver _resolverFor(PartitionTable table) =>
      PartitionResolver.forTable(table, partitionTableOffset: _partitionTableOffset, partitionTableSize: _partitionTableSize, primaryBootloaderOffset: _primaryBootloaderOffset);

  PartitionDefinition? row(String name) => rows.where((p) => p.name == name).firstOrNull;

  /// Pick the chip for offline planning. Ignored while a device is connected.
  void setChip(EspChip? chip) {
    if (_connected) return;
    _chip = chip;
    _primaryBootloaderOffset = chip?.bootloaderFlashOffset;
    _reconcile();
    notifyListeners();
  }

  /// Called on connect with the device's geometry. A plan built offline is
  /// kept and re-checked against it; returns notes about anything dropped.
  List<String> attach({required EspChip chip, required int partitionTableOffset, required int partitionTableSize, int? primaryBootloaderOffset}) {
    _connected = true;
    _chip = chip;
    _partitionTableOffset = partitionTableOffset;
    _partitionTableSize = partitionTableSize;
    _primaryBootloaderOffset = primaryBootloaderOffset;
    _deviceTable = null;
    _deviceApps = const {};
    _otadata = null;
    final notes = _reconcile();
    notifyListeners();
    return notes;
  }

  /// Called on disconnect. A plan on a staged table survives (it can be
  /// flashed to the next device); one on the device's own table cannot.
  void detach() {
    _connected = false;
    _deviceTable = null;
    _deviceApps = const {};
    _otadata = null;
    _reconcile();
    notifyListeners();
  }

  void clear() {
    _stagedTable = null;
    _stagedTableSource = null;
    _stagedTableProblem = null;
    _ops.clear();
    _roles.clear();
    notifyListeners();
  }

  /// Record the table read from the device. Ops are re-checked against it
  /// unless a staged table is what they are planned on. Returns notes about
  /// anything dropped.
  List<String> setDeviceTable(PartitionTable table, {Map<int, AppDescription> apps = const {}, OtaDataParameters? otadata}) {
    _deviceTable = table;
    _deviceApps = apps;
    _otadata = otadata;
    final notes = _stagedTable == null ? _reconcile() : const <String>[];
    notifyListeners();
    return notes;
  }

  // --------------------------------------------------------------------------
  // Staging
  // --------------------------------------------------------------------------

  /// Named writes or erases that would collide with the roles, or with a
  /// role about to be added ([plusRole]).
  List<String> _conflicts({Iterable<String>? names, FlashRole? plusRole}) {
    final t = table;
    if (t == null) return const [];
    return bundleConflicts(
      table: t,
      namedPartitions: names ?? _ops.keys,
      hasFactory: _roles.containsKey(FlashRole.factory) || plusRole == FlashRole.factory,
      hasOta: _roles.containsKey(FlashRole.ota) || plusRole == FlashRole.ota,
    );
  }

  /// Queue [file] for [p]. Returns a message if it can't be, else `null`;
  /// a write that goes through may carry a warning.
  String? stageWrite(PartitionDefinition p, PickedFile file) {
    if (p.isPrimaryPartitionTable) return 'Use "Replace table" to stage a new partition table';
    if (file.bytes.isEmpty) return '${file.name} is empty';
    if (file.bytes.length > p.size) {
      return '${file.name} (${file.bytes.length.bytesString}) does not fit in ${p.name} (${p.size.bytesString})';
    }
    if (_conflicts(names: [p.name]) case [final problem, ...]) return problem;
    _ops[p.name] = PlannedOp.write(p, file, warning: _imageWarning(p, file.bytes));
    notifyListeners();
    return null;
  }

  String? stageErase(PartitionDefinition p) {
    if (p.isPrimaryPartitionTable) return 'The partition table sector is replaced, not erased';
    if (_conflicts(names: [p.name]) case [final problem, ...]) return problem;
    _ops[p.name] = PlannedOp.erase(p, warning: p.isPrimaryBootloader ? 'The device will not boot until a bootloader is written' : null);
    notifyListeners();
    return null;
  }

  void unstage(String partitionName) {
    if (_ops.remove(partitionName) != null) notifyListeners();
  }

  /// Queue [file] as the app for [role]. Returns a message if it can't be.
  String? stageRole(FlashRole role, PickedFile file) {
    if (file.bytes.isEmpty) return '${file.name} is empty';
    final other = role == FlashRole.factory ? FlashRole.ota : FlashRole.factory;
    if (_roles.containsKey(other)) return 'A plan cannot have both a Factory and an OTA flash';
    if (_conflicts(plusRole: role) case [final problem, ...]) return problem;
    _roles[role] = PlannedRole(role, file, warning: _appWarning(file.bytes));
    notifyListeners();
    return null;
  }

  void unstageRole(FlashRole role) {
    if (_roles.remove(role) != null) notifyListeners();
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
      // Re-stage against the current row: geometry may have changed, and a
      // write's image warning depends on the chip.
      _ops.remove(name);
      final problem = op.isWrite ? stageWrite(now, op.file!) : stageErase(now);
      if (problem != null) notes.add('Dropped ${op.summary.toLowerCase()} for $name: $problem');
    }
    for (final r in _roles.values.toList()) {
      _roles[r.role] = PlannedRole(r.role, r.file, warning: _appWarning(r.file.bytes));
    }
    return notes;
  }

  /// A warning when an app or bootloader partition is getting something
  /// that doesn't parse as an image for this chip.
  String? _imageWarning(PartitionDefinition p, Uint8List bytes) {
    if (!p.isApp && !p.isPrimaryBootloader) return null;
    return p.isApp ? _appWarning(bytes) : _chipWarning(bytes, appRequired: false, what: 'bootloader image');
  }

  String? _appWarning(Uint8List bytes) => _chipWarning(bytes, appRequired: true, what: 'app image');

  String? _chipWarning(Uint8List bytes, {required bool appRequired, required String what}) {
    final ImageMetadata image;
    try {
      image = ImageMetadata.fromBytes(bytes, appRequired: appRequired);
    } catch (e) {
      return 'Not a valid $what: $e';
    }
    final chip = _chip;
    final imageChip = image.header.chipId;
    if (chip != null && imageChip?.value != chip.imageChipId) {
      return 'Built for ${imageChip?.name ?? 'an unknown chip'}, device is ${chip.name}';
    }
    return null;
  }

  // --------------------------------------------------------------------------
  // Bundles
  // --------------------------------------------------------------------------

  /// The plan as a bundle, by the filename convention: the table only when
  /// staged, `bootloader.bin`, `@factory.bin` / `@ota.bin`, `<name>.bin`.
  /// Erases have no representation and are left out.
  Uint8List toBundle() => encodeBundle(
        table: _stagedTable,
        bootloader: bootloaderOp?.file?.bytes,
        factoryApp: _roles[FlashRole.factory]?.file.bytes,
        otaApp: _roles[FlashRole.ota]?.file.bytes,
        partitions: {
          for (final op in orderedOps)
            if (op.isWrite && !op.partition.isPrimaryBootloader) op.partition.name: op.file!.bytes,
        },
      );

  /// Stage everything in a bundle: its table, bootloader, role files and
  /// named writes. Throws [IdfToolException] for a bad bundle; returns
  /// notes about entries that could not be staged.
  List<String> loadBundle(Uint8List zip, {required String source}) {
    final bundle = readBundle(zip, partitionTableOffset: _partitionTableOffset, primaryBootloaderOffset: _primaryBootloaderOffset);
    final notes = <String>[];
    if (bundle.table case final t?) notes.addAll(stageTable(t, source: '$source/${bundle.tableFile}'));
    if (bundle.bootloader case final b?) {
      final row = rows.where((p) => p.isPrimaryBootloader).firstOrNull;
      if (row == null) {
        notes.add('bootloader.bin: the bootloader offset is unknown until a chip is picked or connected');
      } else if (stageWrite(row, (name: 'bootloader.bin', bytes: b)) case final problem?) {
        notes.add('bootloader.bin: $problem');
      }
    }
    for (final (role, bytes) in [(FlashRole.factory, bundle.factoryApp), (FlashRole.ota, bundle.otaApp)]) {
      if (bytes == null) continue;
      if (stageRole(role, (name: '${role.fileStem}.bin', bytes: bytes)) case final problem?) notes.add('${role.fileStem}.bin: $problem');
    }
    if (bundle.partitions.isNotEmpty && table == null) {
      notes.add('${bundle.partitions.length} named partition file(s) skipped: this bundle carries no table and none has been read from a device');
    } else {
      for (final MapEntry(key: name, value: bytes) in bundle.partitions.entries) {
        final target = row(name);
        if (target == null) {
          notes.add('$name.bin: no partition named "$name"');
          continue;
        }
        if (stageWrite(target, (name: '$name.bin', bytes: bytes)) case final problem?) notes.add('$name.bin: $problem');
      }
    }
    if (bundle.manifest case final m?) {
      notes.add('manifest.json (${m.name}, ${m.steps.length} step(s)) is not applied here; use the one-click page for manifest bundles');
    }
    for (final f in bundle.ignored) {
      notes.add('$f: ignored');
    }
    notifyListeners();
    return notes;
  }
}
