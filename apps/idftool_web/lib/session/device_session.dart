import 'dart:async';
import 'dart:js_interop';

import 'package:esptool/esptool.dart';
import 'package:esptool/web.dart';
import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

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
  EspChip? chip;
  int? flashSize;
  Uint8List? mac;
  String? flashId;
  Progress? progress;
  String? currentOperation;

  final List<LogLine> log = [];

  EspLoader? get loader => _loader;
  bool get connected => state == SessionState.connected || state == SessionState.busy;
  bool get busy => state == SessionState.busy || state == SessionState.connecting;

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

      final strategies = switch (reset) {
        ResetChoice.auto => _isNativeUsb(port)
            ? [(EspResets.usbJtag(), 'USB-JTAG'), (EspResets.classic(), 'classic')]
            : [(EspResets.classic(), 'classic'), (EspResets.usbJtag(), 'USB-JTAG')],
        ResetChoice.usbJtag => [(EspResets.usbJtag(), 'USB-JTAG')],
        ResetChoice.classic => [(EspResets.classic(), 'classic')],
        ResetChoice.none => [(EspResets.none, 'no')],
      };
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
      if (useStub) {
        await loader.runStub();
      }
      mac = await loader.readMac();
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

  String? get macString => mac?.map((b) => b.toRadixString(16).padLeft(2, '0')).join(':');

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
  Future<T?> run<T>(String label, Future<T> Function(EspLoader loader) op) async {
    final loader = _loader;
    if (loader == null || state != SessionState.connected) {
      addLog('Not connected', error: true);
      return null;
    }
    state = SessionState.busy;
    currentOperation = label;
    progress = null;
    notifyListeners();
    final stopwatch = Stopwatch()..start();
    try {
      final result = await op(loader);
      addLog('$label: done in ${_seconds(stopwatch.elapsed)}');
      return result;
    } catch (e) {
      addLog('$label failed: $e', error: true);
      if (e is! EspException) {
        // Transport-level failure (device gone, port closed): the connection
        // can't be trusted any more.
        _lost('Connection lost');
      }
      return null;
    } finally {
      if (state == SessionState.busy) state = SessionState.connected;
      currentOperation = null;
      progress = null;
      notifyListeners();
    }
  }

  /// Progress callback for the running operation.
  void reportProgress(String label, int done, int total) {
    progress = Progress(label, done, total);
    notifyListeners();
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
