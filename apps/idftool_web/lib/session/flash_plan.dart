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

/// How the app file is flashed — the bundle's `@factory.bin` / `@ota.bin`.
enum FlashRole {
  factory('Factory', '${bundleRolePrefix}factory', 'the factory partition (or ota_0), then clear the OTA selection so it boots'),
  ota('OTA', '${bundleRolePrefix}ota', 'the next OTA slot, then switch boot to it');

  const FlashRole(this.label, this.fileStem, this.description);
  final String label;

  /// The bundle filename without `.bin`.
  final String fileStem;
  final String description;
}

/// Where the partition table being planned against comes from.
enum TableSource { device, file }

/// Whether that table is written too, or only names the partitions.
enum TableUse { reference, flash }

/// The changes queued for a device, in the bundle's terms: a partition
/// table (the device's or a file's, flashed or reference only), a
/// bootloader, one app flashed by role, and a write or erase per named
/// partition. Named partitions resolve against [table]; the bootloader and
/// the app need no table at all.
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

  PartitionTable? _fileTable;
  String? _fileTableSource;
  String? _fileTableProblem;
  TableSource _tableSource = TableSource.device;
  TableUse _tableUse = TableUse.reference;

  final _ops = <String, PlannedOp>{};
  FlashRole _appRole = FlashRole.ota;
  PickedFile? _app;
  String? _appWarningText;

  bool _connected = false;

  // --------------------------------------------------------------------------
  // Geometry and device
  // --------------------------------------------------------------------------

  /// The chip being planned for: the connected one, or the one chosen for
  /// offline planning (it fixes the bootloader offset).
  EspChip? get chip => _chip;
  bool get connected => _connected;
  int? get primaryBootloaderOffset => _primaryBootloaderOffset;
  int get partitionTableOffset => _partitionTableOffset;

  PartitionTable? get deviceTable => _deviceTable;
  Map<int, AppDescription> get deviceApps => _deviceApps;
  OtaDataParameters? get otadata => _otadata;

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

  /// Called on disconnect. A plan on a file's table survives; one on the
  /// device's own table loses its named ops.
  void detach() {
    _connected = false;
    _deviceTable = null;
    _deviceApps = const {};
    _otadata = null;
    _reconcile();
    notifyListeners();
  }

  /// Record the table read from the device; ops planned on it are re-checked.
  List<String> setDeviceTable(PartitionTable table, {Map<int, AppDescription> apps = const {}, OtaDataParameters? otadata}) {
    _deviceTable = table;
    _deviceApps = apps;
    _otadata = otadata;
    final notes = _tableSource == TableSource.device ? _reconcile() : const <String>[];
    notifyListeners();
    return notes;
  }

  // --------------------------------------------------------------------------
  // Partition table
  // --------------------------------------------------------------------------

  TableSource get tableSource => _tableSource;
  TableUse get tableUse => _tableUse;

  /// The table opened from a file, whether or not it is the source in use.
  PartitionTable? get fileTable => _fileTable;
  String? get fileTableSource => _fileTableSource;

  /// Why the file's table failed verification, if it did.
  String? get fileTableProblem => _fileTableProblem;

  /// The table named partitions are planned against.
  PartitionTable? get table => _tableSource == TableSource.file ? _fileTable : _deviceTable;

  /// The table that will be written and put in the bundle, if any.
  PartitionTable? get stagedTable => _tableUse == TableUse.flash ? table : null;
  String? get stagedTableSource => _tableSource == TableSource.file ? _fileTableSource : "the device's own table";
  String? get stagedTableProblem => _tableSource == TableSource.file ? _fileTableProblem : null;

  /// Show [table] from a file; the use is unchanged.
  List<String> openTableFile(PartitionTable table, {required String source}) {
    _fileTable = table;
    _fileTableSource = source;
    _fileTableProblem = null;
    try {
      table.verify(partitionTableOffset: _partitionTableOffset);
    } catch (e) {
      _fileTableProblem = '$e';
    }
    _tableSource = TableSource.file;
    final notes = _reconcile();
    notifyListeners();
    return notes;
  }

  /// Plan on a file's table and flash it (what a bundle with a table means).
  List<String> stageTable(PartitionTable table, {required String source}) {
    _tableUse = TableUse.flash;
    return openTableFile(table, source: source);
  }

  List<String> setTableSource(TableSource source) {
    if (source == TableSource.file && _fileTable == null) return const [];
    _tableSource = source;
    final notes = _reconcile();
    notifyListeners();
    return notes;
  }

  void setTableUse(TableUse use) {
    _tableUse = use;
    notifyListeners();
  }

  /// Forget the file's table and go back to the device's as reference.
  List<String> closeTableFile() {
    _fileTable = null;
    _fileTableSource = null;
    _fileTableProblem = null;
    _tableSource = TableSource.device;
    _tableUse = TableUse.reference;
    final notes = _reconcile();
    notifyListeners();
    return notes;
  }

  /// The staged table is now on the device.
  void tableFlashed() {
    _deviceTable = stagedTable ?? _deviceTable;
    _tableUse = TableUse.reference;
    notifyListeners();
  }

  /// One line saying what named partitions resolve against, and so whether
  /// a bundle of this plan carries a table or relies on the device's.
  String get addressing {
    if (table == null) return 'No partition table: only the bootloader and the app can be planned until one is read from a device or opened.';
    final from = _tableSource == TableSource.file ? 'the table from $_fileTableSource' : "the device's table";
    return _tableUse == TableUse.flash
        ? 'Partitions are named against $from, which is written first and included in the bundle.'
        : 'Partitions are named against $from for reference only; a bundle of this plan carries no table and needs a device with these names.';
  }

  // --------------------------------------------------------------------------
  // Rows
  // --------------------------------------------------------------------------

  /// The real partitions of [table], excluding any bootloader or
  /// partition-table rows it lists (those have boxes of their own).
  List<PartitionDefinition> get partitionRows => [
        for (final p in table ?? const <PartitionDefinition>[])
          if (!p.isPrimaryBootloader && !p.isPrimaryPartitionTable) p
      ];

  /// The virtual bootloader row for the current chip, if known.
  PartitionDefinition? get bootloaderRow {
    final offset = _primaryBootloaderOffset;
    return offset == null ? null : PartitionDefinition.bootloader(offset: offset, size: _partitionTableOffset - offset);
  }

  /// Every addressable row: bootloader, then the table's partitions.
  List<PartitionDefinition> get rows => [if (bootloaderRow case final b?) b, ...partitionRows];

  /// [table]'s rows with the virtual bootloader and partition-table entries
  /// for the current geometry (what the device's layout looks like).
  List<PartitionDefinition> rowsOf(PartitionTable? table) {
    if (table == null) return const [];
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

  // --------------------------------------------------------------------------
  // App
  // --------------------------------------------------------------------------

  FlashRole get appRole => _appRole;
  PickedFile? get app => _app;
  String? get appWarning => _appWarningText;

  /// Where the app will land: the factory partition, or the OTA slot the
  /// device would pick next (unknown until connected).
  String? get appTarget {
    final t = table;
    if (t == null) return null;
    switch (_appRole) {
      case FlashRole.factory:
        return factoryTarget(t)?.name;
      case FlashRole.ota:
        final next = _otadata?.nextSlot;
        if (next == null || _tableSource == TableSource.file) return null;
        return t.findByType(PartitionType.app, AppSubtype.otaMin + next).firstOrNull?.name;
    }
  }

  /// Whether the app, once staged, owns [p]: named writes there are
  /// disabled and handled by the app.
  bool ownedByApp(PartitionDefinition p) {
    if (_app == null) return false;
    final t = table;
    return switch (_appRole) {
      FlashRole.factory => t != null && factoryTarget(t)?.name == p.name,
      FlashRole.ota => p.isOtaApp,
    };
  }

  /// Queue [file] as the app. Named ops on partitions the app now owns are
  /// dropped; the returned notes say which. An empty file is refused.
  ({String? problem, List<String> dropped}) stageApp(PickedFile file) {
    if (file.bytes.isEmpty) return (problem: '${file.name} is empty', dropped: const []);
    _app = file;
    _appWarningText = _chipWarning(file.bytes, appRequired: true, what: 'app image');
    final dropped = _dropOwned();
    notifyListeners();
    return (problem: null, dropped: dropped);
  }

  List<String> setAppRole(FlashRole role) {
    _appRole = role;
    final dropped = _dropOwned();
    notifyListeners();
    return dropped;
  }

  void unstageApp() {
    if (_app == null) return;
    _app = null;
    _appWarningText = null;
    notifyListeners();
  }

  List<String> _dropOwned() {
    final dropped = <String>[];
    for (final name in _ops.keys.toList()) {
      if (ownedByApp(_ops[name]!.partition)) {
        dropped.add('Dropped ${_ops[name]!.summary.toLowerCase()} for $name: handled by the ${_appRole.label} app');
        _ops.remove(name);
      }
    }
    return dropped;
  }

  // --------------------------------------------------------------------------
  // Bootloader and named partitions
  // --------------------------------------------------------------------------

  PlannedOp? get bootloaderOp => bootloaderRow == null ? null : _ops[bootloaderRow!.name];

  String? stageBootloader(PickedFile file) {
    final row = bootloaderRow;
    if (row == null) return 'Pick a chip first: the bootloader offset depends on it';
    return stageWrite(row, file);
  }

  Iterable<PlannedOp> get ops => _ops.values;
  PlannedOp? opFor(String partitionName) => _ops[partitionName];

  /// Named ops in [partitionRows] order (the bootloader is separate).
  List<PlannedOp> get orderedOps => [
        for (final p in partitionRows)
          if (_ops[p.name] != null) _ops[p.name]!
      ];

  /// Queue [file] for [p]. Returns a message if it can't be, else `null`;
  /// a write that goes through may carry a warning.
  String? stageWrite(PartitionDefinition p, PickedFile file) {
    if (file.bytes.isEmpty) return '${file.name} is empty';
    if (file.bytes.length > p.size) {
      return '${file.name} (${file.bytes.length.bytesString}) does not fit in ${p.name} (${p.size.bytesString})';
    }
    if (ownedByApp(p)) return '${p.name} is handled by the ${_appRole.label} app';
    _ops[p.name] = PlannedOp.write(p, file, warning: _imageWarning(p, file.bytes));
    notifyListeners();
    return null;
  }

  String? stageErase(PartitionDefinition p) {
    if (ownedByApp(p)) return '${p.name} is handled by the ${_appRole.label} app';
    _ops[p.name] = PlannedOp.erase(p, warning: p.isPrimaryBootloader ? 'The device will not boot until a bootloader is written' : null);
    notifyListeners();
    return null;
  }

  void unstage(String partitionName) {
    if (_ops.remove(partitionName) != null) notifyListeners();
  }

  // --------------------------------------------------------------------------
  // Whole plan
  // --------------------------------------------------------------------------

  bool get isEmpty => stagedTable == null && _ops.isEmpty && _app == null;
  int get length => _ops.length + (_app == null ? 0 : 1) + (stagedTable == null ? 0 : 1);
  int get bytesToWrite => _ops.values.fold(0, (n, op) => n + (op.file?.bytes.length ?? 0)) + (_app?.bytes.length ?? 0);
  int get warningCount => _ops.values.where((op) => op.warning != null).length + (_appWarningText == null ? 0 : 1) + (stagedTableProblem == null ? 0 : 1);

  void clear() {
    _ops.clear();
    _app = null;
    _appWarningText = null;
    _tableUse = TableUse.reference;
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
    if (_app case final app?) _appWarningText = _chipWarning(app.bytes, appRequired: true, what: 'app image');
    return notes;
  }

  String? _imageWarning(PartitionDefinition p, Uint8List bytes) {
    if (!p.isApp && !p.isPrimaryBootloader) return null;
    return _chipWarning(bytes, appRequired: p.isApp, what: p.isApp ? 'app image' : 'bootloader image');
  }

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

  /// The plan as a bundle by the filename convention: the table only when
  /// flashed, `bootloader.bin`, `@factory.bin` / `@ota.bin`, `<name>.bin`.
  /// Erases have no representation and are left out.
  Uint8List toBundle() => encodeBundle(
        table: stagedTable,
        bootloader: bootloaderOp?.file?.bytes,
        factoryApp: _appRole == FlashRole.factory ? _app?.bytes : null,
        otaApp: _appRole == FlashRole.ota ? _app?.bytes : null,
        partitions: {
          for (final op in orderedOps)
            if (op.isWrite) op.partition.name: op.file!.bytes,
        },
      );

  /// Stage everything in a bundle. Throws [IdfToolException] for a bad
  /// bundle; returns notes about entries that could not be staged.
  List<String> loadBundle(Uint8List zip, {required String source}) {
    final bundle = readBundle(zip, partitionTableOffset: _partitionTableOffset, primaryBootloaderOffset: _primaryBootloaderOffset);
    final notes = <String>[];
    if (bundle.table case final t?) notes.addAll(stageTable(t, source: '$source/${bundle.tableFile}'));
    if (bundle.bootloader case final b?) {
      if (stageBootloader((name: 'bootloader.bin', bytes: b)) case final problem?) notes.add('bootloader.bin: $problem');
    }
    for (final (role, bytes) in [(FlashRole.factory, bundle.factoryApp), (FlashRole.ota, bundle.otaApp)]) {
      if (bytes == null) continue;
      notes.addAll(setAppRole(role));
      final r = stageApp((name: '${role.fileStem}.bin', bytes: bytes));
      if (r.problem case final problem?) notes.add('${role.fileStem}.bin: $problem');
      notes.addAll(r.dropped);
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
