import 'dart:io';
import 'dart:typed_data';

import 'package:esptool/esptool.dart';

import 'libserialport_transport.dart';

/// A small CLI that exercises the [EspLoader] over a real serial port via
/// `package:libserialport`.
///
/// Usage:
///   dart run example/esptool_flex.dart                       # list ports
///   dart run example/esptool_flex.dart <port>                # chip info
///   dart run example/esptool_flex.dart <port> read  <addr> <len> <out.bin>
///   dart run example/esptool_flex.dart <port> write <addr> <in.bin>
///   dart run example/esptool_flex.dart <port> erase <addr> <len>
///
/// Addresses/lengths accept `0x`-prefixed hex or decimal, e.g. `0x1000`.
Future<void> main(List<String> args) async {
  // Point libserialport at the native C library before anything reads the
  // environment or loads it. Harmless if the library is already on the path.
  ensureLibserialportResolved();

  if (args.isEmpty) {
    final ports = LibSerialPortTransport.availablePorts;
    if (ports.isEmpty) {
      stderr.writeln('No serial ports found.');
    } else {
      stdout.writeln('Available serial ports:');
      for (final p in ports) {
        stdout.writeln('  $p');
      }
      stdout.writeln('\nRe-run with a port name to connect.');
    }
    return;
  }

  // `--no-reset` skips all DTR/RTS line control (put the board in download mode
  // manually: hold BOOT, tap RESET/EN, release BOOT). Needed for native-USB
  // boards on macOS, where toggling the reset lines can hang the USB stack.
  final noReset = args.contains('--no-reset');
  final positional = args.where((a) => a != '--no-reset').toList();

  final portName = positional[0];
  final command = positional.length > 1 ? positional[1] : 'info';

  final LibSerialPortTransport transport;
  try {
    transport = LibSerialPortTransport.open(portName);
  } catch (e) {
    stderr.writeln('Could not open $portName: $e');
    exitCode = 1;
    return;
  }
  final loader = EspLoader(transport);

  try {
    stdout.writeln('Connecting to $portName ...');
    // Native-USB chips (ports that enumerate as usbmodem/ttyACM) want the
    // USB-JTAG reset — the classic DTR/RTS reset pulses EN and would tear down
    // their USB. UART-bridge ports want the classic reset. Order accordingly.
    final nativeUsb = portName.contains('usbmodem') || portName.contains('ttyACM');
    final strategies = noReset
        ? <(String, EspReset)>[('no-reset', EspResets.none)]
        : <(String, EspReset)>[
            if (nativeUsb) ('usb-jtag', EspResets.usbJtag()) else ('classic', EspResets.classic()),
            if (nativeUsb) ('classic', EspResets.classic()) else ('usb-jtag', EspResets.usbJtag()),
          ];
    EspChip? chip;
    for (final (name, reset) in strategies) {
      try {
        stdout.writeln('  trying $name reset ...');
        chip = await loader
            .connect(reset: reset, attempts: 3)
            .timeout(const Duration(seconds: 15), onTimeout: () => throw EspConnectException('$name reset timed out'));
        break;
      } on EspConnectException catch (e) {
        stdout.writeln('    ${e.message}');
      }
    }
    if (chip == null) {
      throw EspConnectException('Could not sync with the chip. '
          'Hold BOOT (and tap EN/RESET) to force download mode, then retry.');
    }
    stdout.writeln('Connected. Detected chip: ${chip.name}');
    await loader.attachFlash();

    switch (command) {
      case 'info':
        await _info(loader);
      case 'read':
        await _read(loader, positional);
      case 'write':
        await _write(loader, positional);
      case 'erase':
        await _erase(loader, positional);
      default:
        stderr.writeln('Unknown command: $command');
        exitCode = 2;
        return;
    }

    // Leave the chip running the flashed application.
    stdout.writeln('Resetting chip ...');
    await loader.hardReset();
  } on EspException catch (e) {
    stderr.writeln('esptool error: ${e.message}');
    exitCode = 1;
  } finally {
    await loader.dispose();
    transport.close();
  }
}

Future<void> _info(EspLoader loader) async {
  final mac = await loader.readMac();
  stdout.writeln('MAC address:  ${_hexBytes(mac, separator: ':')}');

  final id = await loader.flashId();
  // RDID returns 24 bits: manufacturer (7:0), memory type (15:8), capacity (23:16).
  final manufacturer = id & 0xFF;
  final memoryType = (id >> 8) & 0xFF;
  final capacity = (id >> 16) & 0xFF;
  stdout.writeln('Flash JEDEC:  0x${id.toRadixString(16).padLeft(6, '0')} '
      '(manufacturer 0x${manufacturer.toRadixString(16).padLeft(2, '0')}, '
      'type 0x${memoryType.toRadixString(16).padLeft(2, '0')})');
  // For most SPI parts the capacity byte is the base-2 log of the size in bytes.
  if (capacity >= 0x14 && capacity <= 0x1A) {
    stdout.writeln('Flash size:   ${1 << capacity} bytes (~${(1 << capacity) ~/ (1024 * 1024)} MB)');
  }

  // Read the image header the ROM bootloader itself loads from (offset varies
  // by chip: 0x1000 on ESP32/S2, 0x0 on later chips).
  final bootloaderOffset = loader.chip?.bootloaderFlashOffset ?? 0x0;
  stdout.writeln('\nReading bootloader header at '
      '0x${bootloaderOffset.toRadixString(16)} ...');
  final header = await loader.readFlash(bootloaderOffset, 32);
  stdout.writeln(_hexDump(header, baseAddress: bootloaderOffset));
  if (header.isNotEmpty && header[0] == ImageHeader.magic) {
    stdout.writeln('Found ESP image magic (0xE9) — a bootloader is present.');
  }
}

Future<void> _read(EspLoader loader, List<String> args) async {
  if (args.length < 5) {
    stderr.writeln('Usage: <port> read <addr> <len> <out.bin>');
    exitCode = 2;
    return;
  }
  final addr = _parseInt(args[2]);
  final length = _parseInt(args[3]);
  final outPath = args[4];

  stdout.writeln('Reading $length bytes from 0x${addr.toRadixString(16)} ...');
  final data = await loader.readFlash(addr, length, onProgress: _progress('Read'));
  stdout.writeln('');
  await File(outPath).writeAsBytes(data);
  stdout.writeln('Wrote ${data.length} bytes to $outPath');
}

Future<void> _write(EspLoader loader, List<String> args) async {
  if (args.length < 4) {
    stderr.writeln('Usage: <port> write <addr> <in.bin>');
    exitCode = 2;
    return;
  }
  final addr = _parseInt(args[2]);
  final data = await File(args[3]).readAsBytes();

  stdout.writeln('Writing ${data.length} bytes to 0x${addr.toRadixString(16)} ...');
  await loader.writeFlash(addr, Uint8List.fromList(data), onProgress: _progress('Written'));
  stdout.writeln('');

  // Verify with an on-device MD5 over the written range.
  final deviceMd5 = await loader.flashMd5(addr, data.length);
  stdout.writeln('Device MD5 of written range: $deviceMd5');
}

Future<void> _erase(EspLoader loader, List<String> args) async {
  if (args.length < 4) {
    stderr.writeln('Usage: <port> erase <addr> <len>');
    exitCode = 2;
    return;
  }
  final addr = _parseInt(args[2]);
  final length = _parseInt(args[3]);
  stdout.writeln('Erasing $length bytes at 0x${addr.toRadixString(16)} ...');
  await loader.eraseRegion(addr, length);
  stdout.writeln('Done.');
}

void Function(int, int) _progress(String label) {
  return (done, total) {
    final pct = total == 0 ? 100 : (done * 100 ~/ total);
    stdout.write('\r$label: $done/$total bytes ($pct%)   ');
  };
}

int _parseInt(String s) => int.parse(s.startsWith('0x') ? s.substring(2) : s, radix: s.startsWith('0x') ? 16 : 10);

String _hexBytes(Uint8List bytes, {String separator = ' '}) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(separator);

String _hexDump(Uint8List data, {int baseAddress = 0}) {
  final buffer = StringBuffer();
  for (var i = 0; i < data.length; i += 16) {
    final end = (i + 16) < data.length ? i + 16 : data.length;
    final row = Uint8List.sublistView(data, i, end);
    buffer.write('0x${(baseAddress + i).toRadixString(16).padLeft(8, '0')}  ');
    buffer.writeln(_hexBytes(row));
  }
  return buffer.toString().trimRight();
}
