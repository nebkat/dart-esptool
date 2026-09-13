// idftool CLI — the python tool's commands over a libserialport transport.
//
//   dart run bin/idftool.dart devices
//   dart run bin/idftool.dart -p /dev/cu.usbmodem101 print-table
//   dart run bin/idftool.dart -p /dev/cu.usbmodem101 read nvs nvs.bin
//   dart run bin/idftool.dart -p /dev/cu.usbmodem101 ota build/app.bin
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:esptool/esptool.dart';
import 'package:esptool_libserialport/esptool_libserialport.dart';
import 'package:idftool/idftool.dart';

Future<void> main(List<String> args) async {
  ensureLibserialportResolved();
  final runner = CommandRunner<void>('idftool', 'Flash, provision and inspect ESP-IDF devices.')
    ..argParser.addOption('port', abbr: 'p', help: 'Serial port device')
    ..argParser.addOption('baud', abbr: 'b', defaultsTo: '115200', help: 'Serial port baud rate')
    ..argParser.addFlag('no-reset', negatable: false, help: 'Do not reset the chip after operations')
    ..argParser.addFlag('no-stub', negatable: false, help: 'Talk to the ROM loader only (no flasher stub)')
    ..argParser.addOption('partition-table-file', help: 'Partition table CSV/binary to use instead of the device\'s')
    ..argParser.addOption('partition-table-offset', defaultsTo: '0x8000', help: 'Partition table offset')
    ..argParser.addOption('partition-table-size', defaultsTo: '0x1000', help: 'Partition table size')
    ..argParser.addOption('primary-bootloader-offset', help: 'Primary bootloader offset (used when loading a CSV)')
    ..argParser.addOption('recovery-bootloader-offset', help: 'Recovery bootloader offset (used when loading a CSV)')
    ..argParser.addOption('diff', defaultsTo: 'auto', allowed: ['auto', 'always', 'skip-flashed', 'never'],
        help: 'always: write only changed sectors; skip-flashed: skip a region that matches; never: write everything');
  for (final c in [
    _Devices(),
    _PrintTable(),
    _DumpTable(),
    _WriteTable(),
    _CreateTable(),
    _Read(),
    _Write(),
    _Erase(),
    _GetBoot(),
    _SetBoot(),
    _ClearBoot(),
    _Factory(),
    _Ota(),
    _AppInfo(),
    _DumpImage(),
    _WriteImage(),
    _PrintImage(),
    _DumpBundle(),
    _WriteBundle(),
    _PrintBundle(),
    _CreateNvs(),
    _WriteNvs(),
    _ReadNvs(),
    _ExtractNvs(),
    _PrintNvs(),
    _GetNvs(),
    _SetNvs(),
    _PrintFs(),
    _ReadFs(),
    _ExtractFs(),
    _CreateFs(),
    _WriteFs(),
  ]) {
    runner.addCommand(c);
  }
  try {
    await runner.run(args);
  } on UsageException catch (e) {
    stderr.writeln(e);
    exitCode = 64;
  } on IdfToolException catch (e) {
    stderr.writeln('Error: $e');
    exitCode = 1;
  } on PartitionTableException catch (e) {
    stderr.writeln('Error: $e');
    exitCode = 1;
  } on PartitionLookupException catch (e) {
    stderr.writeln('Error: $e');
    exitCode = 1;
  } on NvsError catch (e) {
    stderr.writeln('Error: $e');
    exitCode = 1;
  } on EspException catch (e) {
    stderr.writeln('Error: ${e.message}');
    exitCode = 2;
  }
}

Uint8List _readFileArg(String path, String what) {
  final file = File(path);
  if (!file.existsSync()) throw IdfToolException("$what '$path' does not exist");
  final bytes = file.readAsBytesSync();
  if (bytes.isEmpty) throw IdfToolException("$what '$path' is empty");
  return bytes;
}

Uint8List? _readFileForNvs(String path) => File(path).existsSync() ? File(path).readAsBytesSync() : null;

void _reportNvsErrors(NvsImage image) {
  for (final e in image.errors) {
    stderr.writeln('Warning: $e${image.looksEncrypted ? ' (pass --hmac-key)' : ''}');
  }
}

void _addHmacKeyOption(ArgParser parser) => parser.addOption('hmac-key',
    help: 'Encrypted NVS (HMAC key protection scheme): the HMAC key, as 64 hex digits or a file holding its 32 bytes');

/// The NVS encryption keys from `--hmac-key`, if given.
NvsKeys? _hmacKeyArg(ArgResults args) {
  final value = args['hmac-key'] as String?;
  if (value == null) return null;
  final file = File(value);
  return NvsKeys.fromHmacKey(NvsKeys.parseHmacKey(file.existsSync() ? file.readAsBytesSync() : value));
}

/// Shared by the NVS commands: the image comes from `--file` or from the
/// (optionally named) partition on the device.
mixin _NvsSource on _Command {
  void addSourceOptions() {
    argParser.addOption('file', abbr: 'f', help: 'Use this NVS image file instead of a partition on the device');
    _addHmacKeyOption(argParser);
  }

  NvsKeys? get nvsKeys => _hmacKeyArg(argResults!);

  /// Load the image, running [body] with it and — when it came from the
  /// device — the device and partition, so edits can be written back. With
  /// `--hmac-key` the image is decrypted first, so [body] sees plaintext.
  Future<void> withNvs(String? partitionName, Future<void> Function(Uint8List data, IdfDevice? device, PartitionDefinition? partition) body) async {
    final file = argResults!['file'] as String?;
    final keys = nvsKeys;
    if (file != null) {
      final data = _readFileArg(file, 'NVS image');
      if (!looksLikeNvsBinary(data)) throw IdfToolException("'$file' does not look like an NVS image");
      return body(keys == null ? data : decryptNvs(data, keys), null, null);
    }
    await withDevice((device, _) async {
      final (partition: partition, image: image) = await device.readNvs(name: partitionName, keys: keys, onProgress: progress);
      await body(image.data, device, partition);
    });
  }
}

class _CreateNvs extends _Command {
  @override
  final name = 'create-nvs';
  @override
  final description = 'Generate an NVS partition image from a CSV file: CSV OUTPUT';
  _CreateNvs() {
    argParser.addOption('size', help: 'Partition size in bytes (e.g. 0x6000)');
    argParser.addOption('partition', help: 'Partition name to take the size from (--partition-table-file)');
    argParser.addOption('version', defaultsTo: '2', allowed: ['1', '2']);
    _addHmacKeyOption(argParser);
  }
  @override
  Future<void> run() async {
    final csv = File(_arg(argResults!, 0, 'CSV file')).readAsStringSync();
    final out = _arg(argResults!, 1, 'output file');
    int size;
    if (argResults!['size'] != null) {
      size = _int(argResults!['size'] as String, what: 'size');
    } else if (argResults!['partition'] != null) {
      final table = tableFromFile(null) ?? (throw UsageException('--partition needs --partition-table-file', ''));
      size = (table.findByName(argResults!['partition'] as String) ??
              (throw IdfToolException("No partition named '${argResults!['partition']}'")))
          .size;
    } else {
      throw UsageException('Pass --size or --partition', '');
    }
    final image = generateNvsImage(csv, size,
        version: argResults!['version'] == '1' ? NvsVersion.v1 : NvsVersion.v2, readFile: _readFileForNvs, keys: _hmacKeyArg(argResults!));
    File(out).writeAsBytesSync(image);
    stderr.writeln('Wrote ${hex(image.length)}-byte ${argResults!['hmac-key'] != null ? 'encrypted ' : ''}NVS image to $out');
  }
}

class _WriteNvs extends _Command {
  @override
  final name = 'write-nvs';
  @override
  final description = 'Generate an NVS image from a CSV (or take a .bin) and flash it: [PARTITION] FILE';
  _WriteNvs() {
    _addHmacKeyOption(argParser);
  }
  @override
  Future<void> run() => withDevice((device, _) async {
        final rest = argResults!.rest;
        if (rest.isEmpty) throw UsageException('Missing input file', '');
        final partitionName = rest.length > 1 ? rest[0] : null;
        final path = rest.last;
        final partition = await device.nvsPartition(partitionName);
        final bytes = _readFileArg(path, 'input file');
        final keys = _hmacKeyArg(argResults!);
        // With --hmac-key a plaintext .bin is encrypted; one that already is goes as it is.
        final image = looksLikeNvsBinary(bytes)
            ? (keys == null || looksEncryptedNvs(bytes) ? bytes : encryptNvs(bytes, keys))
            : generateNvsImage(String.fromCharCodes(bytes), partition.size, readFile: _readFileForNvs, keys: keys);
        reportWrite(partition.name, await device.writeNvs(image, partitionName: partition.name, strategy: strategy, onProgress: progress));
      });
}

class _ReadNvs extends _Command {
  @override
  final name = 'read-nvs';
  @override
  final description = 'Read an NVS partition from the device and extract it to CSV: [PARTITION] OUTPUT.csv';
  _ReadNvs() {
    _addHmacKeyOption(argParser);
  }
  @override
  Future<void> run() => withDevice((device, _) async {
        final rest = argResults!.rest;
        if (rest.isEmpty) throw UsageException('Missing output file', '');
        final (partition: _, image: image) =
            await device.readNvs(name: rest.length > 1 ? rest[0] : null, keys: _hmacKeyArg(argResults!), onProgress: progress);
        _reportNvsErrors(image);
        File(rest.last).writeAsStringSync(nvsToCsv(image.entries));
        stderr.writeln('Wrote ${image.entries.length} entries to ${rest.last}');
      });
}

class _ExtractNvs extends _Command {
  @override
  final name = 'extract-nvs';
  @override
  final description = 'Extract an NVS image file to CSV: IMAGE OUTPUT.csv';
  _ExtractNvs() {
    _addHmacKeyOption(argParser);
  }
  @override
  Future<void> run() async {
    final data = _readFileArg(_arg(argResults!, 0, 'image file'), 'NVS image');
    final keys = _hmacKeyArg(argResults!);
    final image = parseNvs(keys == null ? data : decryptNvs(data, keys));
    _reportNvsErrors(image);
    File(_arg(argResults!, 1, 'output file')).writeAsStringSync(nvsToCsv(image.entries));
  }
}

class _PrintNvs extends _Command with _NvsSource {
  @override
  final name = 'print-nvs';
  @override
  final description = 'List the entries of an NVS partition (or --file image)';
  _PrintNvs() {
    addSourceOptions();
    argParser.addFlag('pages', negatable: false, help: 'Show the page-level view');
  }
  @override
  Future<void> run() => withNvs(argResults!.rest.firstOrNull, (data, _, partition) async {
        final image = parseNvs(data);
        _reportNvsErrors(image);
        final source = partition == null ? "'${argResults!['file']}'" : "partition '${partition.name}'";
        stdout.writeln('$source: NVS version ${image.version == NvsVersion.v1 ? 1 : 2}, ${hex(data.length)} bytes');
        if (argResults!['pages'] as bool) stdout.writeln('${formatNvsPages(image)}\n');
        stdout.writeln(formatNvsEntries(image.entries));
      });
}

class _GetNvs extends _Command with _NvsSource {
  @override
  final name = 'get-nvs';
  @override
  final description = 'Print the value of keys (namespace:key) from an NVS partition or --file image';
  _GetNvs() {
    addSourceOptions();
    argParser.addOption('namespace', abbr: 'n', help: 'Default namespace for keys that do not name one');
    argParser.addFlag('raw', negatable: false, help: 'Write one value to stdout as raw bytes');
  }
  @override
  Future<void> run() async {
    final rest = argResults!.rest;
    final fromFile = argResults!['file'] != null;
    // Without --file the first positional is the partition, unless it looks like a key.
    final partitionName = !fromFile && rest.length > 1 && !rest[0].contains(':') ? rest[0] : null;
    final specs = partitionName == null ? rest : rest.sublist(1);
    if (specs.isEmpty) throw UsageException('Provide at least one key to read (namespace:key)', '');
    final keys = [for (final s in specs) parseNvsGetSpec(s, defaultNamespace: argResults!['namespace'] as String?)];
    if (argResults!['raw'] as bool && keys.length != 1) throw UsageException('--raw reads exactly one key', '');
    await withNvs(partitionName, (data, _, __) async {
      final image = parseNvs(data);
      _reportNvsErrors(image);
      for (final (ns, key) in keys) {
        final entry = image.get(ns, key) ?? (throw NvsError("'$ns:$key' is not in the image"));
        final value = entry.value;
        if (argResults!['raw'] as bool) {
          stdout.add(value is Uint8List ? value : entry.valueText.codeUnits);
        } else {
          stdout.writeln(value is Uint8List ? hexEncode(value) : entry.valueText);
        }
      }
    });
  }
}

class _SetNvs extends _Command with _NvsSource {
  @override
  final name = 'set-nvs';
  @override
  final description = 'Set or delete keys in an NVS partition or --file image: [PARTITION] ns:key=type:value ...';
  _SetNvs() {
    addSourceOptions();
    argParser.addMultiOption('delete', abbr: 'd', help: 'Delete a key: namespace:key');
    argParser.addOption('namespace', abbr: 'n', help: 'Default namespace for specs that do not name one');
    argParser.addOption('output', abbr: 'o', help: 'With --file, write the result here instead of over the input');
    argParser.addFlag('rewrite', negatable: false, help: 'Compact the image instead of appending');
    argParser.addFlag('dry-run', negatable: false, help: 'Show what would change without writing');
  }
  @override
  Future<void> run() async {
    final rest = argResults!.rest;
    final fromFile = argResults!['file'] != null;
    final partitionName = !fromFile && rest.isNotEmpty && !rest[0].contains('=') ? rest[0] : null;
    final specs = partitionName == null ? rest : rest.sublist(1);
    final deletes = argResults!['delete'] as List<String>;
    if (specs.isEmpty && deletes.isEmpty) throw UsageException('Nothing to do — pass at least one SPEC or --delete.\n$nvsSpecHelp', '');
    final ns = argResults!['namespace'] as String?;
    final edits = [
      for (final s in specs) parseNvsSetSpec(s, defaultNamespace: ns, readFile: _readFileForNvs),
      for (final d in deletes) parseNvsDeleteSpec(d, defaultNamespace: ns),
    ];
    final dryRun = argResults!['dry-run'] as bool;
    await withNvs(partitionName, (data, device, partition) async {
      final image = parseNvs(data);
      _reportNvsErrors(image);
      final resolved = resolveUntypedNvsEdits(image, edits, readFile: _readFileForNvs);
      final result = applyNvsEdits(data, resolved, forceRewrite: argResults!['rewrite'] as bool);
      stderr.writeln("Editing '${partition?.name ?? argResults!['file']}' (${hex(data.length)} bytes)");
      for (final change in result.changes) {
        stderr.writeln(describeNvsChange(change));
      }
      if (result.dirtyPages.isEmpty) {
        stderr.writeln('Nothing changed.');
        return;
      }
      stderr.writeln(result.compacted
          ? 'No room left to append — the image was compacted and rewritten in full.'
          : 'Appended in place; ${result.dirtyPages.length} of ${data.length ~/ NvsLayout.pageSize} '
              'page${result.dirtyPages.length == 1 ? '' : 's'} changed (${result.dirtyPages.join(', ')}).');
      if (dryRun) {
        stderr.writeln('Dry run — nothing written.');
        return;
      }
      // Encrypt again on the way out; the dirty pages are the same for the ciphertext.
      final keys = nvsKeys;
      final output = keys == null ? result.image : encryptNvs(result.image, keys);
      if (partition != null) {
        final writes = contiguousNvsWrites(partition.offset, output, result.dirtyPages);
        stderr.writeln("Writing ${hex(writes.fold(0, (n, w) => n + w.$2.length))} bytes to partition '${partition.name}' in ${writes.length} run(s)");
        for (final (address, bytes) in writes) {
          await device!.loader.writeFlash(address, bytes);
        }
      } else {
        final target = argResults!['output'] as String? ?? argResults!['file'] as String;
        File(target).writeAsBytesSync(output);
        stderr.writeln("Wrote ${hex(output.length)} bytes to '$target'");
      }
    });
  }
}

int _int(String? s, {String what = 'value'}) =>
    s == null ? (throw UsageException('$what is required', '')) : (tryParseIntLiteral(s) ?? (throw UsageException("Invalid $what '$s'", '')));

/// The global options and the lazily opened device — python idftool's `State`.
abstract class _Command extends Command<void> {
  ArgResults get global => globalResults!;

  int get partitionTableOffset => _int(global['partition-table-offset'] as String, what: 'partition table offset');
  int get partitionTableSize => _int(global['partition-table-size'] as String, what: 'partition table size');
  WriteStrategy get strategy => switch (global['diff'] as String) {
        'always' || 'auto' => WriteStrategy.differential,
        'skip-flashed' => WriteStrategy.skipFlashed,
        _ => WriteStrategy.always,
      };

  int? _bootloaderOffset(String option, EspChip? chip) {
    final text = global[option] as String?;
    if (text == null) return option == 'primary-bootloader-offset' ? chip?.bootloaderFlashOffset : null;
    final byChip = EspChip.values.where((c) => c.name.toLowerCase().replaceAll('-', '') == text.toLowerCase()).firstOrNull;
    return byChip?.bootloaderFlashOffset ?? _int(text, what: option);
  }

  /// Load `--partition-table-file` if given.
  PartitionTable? tableFromFile(EspChip? chip) {
    final path = global['partition-table-file'] as String?;
    if (path == null) return null;
    final bytes = File(path).readAsBytesSync();
    if (bytes.isEmpty) throw IdfToolException("Partition table file '$path' is empty");
    if (PartitionTable.isBinary(bytes)) return PartitionTable.fromBinary(bytes).requireNotEmpty("file '$path'");
    return parsePartitionTableCsv(
      PartitionTable.decodeCsv(bytes),
      source: "file '$path'",
      partitionTableOffset: partitionTableOffset,
      primaryBootloaderOffset: _bootloaderOffset('primary-bootloader-offset', chip),
      recoveryBootloaderOffset: _bootloaderOffset('recovery-bootloader-offset', chip),
    );
  }

  /// Connect, run [body], then reset and close.
  Future<void> withDevice(Future<void> Function(IdfDevice device, int flashSize) body) async {
    final portName = global['port'] as String? ?? _pickPort();
    final baud = _int(global['baud'] as String, what: 'baud rate');
    final transport = LibSerialPortTransport.open(portName, baudRate: baud);
    final loader = EspLoader(transport, baudRate: baud);
    try {
      stderr.writeln('Connecting to $portName ...');
      final nativeUsb = portName.contains('usbmodem') || portName.contains('ttyACM');
      final strategies = nativeUsb ? [EspResets.usbJtag(), EspResets.classic()] : [EspResets.classic(), EspResets.usbJtag()];
      EspChip? chip;
      Object? last;
      for (final reset in strategies) {
        try {
          chip = await loader.connect(reset: reset, attempts: 3);
          break;
        } on EspConnectException catch (e) {
          last = e;
        }
      }
      if (chip == null) throw EspConnectException('Could not connect to an ESP chip on $portName', last);
      final flashSize = await loader.attachFlash() ?? 4 * 1024 * 1024;
      if (!(global['no-stub'] as bool)) await loader.runStub();
      stderr.writeln('Connected: ${chip.name}, ${flashSize ~/ (1024 * 1024)} MB flash${loader.isStub ? ', stub running' : ''}');
      final device = IdfDevice(loader,
          partitionTableOffset: partitionTableOffset,
          partitionTableSize: partitionTableSize,
          primaryBootloaderOffset: _bootloaderOffset('primary-bootloader-offset', chip));
      final table = tableFromFile(chip);
      if (table != null) device.usePartitionTable(table);
      await body(device, flashSize);
      if (!(global['no-reset'] as bool)) {
        stderr.writeln('Hard resetting via RTS pin...');
        await loader.hardReset();
      }
    } finally {
      await loader.dispose();
      transport.close();
    }
  }

  String _pickPort() {
    final ports = LibSerialPortTransport.availablePorts.where((p) => p.contains('usb')).toList();
    if (ports.length == 1) return ports.single;
    throw UsageException(ports.isEmpty ? 'No USB serial ports found' : 'Several ports found, pass --port: ${ports.join(', ')}', '');
  }

  /// Read a partition table from a file argument (CSV or binary).
  PartitionTable loadTableArg(String path, EspChip? chip) {
    final bytes = File(path).readAsBytesSync();
    if (bytes.isEmpty) throw IdfToolException("Partition table file '$path' is empty");
    if (PartitionTable.isBinary(bytes)) return PartitionTable.fromBinary(bytes).requireNotEmpty("file '$path'");
    return parsePartitionTableCsv(PartitionTable.decodeCsv(bytes),
        source: "file '$path'",
        partitionTableOffset: partitionTableOffset,
        primaryBootloaderOffset: _bootloaderOffset('primary-bootloader-offset', chip),
        recoveryBootloaderOffset: _bootloaderOffset('recovery-bootloader-offset', chip));
  }

  ProgressCallback get progress {
    String? lastLabel;
    var lastPct = -1;
    return (label, done, total) {
      final pct = total == 0 ? 100 : done * 100 ~/ total;
      if (label != lastLabel) {
        if (lastLabel != null) stderr.writeln();
        lastLabel = label;
        lastPct = -1;
      }
      if (pct != lastPct) {
        stderr.write('\r$label: ${_size(done)} / ${_size(total)} ($pct%)   ');
        lastPct = pct;
      }
      if (done >= total) stderr.writeln();
    };
  }

  void reportWrite(String what, WriteOutcome o) {
    if (o.skipped) {
      stderr.writeln('$what is already in flash, skipping write');
    } else {
      final rate = o.elapsed.inMilliseconds == 0 ? '' : ' (${_size(o.written * 1000 ~/ o.elapsed.inMilliseconds)}/s)';
      stderr.writeln('$what: wrote ${_size(o.written)} in ${o.runs} region${o.runs == 1 ? '' : 's'}'
          '${o.abandoned ? ' (comparison abandoned)' : ''} in ${(o.elapsed.inMilliseconds / 1000).toStringAsFixed(1)} s$rate');
    }
  }

  static String _size(int n) => n >= 1024 * 1024
      ? '${(n / (1024 * 1024)).toStringAsFixed(2)} MiB'
      : n >= 1024
          ? '${(n / 1024).toStringAsFixed(1)} KiB'
          : '$n B';

  static String appInfo(ImageMetadata image, {String indent = ''}) {
    final d = image.appDescription!;
    final h = image.header;
    return [
      '${indent}Project name:     ${d.projectName}',
      '${indent}Version:          ${d.version}',
      '${indent}IDF version:      ${d.idfVersion}',
      '${indent}Secure version:   ${d.secureVersion}',
      '${indent}Compiled:         ${d.date} ${d.time}',
      '${indent}ELF SHA256:       ${d.elfSha256.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}',
      '${indent}Chip:             ${h.chipId?.name ?? 'unknown'}',
    ].join('\n');
  }

  /// Partition table plus app info per app partition, reading via [read].
  static Future<String> tableWithApps(PartitionTable table, Future<Uint8List> Function(int offset, int length) read,
      {OtaDataParameters? otadata}) async {
    final out = StringBuffer(table.format(otadata: otadata));
    for (final p in table.where((p) => p.isApp)) {
      final image = ImageMetadata.fromBytesOrNull(await read(p.offset, p.size), appRequired: true);
      if (image == null) continue;
      out.writeln('\n\nPartition \'${p.name}\' (offset=${hex(p.offset)}):');
      out.write(appInfo(image, indent: '  '));
    }
    return out.toString();
  }
}

String _arg(ArgResults r, int i, String name) =>
    r.rest.length > i ? r.rest[i] : (throw UsageException('Missing $name', ''));

class _Devices extends _Command {
  @override
  final name = 'devices';
  @override
  final description = 'List serial ports; with --identify, connect to each and report chip and MAC (resets them)';
  _Devices() {
    argParser.addFlag('identify', abbr: 'i', negatable: false, help: 'Probe each port for an ESP chip and its MAC');
  }
  @override
  Future<void> run() async {
    final ports = LibSerialPortTransport.availablePorts;
    if (!(argResults!['identify'] as bool)) {
      ports.forEach(stdout.writeln);
      return;
    }
    final rows = <(String, String, String)>[];
    for (final port in ports) {
      if (!port.contains('usb') && !port.contains('ACM') && !port.contains('COM')) continue;
      final (what, detail) = await _probe(port);
      rows.add((port, what, detail));
    }
    final w0 = rows.fold(0, (n, r) => r.$1.length > n ? r.$1.length : n);
    final w1 = rows.fold(0, (n, r) => r.$2.length > n ? r.$2.length : n);
    for (final (port, what, detail) in rows) {
      stdout.writeln('${port.padRight(w0)}   ${what.padRight(w1)}   $detail'.trimRight());
    }
  }

  /// `(what, detail)` for [port] — python idftool's `probe_port`/`device_fields`.
  Future<(String, String)> _probe(String port) async {
    final LibSerialPortTransport transport;
    try {
      transport = LibSerialPortTransport.open(port, baudRate: 115200);
    } catch (e) {
      // EBUSY (16) or EAGAIN (35): another process has the port open.
      return ('Unavailable', RegExp(r'errno = (16|35)\b').hasMatch('$e') ? 'port is in use' : '$e');
    }
    final loader = EspLoader(transport);
    try {
      final nativeUsb = port.contains('usbmodem') || port.contains('ttyACM');
      EspChip? chip;
      for (final reset in nativeUsb ? [EspResets.usbJtag(), EspResets.classic()] : [EspResets.classic(), EspResets.usbJtag()]) {
        try {
          chip = await loader.connect(reset: reset, attempts: 2);
          break;
        } on EspException catch (_) {}
      }
      if (chip == null) return ('Unidentified', 'no response');
      String mac = '';
      try {
        mac = (await loader.readMac()).map((b) => b.toRadixString(16).padLeft(2, '0')).join(':');
      } catch (_) {}
      await loader.hardReset();
      return (chip.name, mac);
    } finally {
      await loader.dispose();
      transport.close();
    }
  }
}

class _PrintTable extends _Command {
  @override
  final name = 'print-table';
  @override
  final description = 'Print the partition table from a file (argument or --partition-table-file) or the device';
  @override
  Future<void> run() async {
    final file = argResults!.rest.firstOrNull ?? global['partition-table-file'] as String?;
    if (file != null) {
      stdout.writeln(loadTableArg(file, null).format());
      return;
    }
    await withDevice((device, _) async {
      final table = await device.partitionTable();
      OtaDataParameters? otadata;
      try {
        otadata = (await device.readOtadata()).otadata;
      } on IdfToolException {
        // no OTA layout
      }
      stdout.writeln(await _Command.tableWithApps(table, device.loader.readFlash, otadata: otadata));
    });
  }
}

class _DumpTable extends _Command {
  @override
  final name = 'dump-table';
  @override
  final description = 'Read the partition table from the device into a file (csv or bin by extension)';
  _DumpTable() {
    argParser.addOption('format', allowed: ['csv', 'bin']);
  }
  @override
  Future<void> run() async {
    final out = _arg(argResults!, 0, 'output file');
    final format = PartitionTableFormat.resolve(
        outputFile: out, explicit: PartitionTableFormat.values.where((f) => f.name == argResults!['format']).firstOrNull);
    await withDevice((device, _) async {
      final table = await device.partitionTable();
      final data = format == PartitionTableFormat.csv ? Uint8List.fromList(table.toCsv().codeUnits) : table.toBinary();
      File(out).writeAsBytesSync(data);
      stderr.writeln('Wrote ${format.name} partition table (${hex(data.length)} bytes) to $out');
    });
  }
}

class _WriteTable extends _Command {
  @override
  final name = 'write-table';
  @override
  final description = 'Flash a partition table from a CSV or binary file';
  _WriteTable() {
    argParser.addFlag('force', negatable: false, help: 'Flash even if verification fails');
  }
  @override
  Future<void> run() async {
    final file = _arg(argResults!, 0, 'table file');
    await withDevice((device, flashSize) async {
      final table = loadTableArg(file, device.chip);
      stdout.writeln(table.format());
      stderr.writeln('\nWriting partition table to ${hex(device.partitionTableOffset)}...\n'
          'Note: this replaces only the partition map; existing partition data is not moved, resized or erased.');
      await device.writePartitionTable(table, force: argResults!['force'] as bool, flashSize: flashSize);
      stderr.writeln('Partition table written');
    });
  }
}

class _CreateTable extends _Command {
  @override
  final name = 'create-table';
  @override
  final description = 'Convert a partition table between CSV and binary';
  _CreateTable() {
    argParser.addOption('format', allowed: ['csv', 'bin']);
  }
  @override
  Future<void> run() async {
    final input = _arg(argResults!, 0, 'input file');
    final out = _arg(argResults!, 1, 'output file');
    final format = PartitionTableFormat.resolve(
        outputFile: out, explicit: PartitionTableFormat.values.where((f) => f.name == argResults!['format']).firstOrNull);
    final table = loadTableArg(input, null);
    final data = format == PartitionTableFormat.csv ? Uint8List.fromList(table.toCsv().codeUnits) : table.toBinary();
    File(out).writeAsBytesSync(data);
    stderr.writeln('Wrote ${format.name} partition table (${hex(data.length)} bytes) to $out');
  }
}

class _Read extends _Command {
  @override
  final name = 'read';
  @override
  final description = 'Read a partition (or slice, e.g. nvs[0x100:0x200]) into a file';
  @override
  Future<void> run() async {
    final spec = _arg(argResults!, 0, 'partition');
    final out = _arg(argResults!, 1, 'output file');
    await withDevice((device, _) async {
      final data = await device.readPartition(spec, onProgress: progress);
      File(out).writeAsBytesSync(data);
      stderr.writeln('Wrote ${hex(data.length)} bytes to $out');
    });
  }
}

class _Write extends _Command {
  @override
  final name = 'write';
  @override
  final description = 'Write files to partitions: PARTITION FILE [PARTITION FILE ...]';
  @override
  Future<void> run() async {
    final rest = argResults!.rest;
    if (rest.isEmpty || rest.length.isOdd) throw UsageException('Expected PARTITION FILE pairs', '');
    await withDevice((device, _) async {
      for (var i = 0; i < rest.length; i += 2) {
        final data = File(rest[i + 1]).readAsBytesSync();
        reportWrite(
            "'${rest[i + 1]}' to ${rest[i]}", await device.writePartition(rest[i], data, strategy: strategy, onProgress: progress));
      }
    });
  }
}

class _Erase extends _Command {
  @override
  final name = 'erase';
  @override
  final description = 'Erase a partition (or slice)';
  @override
  Future<void> run() async {
    final spec = _arg(argResults!, 0, 'partition');
    await withDevice((device, _) => device.erasePartition(spec));
  }
}

class _GetBoot extends _Command {
  @override
  final name = 'get-boot';
  @override
  final description = 'Show the currently active OTA slot';
  @override
  Future<void> run() => withDevice((device, _) async {
        final otadata = (await device.readOtadata()).otadata;
        final slot = otadata.slot;
        stdout.writeln(slot == null
            ? 'OTA slot not set'
            : "OTA slot 'ota_$slot' (seq=${otadata.entry!.seq}, state=${otadata.entry!.state.name})");
      });
}

class _SetBoot extends _Command {
  @override
  final name = 'set-boot';
  @override
  final description = 'Force the next boot to a specific OTA partition';
  @override
  Future<void> run() => withDevice((device, _) => device.setBoot(_arg(argResults!, 0, 'partition')));
}

class _ClearBoot extends _Command {
  @override
  final name = 'clear-boot';
  @override
  final description = 'Erase otadata so the bootloader falls back to the factory app';
  @override
  Future<void> run() => withDevice((device, _) => device.clearBoot());
}

class _Factory extends _Command {
  @override
  final name = 'factory';
  @override
  final description = 'Flash an app to the factory partition';
  @override
  Future<void> run() => withDevice((device, _) async {
        final app = File(_arg(argResults!, 0, 'app binary')).readAsBytesSync();
        reportWrite('factory', await device.factory(app, strategy: strategy, onProgress: progress));
      });
}

class _Ota extends _Command {
  @override
  final name = 'ota';
  @override
  final description = 'Push an app to the next OTA slot and switch to it';
  @override
  Future<void> run() => withDevice((device, _) async {
        final app = File(_arg(argResults!, 0, 'app binary')).readAsBytesSync();
        final result = await device.ota(app, strategy: strategy, onProgress: progress);
        reportWrite(result.partition.name, result.outcome);
        stderr.writeln("Boot partition set to '${result.partition.name}'");
      });
}

class _AppInfo extends _Command {
  @override
  final name = 'app-info';
  @override
  final description = 'Print the app descriptor of an app binary';
  @override
  Future<void> run() async {
    final image = ImageMetadata.fromBytes(File(_arg(argResults!, 0, 'app binary')).readAsBytesSync(), appRequired: true);
    stdout.writeln(_Command.appInfo(image));
  }
}

class _DumpImage extends _Command {
  @override
  final name = 'dump-image';
  @override
  final description = 'Dump the flash to an image file';
  _DumpImage() {
    argParser.addOption('size', help: 'Bytes to read from the start of flash (default: whole chip)');
  }
  @override
  Future<void> run() => withDevice((device, flashSize) async {
        final out = _arg(argResults!, 0, 'output file');
        final size = argResults!['size'] == null ? null : _int(argResults!['size'] as String, what: 'size');
        final data = await device.dumpImage(flashSize: flashSize, size: size, onProgress: progress);
        File(out).writeAsBytesSync(data);
        stderr.writeln('Wrote ${hex(data.length)} bytes to $out');
      });
}

class _WriteImage extends _Command {
  @override
  final name = 'write-image';
  @override
  final description = 'Write a whole-flash image (erasing the whole flash first unless --no-erase)';
  _WriteImage() {
    argParser.addFlag('erase', defaultsTo: true);
  }
  @override
  Future<void> run() => withDevice((device, _) async {
        final image = File(_arg(argResults!, 0, 'image file')).readAsBytesSync();
        reportWrite('image',
            await device.writeImage(image, erase: argResults!['erase'] as bool, strategy: strategy, onProgress: progress));
      });
}

class _PrintImage extends _Command {
  @override
  final name = 'print-image';
  @override
  final description = 'Print the partition table and app info from a flash image file';
  @override
  Future<void> run() async {
    final path = _arg(argResults!, 0, 'image file');
    final image = File(path).readAsBytesSync();
    if (image.length <= partitionTableOffset) {
      throw IdfToolException("Image '$path' (${hex(image.length)} bytes) does not contain a partition table at ${hex(partitionTableOffset)}");
    }
    final table = PartitionTable.fromBinary(
            Uint8List.sublistView(image, partitionTableOffset, (partitionTableOffset + partitionTableSize).clamp(0, image.length)))
        .requireNotEmpty("image at offset ${hex(partitionTableOffset)}");
    Future<Uint8List> read(int offset, int length) async {
      final out = Uint8List(length)..fillRange(0, length, 0xFF);
      if (offset < image.length) out.setRange(0, (length).clamp(0, image.length - offset), image, offset);
      return out;
    }
    stdout.writeln('Image: $path (${hex(image.length)} bytes)\n');
    stdout.writeln(await _Command.tableWithApps(table, read));
  }
}

class _DumpBundle extends _Command {
  @override
  final name = 'dump-bundle';
  @override
  final description = 'Pack every partition from the device into a ZIP';
  @override
  Future<void> run() => withDevice((device, _) async {
        final zip = await device.dumpBundle(onProgress: progress);
        final out = argResults!.rest.firstOrNull ??
            '${device.chip.name.toLowerCase()}-${(await device.loader.readMac()).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}.zip';
        File(out).writeAsBytesSync(zip);
        stderr.writeln('Bundle written to $out');
      });
}

class _WriteBundle extends _Command {
  @override
  final name = 'write-bundle';
  @override
  final description = 'Flash every binary in a bundle ZIP';
  @override
  Future<void> run() => withDevice((device, _) async {
        final zip = File(_arg(argResults!, 0, 'bundle file')).readAsBytesSync();
        final outcomes = await device.writeBundle(zip, strategy: strategy, onProgress: progress);
        outcomes.forEach(reportWrite);
      });
}

class _PrintBundle extends _Command {
  @override
  final name = 'print-bundle';
  @override
  final description = 'Print the partition table and app info from a bundle ZIP';
  @override
  Future<void> run() async {
    final path = _arg(argResults!, 0, 'bundle file');
    final archive = ZipDecoder().decodeBytes(File(path).readAsBytesSync());
    final csv = archive.find('partition_table.csv') ?? (throw IdfToolException("Bundle '$path' has no partition_table.csv"));
    final table = parsePartitionTableCsv(PartitionTable.decodeCsv(csv.readBytes()!),
        source: "bundle '$path'", partitionTableOffset: partitionTableOffset);
    Future<Uint8List> read(int offset, int length) async {
      final p = table.where((p) => p.offset == offset).firstOrNull;
      final file = p == null ? null : archive.find('${p.name}.bin');
      final out = Uint8List(length)..fillRange(0, length, 0xFF);
      if (file != null) {
        final bytes = file.readBytes()!;
        out.setRange(0, bytes.length.clamp(0, length), bytes);
      }
      return out;
    }
    stdout.writeln('Bundle: $path\n');
    stdout.writeln(await _Command.tableWithApps(table, read));
  }
}

// ---------------------------------------------------------------------------
// Filesystems
// ---------------------------------------------------------------------------

FsType? _fsTypeOption(ArgResults r) {
  final t = r['type'] as String?;
  if (t == null) return null;
  return FsType.byLabel(t) ?? (throw UsageException("Unknown filesystem '$t' (fatfs, littlefs or spiffs)", ''));
}

void _addFsType(ArgParser p, String help) => p.addOption('type', abbr: 't', help: help);

/// Write a volume's contents under [destination]; refuses paths that escape it.
void _extractTo(FsVolume volume, String destination) {
  final root = Directory(destination)..createSync(recursive: true);
  final rootPath = root.resolveSymbolicLinksSync();
  for (final e in volume.entries) {
    final target = File('$rootPath/${e.path}');
    if (!target.absolute.path.startsWith(rootPath)) throw IdfToolException("Refusing to extract '${e.path}': it escapes $destination");
    if (e.isDir) {
      Directory(target.path).createSync(recursive: true);
    } else {
      target.parent.createSync(recursive: true);
      target.writeAsBytesSync(volume.read(e.path));
    }
  }
}

/// Every file under [source] (or the single file) as sources, paths relative
/// to it.
List<FsSource> _collect(String source) {
  final dir = Directory(source);
  if (dir.existsSync()) {
    final base = dir.absolute.path.replaceAll(RegExp(r'/$'), '');
    return [
      for (final f in dir.listSync(recursive: true, followLinks: false).whereType<File>())
        (path: f.absolute.path.substring(base.length + 1), bytes: f.readAsBytesSync(), modified: f.lastModifiedSync()),
    ]..sort((a, b) => a.path.compareTo(b.path));
  }
  final file = File(source);
  if (!file.existsSync()) throw IdfToolException("'$source' does not exist");
  return [(path: file.uri.pathSegments.last, bytes: file.readAsBytesSync(), modified: file.lastModifiedSync())];
}

void _warnFs(FsVolume v) {
  for (final e in v.errors) {
    stderr.writeln('Warning: $e');
  }
}

class _PrintFs extends _Command {
  @override
  final name = 'print-fs';
  @override
  final description = 'List the contents of a filesystem partition or --file image';
  _PrintFs() {
    argParser.addOption('file', abbr: 'f', help: 'Read the filesystem from this image file instead of the device');
    _addFsType(argParser, 'Filesystem to read (default: from the partition subtype, else detected)');
  }
  @override
  Future<void> run() async {
    final file = argResults!['file'] as String?;
    final partitionName = argResults!.rest.firstOrNull;
    if ((file == null) == (partitionName == null)) throw UsageException('Provide exactly one of a partition name or --file', '');
    if (file != null) {
      final image = _readFileArg(file, 'image');
      final v = FsVolume.mount(image, type: _fsTypeOption(argResults!));
      _warnFs(v);
      stdout.writeln("'$file': ${v.type.label}, ${hex(image.length)} bytes\n${formatFsListing(v.entries)}");
      return;
    }
    await withDevice((device, _) async {
      final (partition: p, volume: v) = await device.readFs(name: partitionName, type: _fsTypeOption(argResults!), onProgress: progress);
      _warnFs(v);
      stdout.writeln("Partition '${p.name}': ${v.type.label}, ${hex(p.size)} bytes\n${formatFsListing(v.entries)}");
    });
  }
}

class _ReadFs extends _Command {
  @override
  final name = 'read-fs';
  @override
  final description = 'Read a filesystem partition and extract it to a directory: PARTITION DESTINATION';
  _ReadFs() {
    _addFsType(argParser, 'Filesystem to read (default: from the partition subtype, else detected)');
  }
  @override
  Future<void> run() => withDevice((device, _) async {
        final partitionName = _arg(argResults!, 0, 'partition');
        final dest = _arg(argResults!, 1, 'destination');
        final (partition: p, volume: v) = await device.readFs(name: partitionName, type: _fsTypeOption(argResults!), onProgress: progress);
        _warnFs(v);
        _extractTo(v, dest);
        stdout.writeln(formatFsListing(v.entries));
        stderr.writeln("Extracted ${v.type.label} partition '${p.name}' to '$dest'");
      });
}

class _ExtractFs extends _Command {
  @override
  final name = 'extract-fs';
  @override
  final description = 'Extract a filesystem image file to a directory: IMAGE DESTINATION';
  _ExtractFs() {
    _addFsType(argParser, 'Filesystem to read (default: detected from the image)');
  }
  @override
  Future<void> run() async {
    final path = _arg(argResults!, 0, 'image file');
    final dest = _arg(argResults!, 1, 'destination');
    final v = FsVolume.mount(_readFileArg(path, 'image'), type: _fsTypeOption(argResults!));
    _warnFs(v);
    _extractTo(v, dest);
    stdout.writeln(formatFsListing(v.entries));
    stderr.writeln("Extracted ${v.type.label} image '$path' to '$dest'");
  }
}

class _CreateFs extends _Command {
  @override
  final name = 'create-fs';
  @override
  final description = 'Build a filesystem image from a directory: SOURCE OUTPUT';
  _CreateFs() {
    _addFsType(argParser, 'Filesystem to build (default: from --partition)');
    argParser.addOption('size', help: 'Image size in bytes (e.g. 0x40000)');
    argParser.addOption('partition', help: 'Partition to take the size and type from (--partition-table-file)');
  }
  @override
  Future<void> run() async {
    final source = _arg(argResults!, 0, 'source directory');
    final out = _arg(argResults!, 1, 'output file');
    PartitionDefinition? partition;
    if (argResults!['partition'] != null) {
      final table = tableFromFile(null) ?? (throw UsageException('--partition needs --partition-table-file', ''));
      partition = table.findByName(argResults!['partition'] as String) ??
          (throw IdfToolException("No partition named '${argResults!['partition']}'"));
    }
    final size = argResults!['size'] != null ? _int(argResults!['size'] as String, what: 'size') : partition?.size ?? (throw UsageException('Pass --size or --partition', ''));
    final type = FsType.resolve(explicit: _fsTypeOption(argResults!), partition: partition);
    final image = createFs(type, _collect(source), size);
    File(out).writeAsBytesSync(image);
    final v = FsVolume.mount(image, type: type);
    stdout.writeln(formatFsListing(v.entries));
    stderr.writeln('Wrote ${type.label} image (${hex(image.length)} bytes) to $out');
  }
}

class _WriteFs extends _Command {
  @override
  final name = 'write-fs';
  @override
  final description = 'Build a filesystem image from a directory (or take a prebuilt image) and flash it: PARTITION SOURCE';
  _WriteFs() {
    _addFsType(argParser, 'Filesystem to build (default: from the partition subtype)');
  }
  @override
  Future<void> run() => withDevice((device, _) async {
        final partitionName = _arg(argResults!, 0, 'partition');
        final source = _arg(argResults!, 1, 'source');
        final partition = await device.fsPartition(partitionName);
        final type = FsType.resolve(explicit: _fsTypeOption(argResults!), partition: partition, what: "'$source'");
        Uint8List image;
        if (Directory(source).existsSync()) {
          image = createFs(type, _collect(source), partition.size);
        } else {
          final data = _readFileArg(source, 'source');
          if (FsType.detect(data) == type) {
            if (data.length < partition.size) {
              stderr.writeln('Warning: image is ${hex(data.length)} bytes, smaller than partition '
                  "'${partition.name}' (${hex(partition.size)}) — it was built for a different size and may not mount");
            }
            image = data;
          } else {
            image = createFs(type, _collect(source), partition.size);
          }
        }
        stdout.writeln(formatFsListing(FsVolume.mount(image, type: type).entries));
        reportWrite(partition.name, await device.writeFs(image, partitionName: partition.name, strategy: strategy, onProgress: progress));
      });
}
