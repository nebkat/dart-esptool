import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:esptool/esptool.dart';
import 'package:web/web.dart' as web;

import 'package:esptool/web.dart';

final _log = web.document.getElementById('log') as web.HTMLPreElement;
final _portSelect = web.document.getElementById('port') as web.HTMLSelectElement;
final _progress = web.document.getElementById('progress') as web.HTMLProgressElement;

T _el<T extends JSObject>(String id) => web.document.getElementById(id)! as T;
String _value(String id) => _el<web.HTMLInputElement>(id).value;

var _ports = <SerialPort>[];
var _busy = false;

void main() {
  final s = serial;
  if (s == null) {
    _el<web.HTMLElement>('support').textContent =
        'Web Serial is unavailable — use Chrome/Edge on https:// or localhost.';
    for (final b in _buttons()) {
      b.disabled = true;
    }
    return;
  }

  s.addEventListener('connect', ((web.Event _) {
    log('[serial] connect event');
    _refreshPorts();
  }).toJS);
  s.addEventListener('disconnect', ((web.Event _) {
    log('[serial] disconnect event');
    _refreshPorts();
  }).toJS);

  _onClick('add-port', () async {
    final port = await s.requestPort().toDart;
    await _refreshPorts(select: port);
  });
  _onClick('info', () => _run('info', _info));
  _onClick('read', () => _run('read', _read));
  _onClick('write', () => _run('write', _write));
  _onClick('erase', () => _run('erase', _erase));
  _onClick('hard-reset', () => _run('hard reset', (_) async {}, connect: false, forceResetAfter: true));
  _onClick('clear', () async => _log.textContent = '');

  _refreshPorts();
}

Iterable<web.HTMLButtonElement> _buttons() sync* {
  final list = web.document.querySelectorAll('button');
  for (var i = 0; i < list.length; i++) {
    yield list.item(i)! as web.HTMLButtonElement;
  }
}

void _onClick(String id, Future<void> Function() handler) {
  _el<web.HTMLElement>(id).addEventListener('click', ((web.Event _) {
    handler().catchError((Object e) => log('ERROR: $e'));
  }).toJS);
}

final _t0 = web.window.performance.now();

void log(String message) {
  final t = ((web.window.performance.now() - _t0) / 1000).toStringAsFixed(3).padLeft(8);
  final line = '[$t] $message';
  _log.textContent = '${_log.textContent}$line\n';
  _log.scrollTop = _log.scrollHeight.toDouble();
  web.console.log('[esptool] $line'.toJS);
}

String _hex(int v, [int width = 4]) => '0x${v.toRadixString(16).padLeft(width, '0')}';

const _vendors = {
  0x303A: 'Espressif USB-Serial/JTAG',
  0x10C4: 'Silicon Labs CP210x',
  0x1A86: 'WCH CH34x',
  0x0403: 'FTDI',
  0x067B: 'Prolific PL2303',
};

String _label(SerialPort port) {
  final info = port.getInfo();
  final vid = info.usbVendorId;
  final pid = info.usbProductId;
  if (vid == null) return 'non-USB port';
  return '${_vendors[vid] ?? 'USB'} (${_hex(vid)}:${_hex(pid ?? 0)})';
}

bool _isNativeUsb(SerialPort port) => port.getInfo().usbVendorId == 0x303A;

Future<void> _refreshPorts({SerialPort? select}) async {
  final previous = select ?? _selectedPort;
  _ports = (await serial!.getPorts().toDart).toDart;
  _portSelect.innerHTML = ''.toJS;
  for (var i = 0; i < _ports.length; i++) {
    final option = web.HTMLOptionElement()
      ..value = '$i'
      ..text = '$i: ${_label(_ports[i])}';
    _portSelect.add(option);
    if (identical(_ports[i], previous) || _ports[i] == previous) _portSelect.selectedIndex = i;
  }
  if (_ports.isEmpty) {
    final option = web.HTMLOptionElement()..text = '(no ports granted — click "Add port…")';
    _portSelect.add(option);
  }
}

SerialPort? get _selectedPort {
  final i = _portSelect.selectedIndex;
  return i >= 0 && i < _ports.length ? _ports[i] : null;
}

EspReset _named(String name) => switch (name) {
      'usb-jtag' => EspResets.usbJtag(),
      'classic' => EspResets.classic(),
      _ => EspResets.none,
    };

Future<EspChip> _connect(EspLoader loader, SerialPort port) async {
  final choice = _el<web.HTMLSelectElement>('reset').value;
  final strategies = switch (choice) {
    'auto' => _isNativeUsb(port) ? ['usb-jtag', 'classic'] : ['classic', 'usb-jtag'],
    _ => [choice],
  };
  for (final name in strategies) {
    log('  trying $name reset ...');
    try {
      return await loader
          .connect(reset: _named(name), attempts: 3)
          .timeout(const Duration(seconds: 15), onTimeout: () => throw EspConnectException('$name reset timed out'));
    } on EspConnectException catch (e) {
      log('    ${e.message}${e.cause != null ? ' (${e.cause})' : ''}');
    }
  }
  throw EspConnectException('Could not sync with the chip. Hold BOOT and tap EN/RESET, then retry with reset=none.');
}

/// Open the selected port, sync with the ROM, run [action], optionally hard
/// reset, and close — logging timestamps at each step so hangs are visible.
Future<void> _run(
  String name,
  Future<void> Function(EspLoader loader) action, {
  bool connect = true,
  bool forceResetAfter = false,
}) async {
  if (_busy) return;
  final port = _selectedPort;
  if (port == null) {
    log('No port selected.');
    return;
  }
  _busy = true;
  for (final b in _buttons()) {
    b.disabled = true;
  }
  _progress.value = 0;
  final trace = _el<web.HTMLInputElement>('trace').checked ? (String m) => log('    · $m') : null;
  final stopwatch = Stopwatch()..start();
  log('=== $name on ${_label(port)}');

  WebSerialTransport? transport;
  EspLoader? loader;
  try {
    transport = await WebSerialTransport.open(port, trace: trace);
    // Over USB-OTG the ROM enumerates with the chip id as PID (USB-Serial/JTAG
    // is always 0x1001) and the stub must use smaller blocks.
    final info = port.getInfo();
    final usbOtg = _isNativeUsb(port) && EspChip.values.any((c) => c.imageChipId == info.usbProductId);
    loader = EspLoader(transport, usbOtg: usbOtg);
    if (connect) {
      final chip = await _connect(loader, port);
      log('Connected: ${chip.name} after ${stopwatch.elapsedMilliseconds} ms${usbOtg ? ' (USB-OTG)' : ''}');
      final flashSize = await loader.attachFlash();
      log('Flash attached: ${flashSize == null ? 'unknown size' : '${flashSize ~/ (1024 * 1024)} MB'}');
      if (_el<web.HTMLInputElement>('stub').checked) {
        final t = Stopwatch()..start();
        await loader.runStub();
        log('Stub flasher running (${t.elapsedMilliseconds} ms upload)');
      }
      final baud = int.parse(_el<web.HTMLSelectElement>('baud').value);
      if (baud != 115200) {
        await loader.changeBaudRate(baud);
        log('Baud rate changed to $baud');
      }
    }
    await action(loader);
    if (forceResetAfter || _el<web.HTMLInputElement>('reset-after').checked) {
      log('Hard reset ...');
      await loader.hardReset().timeout(const Duration(seconds: 5));
      log('Hard reset done');
    }
  } catch (e) {
    log('ERROR: $e');
  } finally {
    await loader?.dispose();
    await transport?.close().timeout(const Duration(seconds: 5), onTimeout: () => log('close() timed out'));
    log('=== $name finished in ${stopwatch.elapsedMilliseconds} ms');
    _busy = false;
    for (final b in _buttons()) {
      b.disabled = false;
    }
  }
}

void Function(int, int) _onProgress(String label) {
  var lastPct = -1;
  return (done, total) {
    _progress
      ..max = total.toDouble()
      ..value = done.toDouble();
    final pct = total == 0 ? 100 : done * 100 ~/ total;
    if (pct ~/ 10 != lastPct ~/ 10) log('  $label $done/$total ($pct%)');
    lastPct = pct;
  };
}

int _parseInt(String s) {
  s = s.trim();
  if (s.isEmpty) throw FormatException('missing value');
  return s.startsWith('0x') ? int.parse(s.substring(2), radix: 16) : int.parse(s);
}

String _hexBytes(Uint8List bytes, {String separator = ' '}) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(separator);

Future<void> _info(EspLoader loader) async {
  log('MAC address:  ${_hexBytes(await loader.readMac(), separator: ':')}');
  final id = await loader.flashId();
  final capacity = (id >> 16) & 0xFF;
  log('Flash JEDEC:  ${_hex(id, 6)} (manufacturer ${_hex(id & 0xFF, 2)}, type ${_hex((id >> 8) & 0xFF, 2)})');
  if (capacity >= 0x14 && capacity <= 0x1A) log('Flash size:   ${(1 << capacity) ~/ (1024 * 1024)} MB');

  final offset = loader.chip?.bootloaderFlashOffset ?? 0x0;
  if (!loader.isStub && loader.chip != EspChip.esp32) {
    // No ROM flash read on this chip; an on-device MD5 still proves flash access.
    log('READ_FLASH_SLOW is ESP32-ROM-only (needs the stub here).');
    log('MD5 of 32 KiB at ${_hex(offset, 6)}: ${await loader.flashMd5(offset, 0x8000)}');
    return;
  }
  final header = await loader.readFlash(offset, 32);
  for (var i = 0; i < header.length; i += 16) {
    log('${_hex(offset + i, 8)}  ${_hexBytes(Uint8List.sublistView(header, i, i + 16))}');
  }
  if (header.isNotEmpty && header[0] == ImageHeader.magic) log('ESP image magic (0xE9) found — bootloader present.');
}

Future<void> _read(EspLoader loader) async {
  final addr = _parseInt(_value('read-addr'));
  final length = _parseInt(_value('read-len'));
  log('Reading $length bytes from ${_hex(addr, 6)} ...');
  final stopwatch = Stopwatch()..start();
  final data = await loader.readFlash(addr, length, onProgress: _onProgress('read'));
  final rate = data.length / (stopwatch.elapsedMilliseconds / 1000) / 1024;
  log('Read ${data.length} bytes in ${stopwatch.elapsedMilliseconds} ms (${rate.toStringAsFixed(1)} KiB/s)');

  final blob = web.Blob(<JSAny>[data.toJS].toJS, web.BlobPropertyBag(type: 'application/octet-stream'));
  final url = web.URL.createObjectURL(blob);
  web.HTMLAnchorElement()
    ..href = url
    ..download = 'flash_${_hex(addr, 6)}_${_hex(length)}.bin'
    ..click();
  web.URL.revokeObjectURL(url);
}

Future<void> _write(EspLoader loader) async {
  final files = _el<web.HTMLInputElement>('write-file').files;
  if (files == null || files.length == 0) throw StateError('choose a file to write');
  final file = files.item(0)!;
  final addr = _parseInt(_value('write-addr'));
  final data = (await file.arrayBuffer().toDart).toDart.asUint8List();
  log('Writing ${file.name} (${data.length} bytes) to ${_hex(addr, 6)} ...');
  final stopwatch = Stopwatch()..start();
  await loader.writeFlash(addr, data, onProgress: _onProgress('written'));
  log('Wrote in ${stopwatch.elapsedMilliseconds} ms; verifying ...');
  log('Device MD5: ${await loader.flashMd5(addr, data.length)}');
}

Future<void> _erase(EspLoader loader) async {
  final addr = _parseInt(_value('erase-addr'));
  final length = _parseInt(_value('erase-len'));
  log('Erasing $length bytes at ${_hex(addr, 6)} ...');
  await loader.eraseRegion(addr, length);
  log('Erased.');
}
