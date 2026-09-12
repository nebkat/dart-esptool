import 'dart:async';
import 'dart:js_interop';

import 'package:esptool/esptool.dart';
import 'package:esptool/web.dart';
import 'package:flutter/foundation.dart';
import 'package:idftool/idftool.dart';
import 'package:web/web.dart' as web;

import 'flash_plan.dart';

/// How to get the chip into download mode when connecting.
enum ResetChoice {
  auto('Auto'),
  usbJtag('USB-JTAG'),
  classic('Classic DTR/RTS'),
  none('None (already in download mode)');

  const ResetChoice(this.label);
  final String label;
}

enum SessionState { disconnected, connecting, connected, busy }

/// What probing a port found — python idftool's `probe_port` record.
class PortIdentity {
  const PortIdentity({this.chip, this.mac, this.error});
  final EspChip? chip;
  final String? mac;

  /// Why the port couldn't be identified (busy, no response, ...).
  final String? error;

  String get label => error != null
      ? 'unavailable: $error'
      : chip == null
          ? 'unidentified'
          : [chip!.name, if (mac != null) mac!].join(' · ');
}

class LogLine {
  LogLine(this.message, {this.error = false}) : time = DateTime.now();
  final DateTime time;
  final String message;
  final bool error;
}

/// A running operation's progress, for the UI.
class Progress {
  const Progress(this.label, this.done, this.total);
  final String label;
  final int done;
  final int total;
  double get fraction => total == 0 ? 0 : done / total;
}

/// The one connection the app holds to a device: port selection, the
/// transport and loader, chip facts learned at connect time, a log, and a
/// queue that runs operations one at a time.
///
/// Unlike the plain-Dart demo this keeps the port open between operations —
/// reconnecting costs a reset and a stub upload each time.
class DeviceSession extends ChangeNotifier {
  DeviceSession() {
    final s = serial;
    if (s != null) {
      s.addEventListener('connect', _onPortsChanged.toJS);
      s.addEventListener('disconnect', _onPortsChanged.toJS);
      refreshPorts();
    }
  }

  static bool get supported => serial != null;

  List<SerialPort> ports = const [];
  SerialPort? selectedPort;
  ResetChoice reset = ResetChoice.auto;
  bool useStub = true;

  SessionState state = SessionState.disconnected;
  WebSerialTransport? _transport;
  EspLoader? _loader;
  IdfDevice? _device;
  EspChip? chip;
  int? flashSize;
  Uint8List? mac;
  String? flashId;
  Progress? progress;
  String? currentOperation;

  final List<LogLine> log = [];

  /// What each granted port turned out to be, learned by connecting to it or
  /// by [identifyAll]. Web Serial hides the OS path, so this is the only way
  /// to tell two identical adapters apart.
  final Map<SerialPort, PortIdentity> identities = {};
  bool _identifying = false;

  /// [describePort] plus whatever [identities] knows about it.
  String labelFor(SerialPort port) {
    final id = identities[port];
    return id == null ? describePort(port) : '${describePort(port)} — ${id.label}';
  }

  /// Changes queued for the connected device (see [FlashPlan]).
  final FlashPlan plan = FlashPlan();

  EspLoader? get loader => _loader;

  /// The idftool device layer over [loader], while connected.
  IdfDevice? get device => _device;
  bool get connected => state == SessionState.connected || state == SessionState.busy;
  bool get busy => state == SessionState.busy || state == SessionState.connecting || _identifying;

  void _onPortsChanged(web.Event _) => refreshPorts();

  Future<void> refreshPorts() async {
    final s = serial;
    if (s == null) return;
    ports = (await s.getPorts().toDart).toDart;
    if (selectedPort != null && !ports.contains(selectedPort)) {
      selectedPort = null;
      if (connected) _lost('Port disconnected');
    }
    selectedPort ??= ports.firstOrNull;
    notifyListeners();
  }

  /// Show the browser's port chooser (needs a user gesture).
  Future<void> requestPort() async {
    final s = serial;
    if (s == null) return;
    try {
      selectedPort = await s.requestPort().toDart;
    } catch (_) {
      return; // user cancelled the chooser
    }
    await refreshPorts();
  }

  void selectPort(SerialPort? port) {
    selectedPort = port;
    notifyListeners();
  }

  void setReset(ResetChoice value) {
    reset = value;
    notifyListeners();
  }

  void setUseStub(bool value) {
    useStub = value;
    notifyListeners();
  }

  void addLog(String message, {bool error = false}) {
    log.add(LogLine(message, error: error));
    if (log.length > 2000) log.removeRange(0, log.length - 2000);
    notifyListeners();
  }

  void clearLog() {
    log.clear();
    notifyListeners();
  }

  static String describePort(SerialPort port) {
    final info = port.getInfo();
    final vid = info.usbVendorId;
    if (vid == null) return 'Serial port';
    final pid = info.usbProductId ?? 0;
    final vendor = switch (vid) {
      0x303A => pid == 0x1001 ? 'Espressif USB-Serial/JTAG' : 'Espressif USB-OTG',
      0x10C4 => 'Silicon Labs CP210x',
      0x1A86 => 'WCH CH34x',
      0x0403 => 'FTDI',
      0x067B => 'Prolific PL2303',
      _ => 'USB serial',
    };
    return '$vendor (${_hex(vid, 4)}:${_hex(pid, 4)})';
  }

  static bool _isNativeUsb(SerialPort port) => port.getInfo().usbVendorId == 0x303A;

  Future<void> connect() async {
    final port = selectedPort;
    if (port == null || connected || busy) return;
    state = SessionState.connecting;
    notifyListeners();
    final stopwatch = Stopwatch()..start();
    addLog('Connecting to ${describePort(port)} ...');
    try {
      final transport = await WebSerialTransport.open(port);
      _transport = transport;
      final info = port.getInfo();
      final usbOtg = _isNativeUsb(port) && EspChip.values.any((c) => c.imageChipId == info.usbProductId);
      final loader = EspLoader(transport, usbOtg: usbOtg);
      _loader = loader;

      final strategies = _strategies(port);
      EspChip? detected;
      Object? lastError;
      for (final (strategy, name) in strategies) {
        try {
          detected = await loader
              .connect(reset: strategy, attempts: 3)
              .timeout(const Duration(seconds: 15), onTimeout: () => throw EspConnectException('$name reset timed out'));
          break;
        } on EspConnectException catch (e) {
          lastError = e;
          addLog('  $name reset: ${e.message}');
        }
      }
      if (detected == null) {
        throw EspConnectException(
            'Could not sync with the chip. Hold BOOT and tap RESET, then connect with reset = none.', lastError);
      }
      chip = detected;
      flashSize = await loader.attachFlash();
      final device = IdfDevice(loader);
      _device = device;
      plan.attach(
        chip: detected,
        partitionTableOffset: device.partitionTableOffset,
        partitionTableSize: device.partitionTableSize,
        primaryBootloaderOffset: device.primaryBootloaderOffset,
      );
      if (useStub) {
        await loader.runStub();
      }
      mac = await loader.readMac();
      identities[port] = PortIdentity(chip: detected, mac: macString);
      final id = await loader.flashId();
      flashId = _hex(id, 6);
      addLog('Connected: ${detected.name}, ${flashSize == null ? 'unknown flash size' : _mb(flashSize!)} flash, '
          'MAC ${macString ?? '?'}${loader.isStub ? ', stub running' : ' (ROM loader)'} '
          'in ${stopwatch.elapsedMilliseconds} ms');
      state = SessionState.connected;
    } catch (e) {
      addLog('Connect failed: $e', error: true);
      await _close();
      state = SessionState.disconnected;
    }
    notifyListeners();
  }

  String? get macString => _formatMac(mac);
  static String? _formatMac(Uint8List? mac) => mac?.map((b) => b.toRadixString(16).padLeft(2, '0')).join(':');

  List<(EspReset, String)> _strategies(SerialPort port) => switch (reset) {
        ResetChoice.auto => _isNativeUsb(port)
            ? [(EspResets.usbJtag(), 'USB-JTAG'), (EspResets.classic(), 'classic')]
            : [(EspResets.classic(), 'classic'), (EspResets.usbJtag(), 'USB-JTAG')],
        ResetChoice.usbJtag => [(EspResets.usbJtag(), 'USB-JTAG')],
        ResetChoice.classic => [(EspResets.classic(), 'classic')],
        ResetChoice.none => [(EspResets.none, 'no')],
      };

  /// Probe every granted port that isn't the live connection: reset into the
  /// bootloader, read chip and MAC, reset back into the app. Like python
  /// idftool's device picker, this reboots each device it touches.
  Future<void> identifyAll() async {
    if (_identifying || busy) return;
    _identifying = true;
    notifyListeners();
    try {
      for (final port in List.of(ports)) {
        if (connected && port == selectedPort) continue;
        identities[port] = await _probe(port);
        addLog('${describePort(port)}: ${identities[port]!.label}');
        notifyListeners();
      }
    } finally {
      _identifying = false;
      notifyListeners();
    }
  }

  Future<PortIdentity> _probe(SerialPort port) async {
    WebSerialTransport? transport;
    try {
      transport = await WebSerialTransport.open(port);
    } catch (e) {
      return PortIdentity(error: '$e'.contains('Failed to open') ? 'port is in use' : '$e');
    }
    final loader = EspLoader(transport);
    try {
      EspChip? chip;
      for (final (strategy, _) in _strategies(port)) {
        try {
          chip = await loader.connect(reset: strategy, attempts: 2).timeout(const Duration(seconds: 8));
          break;
        } catch (_) {}
      }
      if (chip == null) return const PortIdentity(error: 'no response — not an ESP, or not resettable');
      String? mac;
      try {
        mac = _formatMac(await loader.readMac());
      } catch (_) {}
      try {
        await loader.hardReset().timeout(const Duration(seconds: 3));
      } catch (_) {}
      return PortIdentity(chip: chip, mac: mac);
    } finally {
      await loader.dispose();
      try {
        await transport.close().timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
  }

  /// Close the port, optionally rebooting the chip into its application first.
  Future<void> disconnect({bool hardReset = true}) async {
    if (!connected) return;
    if (hardReset) {
      try {
        await _loader?.hardReset().timeout(const Duration(seconds: 5));
        addLog('Chip reset');
      } catch (e) {
        addLog('Hard reset failed: $e', error: true);
      }
    }
    await _close();
    state = SessionState.disconnected;
    addLog('Disconnected');
    notifyListeners();
  }

  void _lost(String why) {
    addLog(why, error: true);
    unawaited(_close());
    state = SessionState.disconnected;
  }

  Future<void> _close() async {
    final loader = _loader;
    final transport = _transport;
    _loader = null;
    _device = null;
    plan.detach();
    _transport = null;
    chip = null;
    flashSize = null;
    mac = null;
    flashId = null;
    await loader?.dispose();
    try {
      await transport?.close().timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  /// Run [op] against the connected loader as the one active operation,
  /// logging failures. Returns `null` if it failed or nothing is connected.
  Future<T?> run<T>(String label, Future<T> Function(EspLoader loader) op) =>
      runDevice(label, (device) => op(device.loader));

  /// [run], handing the operation the [IdfDevice].
  Future<T?> runDevice<T>(String label, Future<T> Function(IdfDevice device) op) async {
    final device = _device;
    if (device == null || state != SessionState.connected) {
      addLog('Not connected', error: true);
      return null;
    }
    state = SessionState.busy;
    currentOperation = label;
    progress = null;
    notifyListeners();
    final stopwatch = Stopwatch()..start();
    try {
      final result = await op(device);
      addLog('$label: done in ${_seconds(stopwatch.elapsed)}');
      return result;
    } catch (e) {
      addLog('$label failed: $e', error: true);
      // Only a port that has actually gone away means the connection is
      // lost; anything else (protocol, input or a bug) leaves it usable.
      if (!(_transport?.port.connected ?? false)) _lost('Connection lost');
      return null;
    } finally {
      if (state == SessionState.busy) state = SessionState.connected;
      currentOperation = null;
      progress = null;
      notifyListeners();
    }
  }

  /// Progress callback for the running operation (an idftool [ProgressCallback]).
  void reportProgress(String label, int done, int total) {
    progress = Progress(label, done, total);
    // Repainting the whole app on every 4 KiB frame starves the serial read
    // loop; a native-USB chip then drops bytes. Coalesce to ~15 Hz, but
    // always show the final state.
    final now = DateTime.now();
    if (done >= total || _lastProgressNotify == null || now.difference(_lastProgressNotify!).inMilliseconds >= 66) {
      _lastProgressNotify = now;
      notifyListeners();
    }
  }

  DateTime? _lastProgressNotify;

  @override
  void dispose() {
    plan.dispose();
    super.dispose();
  }

  static String _hex(int v, int width) => '0x${v.toRadixString(16).padLeft(width, '0')}';
  static String _mb(int bytes) => '${bytes ~/ (1024 * 1024)} MB';
  static String _seconds(Duration d) => '${(d.inMilliseconds / 1000).toStringAsFixed(2)} s';
}

extension SessionFormatting on int {
  String get hex => '0x${toRadixString(16)}';
  String get bytesString {
    if (this >= 1024 * 1024) return '${(this / (1024 * 1024)).toStringAsFixed(this % (1024 * 1024) == 0 ? 0 : 2)} MiB';
    if (this >= 1024) return '${(this / 1024).toStringAsFixed(this % 1024 == 0 ? 0 : 1)} KiB';
    return '$this B';
  }
}
