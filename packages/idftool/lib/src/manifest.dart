import 'dart:typed_data';

import 'package:esptool/esptool.dart';

import 'bundle.dart';
import 'device.dart';
import 'flash/differential.dart';
import 'nvs/nvs.dart';
import 'partition_table.dart';
import 'partition_table_files.dart';

/// The optional `manifest.json` of a bundle: a name, description and target
/// chip, plus what the filename convention (see `bundle.dart`) cannot say.
///
/// Two forms. The current one is extras: an `ops` list run after the
/// file operations the bundle's names imply.
///
/// ```json
/// {
///   "name": "MS5 v0.17.0",
///   "description": "Field update: new app, reset the channel",
///   "chip": "esp32s3",
///   "ops": [
///     {"op": "set-nvs", "partition": "nvs_cfg", "set": {"cfg:channel": "string:stable"}},
///     {"op": "clear-boot"}
///   ]
/// }
/// ```
///
/// The older one is a recipe: a `steps` list that is the whole sequence,
/// naming its files explicitly, with nothing derived from filenames. It
/// keeps loading. A manifest cannot carry both.
///
/// Ops map onto [IdfDevice]: `write-bundle` (every `<partition>.bin` in the
/// ZIP plus `partition_table.csv` if present), `factory`/`ota` (`file`),
/// `write-table` (`file`), `write-bootloader` (`file`), `write`
/// (`partition`, `file`), `erase` (`partition`), `set-nvs` (`partition`,
/// `set` map of `ns:key` → `type:value`, `delete` list of `ns:key`),
/// `write-fs` (`partition`, `file`), `edit-fs` (`partition`, `put` map of
/// path in the filesystem → file in the bundle, `delete` list of paths),
/// `set-boot` (`partition`), `clear-boot`. The same ZIP is what the python single-use executables
/// consume.
class FlashManifest {
  const FlashManifest({this.name, this.description, this.chip, this.steps = const [], this.ops = const []});

  final String? name;
  final String? description;

  /// The chip the bundle targets (e.g. `esp32s3`); checked against the
  /// connected device before anything is written. `null` skips the check.
  final EspChip? chip;

  /// The recipe form: the whole sequence. Empty for an extras manifest.
  final List<FlashStep> steps;

  /// The extras form: run after the file operations. Empty for a recipe.
  final List<FlashStep> ops;

  /// Whether this is the recipe form, which replaces the filename convention.
  bool get isRecipe => steps.isNotEmpty;

  static const fileName = 'manifest.json';

  factory FlashManifest.fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    if (name != null && (name is! String || name.isEmpty)) throw IdfToolException('manifest.json: "name" must be a non-empty string');
    final chipName = json['chip'];
    EspChip? chip;
    if (chipName != null) {
      if (chipName is! String) throw IdfToolException('manifest.json: "chip" must be a string');
      chip = EspChip.values.where((c) => c.name.toLowerCase().replaceAll('-', '') == chipName.toLowerCase().replaceAll('-', '')).firstOrNull;
      if (chip == null) throw IdfToolException("manifest.json: unknown chip '$chipName'");
    }
    final steps = _steps(json, 'steps', 'step');
    final ops = _steps(json, 'ops', 'op');
    if (steps.isNotEmpty && ops.isNotEmpty) throw IdfToolException('manifest.json: "steps" (a recipe) and "ops" (extras) cannot both be present');
    return FlashManifest(name: name as String?, description: json['description'] as String?, chip: chip, steps: steps, ops: ops);
  }

  static List<FlashStep> _steps(Map<String, dynamic> json, String key, String noun) {
    final raw = json[key];
    if (raw == null) return const [];
    if (raw is! List || raw.isEmpty) throw IdfToolException('manifest.json: "$key" must be a non-empty list');
    final steps = <FlashStep>[];
    for (var i = 0; i < raw.length; i++) {
      final item = raw[i];
      if (item is! Map<String, dynamic>) throw IdfToolException('manifest.json: $noun ${i + 1} must be an object');
      try {
        steps.add(FlashStep.fromJson(item));
      } on IdfToolException catch (e) {
        throw IdfToolException('manifest.json: $noun ${i + 1}: ${e.message}');
      }
    }
    return steps;
  }

  Map<String, dynamic> toJson() => {
        if (name != null) 'name': name,
        if (description != null) 'description': description,
        if (chip != null) 'chip': chip!.name.toLowerCase().replaceAll('-', ''),
        if (steps.isNotEmpty) 'steps': [for (final s in steps) s.toJson()],
        if (ops.isNotEmpty) 'ops': [for (final s in ops) s.toJson()],
      };
}

/// One operation of a [FlashManifest].
sealed class FlashStep {
  const FlashStep();

  String get op;

  /// What the step will do, for the pre-flight outline.
  String describe();

  /// Files in the bundle this step needs.
  List<String> get files => const [];

  Map<String, dynamic> toJson();

  static FlashStep fromJson(Map<String, dynamic> j) {
    final op = j['op'];
    if (op is! String) throw IdfToolException('"op" is required');
    String file() => _string(j, 'file');
    String partition() => _string(j, 'partition');
    return switch (op) {
      'write-bundle' => const WriteBundleStep(),
      'factory' => FactoryStep(file()),
      'ota' => OtaStep(file()),
      'write-table' => WriteTableStep(file(), force: j['force'] == true),
      'write-bootloader' => WriteBootloaderStep(file()),
      'write' => WritePartitionStep(partition(), file()),
      'erase' => EraseStep(partition()),
      'write-fs' => WriteFsStep(partition(), file()),
      'edit-fs' => EditFsStep(
          partition(),
          put: {for (final e in ((j['put'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}'},
          delete: [for (final d in (j['delete'] as List?) ?? const []) '$d'],
        ),
      'set-boot' => SetBootStep(partition()),
      'clear-boot' => const ClearBootStep(),
      'set-nvs' => SetNvsStep(
          partition: j['partition'] as String?,
          set: {for (final e in ((j['set'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}'},
          delete: [for (final d in (j['delete'] as List?) ?? const []) '$d'],
        ),
      _ => throw IdfToolException("unknown op '$op'"),
    };
  }

  static String _string(Map<String, dynamic> j, String key) {
    final v = j[key];
    if (v is! String || v.isEmpty) throw IdfToolException('"$key" is required for op \'${j['op']}\'');
    return v;
  }
}

class WriteBundleStep extends FlashStep {
  const WriteBundleStep();
  @override
  String get op => 'write-bundle';
  @override
  String describe() => 'Write every partition image in the bundle (and its partition table, if included)';
  @override
  Map<String, dynamic> toJson() => {'op': op};
}

class FactoryStep extends FlashStep {
  const FactoryStep(this.file);
  final String file;
  @override
  String get op => 'factory';
  @override
  String describe() => 'Flash $file to the factory partition (or ota_0) and boot it';
  @override
  List<String> get files => [file];
  @override
  Map<String, dynamic> toJson() => {'op': op, 'file': file};
}

class OtaStep extends FlashStep {
  const OtaStep(this.file);
  final String file;
  @override
  String get op => 'ota';
  @override
  String describe() => 'Write $file to the next OTA slot and switch to it';
  @override
  List<String> get files => [file];
  @override
  Map<String, dynamic> toJson() => {'op': op, 'file': file};
}

class WriteTableStep extends FlashStep {
  const WriteTableStep(this.file, {this.force = false});
  final String file;
  final bool force;
  @override
  String get op => 'write-table';
  @override
  String describe() => 'Replace the partition table with $file${force ? ' (unverified)' : ''}';
  @override
  List<String> get files => [file];
  @override
  Map<String, dynamic> toJson() => {'op': op, 'file': file, if (force) 'force': true};
}

class WriteBootloaderStep extends FlashStep {
  const WriteBootloaderStep(this.file);
  final String file;
  @override
  String get op => 'write-bootloader';
  @override
  String describe() => "Write $file at the chip's bootloader offset";
  @override
  List<String> get files => [file];
  @override
  Map<String, dynamic> toJson() => {'op': op, 'file': file};
}

class WritePartitionStep extends FlashStep {
  const WritePartitionStep(this.partition, this.file);
  final String partition;
  final String file;
  @override
  String get op => 'write';
  @override
  String describe() => 'Write $file to partition $partition';
  @override
  List<String> get files => [file];
  @override
  Map<String, dynamic> toJson() => {'op': op, 'partition': partition, 'file': file};
}

class EraseStep extends FlashStep {
  const EraseStep(this.partition);
  final String partition;
  @override
  String get op => 'erase';
  @override
  String describe() => 'Erase partition $partition';
  @override
  Map<String, dynamic> toJson() => {'op': op, 'partition': partition};
}

class WriteFsStep extends FlashStep {
  const WriteFsStep(this.partition, this.file);
  final String partition;
  final String file;
  @override
  String get op => 'write-fs';
  @override
  String describe() => 'Write filesystem image $file to partition $partition';
  @override
  List<String> get files => [file];
  @override
  Map<String, dynamic> toJson() => {'op': op, 'partition': partition, 'file': file};
}

/// Put and delete single files in a filesystem partition: the partition is
/// read, the changes applied and a fresh image written back (SPIFFS and FAT;
/// LittleFS images cannot be built yet).
class EditFsStep extends FlashStep {
  EditFsStep(this.partition, {this.put = const {}, this.delete = const []}) {
    if (put.isEmpty && delete.isEmpty) throw IdfToolException('edit-fs needs "put" and/or "delete"');
  }
  final String partition;

  /// Path in the filesystem → file in the bundle.
  final Map<String, String> put;
  final List<String> delete;
  @override
  String get op => 'edit-fs';
  @override
  String describe() {
    final what = [
      if (put.isNotEmpty) 'put ${put.keys.join(', ')}',
      if (delete.isNotEmpty) 'delete ${delete.join(', ')}',
    ].join('; ');
    return 'Update files in $partition: $what';
  }

  @override
  List<String> get files => put.values.toList();
  @override
  Map<String, dynamic> toJson() => {'op': op, 'partition': partition, if (put.isNotEmpty) 'put': put, if (delete.isNotEmpty) 'delete': delete};
}

class SetBootStep extends FlashStep {
  const SetBootStep(this.partition);
  final String partition;
  @override
  String get op => 'set-boot';
  @override
  String describe() => 'Boot from $partition';
  @override
  Map<String, dynamic> toJson() => {'op': op, 'partition': partition};
}

class ClearBootStep extends FlashStep {
  const ClearBootStep();
  @override
  String get op => 'clear-boot';
  @override
  String describe() => 'Clear the OTA selection so the factory app boots';
  @override
  Map<String, dynamic> toJson() => {'op': op};
}

class SetNvsStep extends FlashStep {
  SetNvsStep({this.partition, this.set = const {}, this.delete = const []}) {
    if (set.isEmpty && delete.isEmpty) throw IdfToolException('set-nvs needs "set" and/or "delete"');
  }
  final String? partition;

  /// `ns:key` → `type:value` (or bare value when the key already exists).
  final Map<String, String> set;
  final List<String> delete;
  @override
  String get op => 'set-nvs';
  @override
  String describe() {
    final what = [
      for (final e in set.entries) '${e.key} = ${e.value}',
      for (final d in delete) 'delete $d',
    ].join(', ');
    return 'Update NVS${partition == null ? '' : ' ($partition)'}: $what';
  }

  List<NvsEdit> get edits => [
        for (final e in set.entries) parseNvsSetSpec('${e.key}=${e.value}'),
        for (final d in delete) parseNvsDeleteSpec(d),
      ];
  @override
  Map<String, dynamic> toJson() =>
      {'op': op, if (partition != null) 'partition': partition, if (set.isNotEmpty) 'set': set, if (delete.isNotEmpty) 'delete': delete};
}

/// A bundle ZIP resolved into the steps that flash it: the operations its
/// filenames imply (table, bootloader, `@factory`/`@ota`, named
/// partitions) followed by the manifest's `ops`, or the manifest's `steps`
/// alone for a recipe. Every referenced file is checked to be present.
class FlashBundle {
  const FlashBundle({
    required this.name,
    this.description,
    this.chip,
    required this.steps,
    required this.contents,
    required this.zip,
    required this.files,
  });

  /// The manifest's name, or the bundle's own filename.
  final String name;
  final String? description;

  /// The manifest's chip, or the chip the bundle's app or bootloader image
  /// was built for. `null` when neither says.
  final EspChip? chip;
  final List<FlashStep> steps;
  final BundleContents contents;

  /// The ZIP itself, for `write-bundle`.
  final Uint8List zip;

  /// Every entry, by its full name in the ZIP.
  final Map<String, Uint8List> files;

  FlashManifest? get manifest => contents.manifest;

  /// [source] names the bundle when the manifest does not. The table
  /// offsets only shape the outline; `write-table` re-reads the table
  /// against the connected device's geometry.
  static FlashBundle fromZip(
    Uint8List zip, {
    String source = 'bundle',
    int partitionTableOffset = PartitionTable.defaultOffset,
    int? primaryBootloaderOffset,
  }) {
    final contents = readBundle(zip, partitionTableOffset: partitionTableOffset, primaryBootloaderOffset: primaryBootloaderOffset);
    final manifest = contents.manifest;
    final steps = manifest != null && manifest.isRecipe
        ? manifest.steps
        : <FlashStep>[
            if (contents.tableFile case final f?) WriteTableStep(f),
            if (contents.bootloader != null) const WriteBootloaderStep('bootloader.bin'),
            if (contents.factoryApp != null) const FactoryStep('${bundleRolePrefix}factory.bin'),
            if (contents.otaApp != null) const OtaStep('${bundleRolePrefix}ota.bin'),
            for (final name in contents.partitions.keys) WritePartitionStep(name, '$name.bin'),
            ...?manifest?.ops,
          ];
    if (steps.isEmpty) {
      throw IdfToolException('Nothing to flash: no partition_table, bootloader.bin, ${bundleRolePrefix}factory.bin, '
          '${bundleRolePrefix}ota.bin or <name>.bin, and no ${FlashManifest.fileName} steps');
    }
    final files = contents.files;
    for (final step in steps) {
      for (final name in step.files) {
        if (!files.containsKey(name)) throw IdfToolException("${step.op}: file '$name' is not in the bundle");
      }
    }
    if (steps.any((s) => s is WriteBundleStep) && !files.keys.any((k) => k.endsWith('.bin') && !k.contains('/'))) {
      throw IdfToolException('write-bundle: the bundle has no <partition>.bin files');
    }
    final stem = source.toLowerCase().endsWith('.zip') ? source.substring(0, source.length - 4) : source;
    return FlashBundle(
      name: manifest?.name ?? stem,
      description: manifest?.description,
      chip: manifest?.chip ?? _imageChip(contents.factoryApp) ?? _imageChip(contents.otaApp) ?? _imageChip(contents.bootloader),
      steps: steps,
      contents: contents,
      zip: zip,
      files: files,
    );
  }

  static EspChip? _imageChip(Uint8List? image) {
    final id = image == null ? null : ImageMetadata.fromBytesOrNull(image)?.header.chipId?.value;
    return id == null ? null : EspChip.values.where((c) => c.imageChipId == id).firstOrNull;
  }

  Uint8List file(String name) => files[name] ?? (throw IdfToolException("File '$name' is not in the bundle"));
}

/// Progress of a [runFlashBundle]: which step is running (0-based) and the
/// byte progress inside it.
typedef FlashStepCallback = void Function(int index, FlashStep step);

/// Run every step of [bundle] against [device], in order. Throws on the
/// first failure; [onStep] fires as each step starts.
///
/// [nvsKeys] decrypt and re-encrypt the partition for `set-nvs` steps on an
/// encrypted NVS partition. Keys never come from the bundle itself.
Future<void> runFlashBundle(
  IdfDevice device,
  FlashBundle bundle, {
  FlashStepCallback? onStep,
  ProgressCallback? onProgress,
  WriteStrategy strategy = WriteStrategy.differential,
  NvsKeys? nvsKeys,
  void Function(String message)? log,
}) async {
  if (bundle.chip != null && device.chip != bundle.chip) {
    throw IdfToolException('This bundle is for ${bundle.chip!.name}, but the connected device is a ${device.chip.name}');
  }
  for (var i = 0; i < bundle.steps.length; i++) {
    final step = bundle.steps[i];
    onStep?.call(i, step);
    String outcome(WriteOutcome o) => o.skipped ? 'already in flash' : 'wrote ${o.written} bytes in ${o.runs} region${o.runs == 1 ? '' : 's'}';
    switch (step) {
      case WriteBundleStep():
        final results = await device.writeBundle(bundle.zip, strategy: strategy, onProgress: onProgress);
        results.forEach((name, o) => log?.call('$name: ${outcome(o)}'));
      case FactoryStep(:final file):
        log?.call('factory: ${outcome(await device.factory(bundle.file(file), strategy: strategy, onProgress: onProgress))}');
      case OtaStep(:final file):
        final r = await device.ota(bundle.file(file), strategy: strategy, onProgress: onProgress);
        log?.call('${r.partition.name}: ${outcome(r.outcome)}; boot slot switched');
      case WriteTableStep(:final file, :final force):
        final bytes = bundle.file(file);
        final table = PartitionTable.isBinary(bytes)
            ? PartitionTable.fromBinary(bytes)
            : parsePartitionTableCsv(PartitionTable.decodeCsv(bytes),
                source: file, partitionTableOffset: device.partitionTableOffset, primaryBootloaderOffset: device.primaryBootloaderOffset);
        await device.writePartitionTable(table, force: force);
        log?.call('partition table written');
      case WriteBootloaderStep(:final file):
        final entry = (await device.resolver()).bootloaderEntry ??
            (throw IdfToolException('The bootloader offset of ${device.chip.name} is not known'));
        log?.call('bootloader: ${outcome(await device.writePartition(entry.name, bundle.file(file), strategy: strategy, onProgress: onProgress))}');
      case WritePartitionStep(:final partition, :final file):
        log?.call('$partition: ${outcome(await device.writePartition(partition, bundle.file(file), strategy: strategy, onProgress: onProgress))}');
      case EraseStep(:final partition):
        await device.erasePartition(partition);
        log?.call('$partition erased');
      case WriteFsStep(:final partition, :final file):
        log?.call('$partition: ${outcome(await device.writeFs(bundle.file(file), partitionName: partition, strategy: strategy, onProgress: onProgress))}');
      case EditFsStep(:final partition, :final put, :final delete):
        final r = await device.editFs(
          partitionName: partition,
          put: {for (final e in put.entries) e.key: bundle.file(e.value)},
          delete: delete,
          strategy: strategy,
          onProgress: onProgress,
        );
        log?.call('$partition: ${r.put} file(s) put, ${r.deleted} deleted; ${outcome(r.outcome)}');
        for (final m in r.missing) {
          log?.call('$partition: $m was not there to delete');
        }
      case SetBootStep(:final partition):
        await device.setBoot(partition);
        log?.call('boot slot set to $partition');
      case ClearBootStep():
        await device.clearBoot();
        log?.call('boot slot cleared');
      case SetNvsStep():
        final r = await device.editNvs(step.edits, partitionName: step.partition, keys: nvsKeys, onProgress: onProgress);
        for (final c in r.result.changes) {
          log?.call(describeNvsChange(c));
        }
    }
  }
}
