import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:esptool/esptool.dart';

import 'device.dart';
import 'flash/differential.dart';
import 'nvs/nvs.dart';
import 'partition_table.dart';
import 'partition_table_files.dart';

/// A one-click flashing recipe: an idftool bundle ZIP carrying a
/// `manifest.json` that names the device and lists the operations to run,
/// in order, against files inside the same ZIP.
///
/// ```json
/// {
///   "name": "MS5 v0.17.0",
///   "description": "Field update: OTA app, reset channel",
///   "chip": "esp32s3",
///   "steps": [
///     {"op": "ota", "file": "app.bin"},
///     {"op": "set-nvs", "partition": "nvs_cfg", "set": {"cfg:channel": "string:stable"}},
///     {"op": "clear-boot"}
///   ]
/// }
/// ```
///
/// Ops map onto [IdfDevice]: `write-bundle` (every `<partition>.bin` in the
/// ZIP plus `partition_table.csv` if present), `factory`/`ota` (`file`),
/// `write-table` (`file`), `write` (`partition`, `file`), `erase`
/// (`partition`), `set-nvs` (`partition`, `set` map of `ns:key` →
/// `type:value`, `delete` list of `ns:key`), `write-fs` (`partition`,
/// `file`), `set-boot` (`partition`), `clear-boot`. The same ZIP is what the
/// python single-use executables consume.
class FlashManifest {
  const FlashManifest({required this.name, this.description, this.chip, required this.steps});

  final String name;
  final String? description;

  /// The chip the recipe targets (e.g. `esp32s3`); checked against the
  /// connected device before anything is written. `null` skips the check.
  final EspChip? chip;
  final List<FlashStep> steps;

  static const fileName = 'manifest.json';

  factory FlashManifest.fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    if (name is! String || name.isEmpty) throw IdfToolException('manifest.json: "name" is required');
    final chipName = json['chip'];
    EspChip? chip;
    if (chipName != null) {
      if (chipName is! String) throw IdfToolException('manifest.json: "chip" must be a string');
      chip = EspChip.values.where((c) => c.name.toLowerCase().replaceAll('-', '') == chipName.toLowerCase().replaceAll('-', '')).firstOrNull;
      if (chip == null) throw IdfToolException("manifest.json: unknown chip '$chipName'");
    }
    final rawSteps = json['steps'];
    if (rawSteps is! List || rawSteps.isEmpty) throw IdfToolException('manifest.json: "steps" must be a non-empty list');
    final steps = <FlashStep>[];
    for (var i = 0; i < rawSteps.length; i++) {
      final raw = rawSteps[i];
      if (raw is! Map<String, dynamic>) throw IdfToolException('manifest.json: step ${i + 1} must be an object');
      try {
        steps.add(FlashStep.fromJson(raw));
      } on IdfToolException catch (e) {
        throw IdfToolException('manifest.json: step ${i + 1}: ${e.message}');
      }
    }
    return FlashManifest(name: name, description: json['description'] as String?, chip: chip, steps: steps);
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        if (description != null) 'description': description,
        if (chip != null) 'chip': chip!.name.toLowerCase().replaceAll('-', ''),
        'steps': [for (final s in steps) s.toJson()],
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
      'write' => WritePartitionStep(partition(), file()),
      'erase' => EraseStep(partition()),
      'write-fs' => WriteFsStep(partition(), file()),
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
  String describe() => 'Flash $file to the factory partition and boot it';
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

/// A bundle ZIP with its manifest parsed and every referenced file checked
/// to be present.
class FlashBundle {
  const FlashBundle({required this.manifest, required this.zip, required this.files});

  final FlashManifest manifest;

  /// The ZIP itself, for `write-bundle`.
  final Uint8List zip;
  final Map<String, Uint8List> files;

  static FlashBundle fromZip(Uint8List zip) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(zip, verify: true);
    } catch (e) {
      throw IdfToolException('Not a valid bundle ZIP: $e');
    }
    final files = {for (final f in archive.files.where((f) => f.isFile)) f.name: f.readBytes()!};
    final manifestBytes = files[FlashManifest.fileName] ?? (throw IdfToolException('Bundle has no ${FlashManifest.fileName}'));
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(manifestBytes));
    } catch (e) {
      throw IdfToolException('${FlashManifest.fileName} is not valid JSON: $e');
    }
    if (json is! Map<String, dynamic>) throw IdfToolException('${FlashManifest.fileName} must be a JSON object');
    final manifest = FlashManifest.fromJson(json);
    for (final step in manifest.steps) {
      for (final name in step.files) {
        if (!files.containsKey(name)) throw IdfToolException("${step.op}: file '$name' is not in the bundle");
      }
    }
    if (manifest.steps.any((s) => s is WriteBundleStep) && !files.keys.any((k) => k.endsWith('.bin') && !k.contains('/'))) {
      throw IdfToolException('write-bundle: the bundle has no <partition>.bin files');
    }
    return FlashBundle(manifest: manifest, zip: zip, files: files);
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
  final manifest = bundle.manifest;
  if (manifest.chip != null && device.chip != manifest.chip) {
    throw IdfToolException('This bundle is for ${manifest.chip!.name}, but the connected device is a ${device.chip.name}');
  }
  for (var i = 0; i < manifest.steps.length; i++) {
    final step = manifest.steps[i];
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
      case WritePartitionStep(:final partition, :final file):
        log?.call('$partition: ${outcome(await device.writePartition(partition, bundle.file(file), strategy: strategy, onProgress: onProgress))}');
      case EraseStep(:final partition):
        await device.erasePartition(partition);
        log?.call('$partition erased');
      case WriteFsStep(:final partition, :final file):
        log?.call('$partition: ${outcome(await device.writeFs(bundle.file(file), partitionName: partition, strategy: strategy, onProgress: onProgress))}');
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
