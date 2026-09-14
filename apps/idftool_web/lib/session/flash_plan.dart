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

/// Values to set or delete in an NVS partition, in the manifest's terms:
/// `ns:key` → `type:value` to set, `ns:key` to delete.
class NvsPlan {
  NvsPlan(this.partition, {Map<String, String>? set, List<String>? delete})
      : set = set ?? {},
        delete = delete ?? [];
  final String partition;
  final Map<String, String> set;
  final List<String> delete;

  bool get isEmpty => set.isEmpty && delete.isEmpty;
  int get length => set.length + delete.length;

  List<NvsEdit> get edits => [
        for (final e in set.entries) parseNvsSetSpec('${e.key}=${e.value}'),
        for (final d in delete) parseNvsDeleteSpec(d),
      ];

  String get summary => [
        for (final e in set.entries) 'Set ${e.key} = ${e.value}',
        for (final d in delete) 'Delete $d',
      ].join(', ');

  /// The manifest's `type:value` for an edit from the entry dialog.
  static String spec(NvsEdit edit) => '${edit.type!.label}:${formatNvsValue(edit.value!)}';
}

/// Files to put or delete in a filesystem partition.
class FsPlan {
  FsPlan(this.partition, {Map<String, PickedFile>? put, List<String>? delete})
      : put = put ?? {},
        delete = delete ?? [];
  final String partition;

  /// Path in the filesystem → the file to put there.
  final Map<String, PickedFile> put;
  final List<String> delete;

  bool get isEmpty => put.isEmpty && delete.isEmpty;
  int get length => put.length + delete.length;
  int get bytes => put.values.fold(0, (n, f) => n + f.bytes.length);

  String get summary => [
        for (final e in put.entries) 'Put ${e.key} (${e.value.bytes.length.bytesString})',
        for (final d in delete) 'Delete $d',
      ].join(', ');

  /// Where a put file lives in the bundle.
  String bundlePath(String path) => 'files/$partition/${path.replaceAll(RegExp(r'^/+'), '')}';
}

/// A write to a partition named by hand (or by its file's name) while no
/// table says whether it exists: the bundle's `<name>.bin` with nothing to
/// check it against. Resolved into a [PlannedOp] as soon as a table has
/// the name; kept, with a warning, when it does not.
class ManualWrite {
  const ManualWrite(this.name, this.file, {this.warning});
  final String name;
  final PickedFile file;
  final String? warning;
  String get summary => 'Write ${file.name} (${file.bytes.length.bytesString})';
}

/// Where the partition table being planned against comes from. [device]
/// with nothing connected (or read) plans by name alone, for a bundle or
/// a device not connected yet; the names line up when one is.
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
  final _manual = <ManualWrite>[];
  FlashRole _appRole = FlashRole.ota;
  PickedFile? _app;
  String? _appWarningText;

  String? _bundleName;
  String? _bundleDescription;

  final _nvs = <String, NvsPlan>{};
  final _fs = <String, FsPlan>{};

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

  /// Called on disconnect. A plan on a file's table survives as it is; one
  /// on the device's own table keeps its writes by name (erases are
  /// dropped) and goes on without a table.
  void detach() {
    _connected = false;
    _deviceTable = null;
    _deviceApps = const {};
    _otadata = null;
    if (_tableSource == TableSource.device) {
      for (final op in _ops.values.toList()) {
        if (op.partition.isPrimaryBootloader) continue;
        if (op.isWrite) _manual.add(ManualWrite(op.partition.name, op.file!));
        _ops.remove(op.partition.name);
      }
    }
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

  /// The table named partitions are planned against (`null` under [TableSource.none]).
  PartitionTable? get table => _tableSource == TableSource.file ? _fileTable : _deviceTable;

  /// Planning by name alone: the device is the source but there is no
  /// table from it (nothing connected, or not read).
  bool get byName => _tableSource == TableSource.device && _deviceTable == null;

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
    if (table == null) _tableUse = TableUse.reference;
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
    if (byName) {
      return "Partitions are named freely (a file's name by default) and checked against the device's table when flashing; a bundle of this plan carries no table.";
    }
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
  // NVS values and filesystem files
  // --------------------------------------------------------------------------

  /// Value edits by partition, in [partitionRows] order (unknown names last).
  List<NvsPlan> get nvsPlans => _ordered(_nvs);
  List<FsPlan> get fsPlans => _ordered(_fs);
  NvsPlan? nvsPlanFor(String partition) => _nvs[partition];
  FsPlan? fsPlanFor(String partition) => _fs[partition];

  List<T> _ordered<T>(Map<String, T> byName) {
    final order = [for (final p in partitionRows) p.name];
    final names = byName.keys.toList()
      ..sort((a, b) {
        final ia = order.indexOf(a), ib = order.indexOf(b);
        return (ia < 0 ? order.length : ia).compareTo(ib < 0 ? order.length : ib);
      });
    return [for (final n in names) byName[n]!];
  }

  /// Queue a value to set. A pending delete of the same key is dropped.
  void stageNvsSet(String partition, String qualified, String spec) {
    final plan = _nvs.putIfAbsent(partition, () => NvsPlan(partition));
    plan.delete.remove(qualified);
    plan.set[qualified] = spec;
    notifyListeners();
  }

  void stageNvsDelete(String partition, String qualified) {
    final plan = _nvs.putIfAbsent(partition, () => NvsPlan(partition));
    plan.set.remove(qualified);
    if (!plan.delete.contains(qualified)) plan.delete.add(qualified);
    notifyListeners();
  }

  void unstageNvs(String partition, String qualified) {
    final plan = _nvs[partition];
    if (plan == null) return;
    plan.set.remove(qualified);
    plan.delete.remove(qualified);
    if (plan.isEmpty) _nvs.remove(partition);
    notifyListeners();
  }

  void unstageNvsAll(String partition) {
    if (_nvs.remove(partition) != null) notifyListeners();
  }

  String? stageFsPut(String partition, String path, PickedFile file) {
    final n = path.trim().replaceAll(RegExp(r'^/+'), '');
    if (n.isEmpty) return 'A path is needed';
    final plan = _fs.putIfAbsent(partition, () => FsPlan(partition));
    plan.delete.remove(n);
    plan.put[n] = file;
    notifyListeners();
    return null;
  }

  String? stageFsDelete(String partition, String path) {
    final n = path.trim().replaceAll(RegExp(r'^/+'), '');
    if (n.isEmpty) return 'A path is needed';
    final plan = _fs.putIfAbsent(partition, () => FsPlan(partition));
    plan.put.remove(n);
    if (!plan.delete.contains(n)) plan.delete.add(n);
    notifyListeners();
    return null;
  }

  void unstageFs(String partition, String path) {
    final plan = _fs[partition];
    if (plan == null) return;
    plan.put.remove(path);
    plan.delete.remove(path);
    if (plan.isEmpty) _fs.remove(partition);
    notifyListeners();
  }

  void unstageFsAll(String partition) {
    if (_fs.remove(partition) != null) notifyListeners();
  }

  // --------------------------------------------------------------------------
  // Writes by name alone
  // --------------------------------------------------------------------------

  /// Writes waiting for a table with their name (all of them while
  /// [byName]; the unmatched ones otherwise).
  List<ManualWrite> get manual => List.unmodifiable(_manual);

  /// Queue [file] for the partition called [name] (the file's stem by
  /// default). With a table that has the name it becomes a normal write.
  String? stageManual(PickedFile file, {String? name}) {
    if (file.bytes.isEmpty) return '${file.name} is empty';
    final n = (name ?? _stem(file.name)).trim();
    if (n.isEmpty) return 'A partition name is needed';
    if (n.startsWith(bundleRolePrefix)) return "Partition names cannot start with '$bundleRolePrefix'";
    _manual.removeWhere((m) => m.name == n);
    _manual.add(ManualWrite(n, file));
    _reconcile();
    notifyListeners();
    return null;
  }

  String? renameManual(int index, String name) {
    final n = name.trim();
    if (n.isEmpty) return 'A partition name is needed';
    if (n.startsWith(bundleRolePrefix)) return "Partition names cannot start with '$bundleRolePrefix'";
    if (_manual.indexWhere((m) => m.name == n) case final other when other >= 0 && other != index) return "'$n' is already planned";
    _manual[index] = ManualWrite(n, _manual[index].file);
    _reconcile();
    notifyListeners();
    return null;
  }

  void unstageManual(int index) {
    _manual.removeAt(index);
    notifyListeners();
  }

  static String _stem(String fileName) => fileName.contains('.') ? fileName.substring(0, fileName.lastIndexOf('.')) : fileName;

  // --------------------------------------------------------------------------
  // Whole plan
  // --------------------------------------------------------------------------

  bool get isEmpty => stagedTable == null && _ops.isEmpty && _manual.isEmpty && _app == null && _nvs.isEmpty && _fs.isEmpty;
  int get length => _ops.length + _manual.length + (_app == null ? 0 : 1) + (stagedTable == null ? 0 : 1) + _nvs.length + _fs.length;
  int get bytesToWrite =>
      _ops.values.fold<int>(0, (n, op) => n + (op.file?.bytes.length ?? 0)) +
      _manual.fold<int>(0, (n, m) => n + m.file.bytes.length) +
      (_app?.bytes.length ?? 0) +
      _fs.values.fold<int>(0, (n, f) => n + f.bytes);
  int get warningCount =>
      _ops.values.where((op) => op.warning != null).length +
      _manual.where((m) => m.warning != null).length +
      (_appWarningText == null ? 0 : 1) +
      (stagedTableProblem == null ? 0 : 1);

  void clear() {
    _ops.clear();
    _manual.clear();
    _app = null;
    _appWarningText = null;
    _tableUse = TableUse.reference;
    _bundleName = null;
    _bundleDescription = null;
    _nvs.clear();
    _fs.clear();
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
    // Writes by name: resolve the ones the table has, warn about the rest.
    final t = table;
    for (var i = 0; i < _manual.length; i++) {
      final m = _manual[i];
      if (t == null) {
        _manual[i] = ManualWrite(m.name, m.file);
        continue;
      }
      final p = current[m.name];
      if (p == null || p.isPrimaryBootloader) {
        _manual[i] = ManualWrite(m.name, m.file, warning: "No partition named '${m.name}' in this table; it will be skipped when flashing");
        continue;
      }
      final problem = stageWrite(p, m.file);
      if (problem == null) {
        _manual.removeAt(i--);
      } else {
        _manual[i] = ManualWrite(m.name, m.file, warning: problem);
      }
    }
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

  /// What the bundle's manifest says about it: kept from the last bundle
  /// opened or saved, so a plan round-trips with its name.
  String? get bundleName => _bundleName;
  String? get bundleDescription => _bundleDescription;

  void setBundleInfo({String? name, String? description}) {
    _bundleName = (name ?? '').trim().isEmpty ? null : name!.trim();
    _bundleDescription = (description ?? '').trim().isEmpty ? null : description!.trim();
    notifyListeners();
  }

  /// The erases, which only a manifest can carry.
  List<PlannedOp> get erases => [for (final op in orderedOps) if (!op.isWrite) op];

  /// The manifest a bundle of this plan needs, or `null` when the files say
  /// it all: name, description, the chip planned for, and as ops the
  /// erases, value edits and file edits.
  FlashManifest? get manifest {
    final ops = <FlashStep>[
      for (final op in erases) EraseStep(op.partition.name),
      for (final n in nvsPlans) SetNvsStep(partition: n.partition, set: Map.of(n.set), delete: List.of(n.delete)),
      for (final f in fsPlans) EditFsStep(f.partition, put: {for (final path in f.put.keys) path: f.bundlePath(path)}, delete: List.of(f.delete)),
    ];
    if (_bundleName == null && _bundleDescription == null && _chip == null && ops.isEmpty) return null;
    return FlashManifest(name: _bundleName, description: _bundleDescription, chip: _chip, ops: ops);
  }

  /// The plan as a bundle by the filename convention: the table only when
  /// flashed, `bootloader.bin`, `@factory.bin` / `@ota.bin`, `<name>.bin`,
  /// and a `manifest.json` when there is anything to say (see [manifest]).
  Uint8List toBundle() => encodeBundle(
        table: stagedTable,
        bootloader: bootloaderOp?.file?.bytes,
        factoryApp: _appRole == FlashRole.factory ? _app?.bytes : null,
        otaApp: _appRole == FlashRole.ota ? _app?.bytes : null,
        partitions: {
          for (final op in orderedOps)
            if (op.isWrite) op.partition.name: op.file!.bytes,
          for (final m in _manual) m.name: m.file.bytes,
        },
        manifest: manifest,
        files: {
          for (final f in fsPlans)
            for (final MapEntry(key: path, value: file) in f.put.entries) f.bundlePath(path): file.bytes,
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
    for (final MapEntry(key: name, value: bytes) in bundle.partitions.entries) {
      if (stageManual((name: '$name.bin', bytes: bytes), name: name) case final problem?) notes.add('$name.bin: $problem');
    }
    if (bundle.manifest case final m?) {
      _bundleName = m.name;
      _bundleDescription = m.description;
      if (m.isRecipe) {
        notes.add('manifest.json is a recipe of ${m.steps.length} step(s), which is not applied here; the one-click page runs it');
      }
      for (final op in m.ops) {
        switch (op) {
          case EraseStep(:final partition):
            final p = row(partition);
            final problem = p == null ? "no partition named '$partition' in this table" : stageErase(p);
            if (problem != null) notes.add('manifest.json: erase $partition skipped: $problem');
          case SetNvsStep(:final partition, :final set, :final delete):
            final name = partition ?? table?.where((p) => p.isData && p.subtype == DataSubtype.nvs.value).firstOrNull?.name ?? 'nvs';
            set.forEach((k, v) => stageNvsSet(name, k, v));
            for (final d in delete) {
              stageNvsDelete(name, d);
            }
          case EditFsStep(:final partition, :final put, :final delete):
            for (final MapEntry(key: path, value: file) in put.entries) {
              final data = bundle.files[file];
              if (data == null) {
                notes.add("manifest.json: put $path in $partition skipped: '$file' is not in the bundle");
                continue;
              }
              stageFsPut(partition, path, (name: file.split('/').last, bytes: data));
            }
            for (final d in delete) {
              stageFsDelete(partition, d);
            }
          default:
            notes.add("manifest.json: '${op.op}' is not applied here; the one-click page runs it");
        }
      }
    }
    for (final f in bundle.ignored) {
      notes.add('$f: ignored');
    }
    notifyListeners();
    return notes;
  }
}
