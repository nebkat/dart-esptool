import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:esptool/esptool.dart';
import 'package:esptool/web.dart';
import 'package:flutter/foundation.dart';
import 'package:idftool/idftool.dart';
import 'package:web/web.dart' as web;

import 'flash_plan.dart';
import 'monitor_log.dart';

export '../util/format.dart';
export 'monitor_log.dart';

/// How to get the chip into download mode when connecting.
enum ResetChoice {
  auto('Auto'),
  usbJtag('USB-JTAG'),
  classic('Classic DTR/RTS'),
  none('None (already in download mode)');

  const ResetChoice(this.label);
  final String label;
}

/// [connected] and [busy] talk to the bootloader; in [monitoring] the chip
/// runs its app and the port carries its console instead.
enum SessionState { disconnected, connecting, connected, busy, monitoring }

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

  /// Keys for encrypted NVS partitions, derived from the HMAC key entered
  /// this session. Held in memory only — never saved.
  NvsKeys? nvsKeys;

  void setNvsKeys(NvsKeys? keys) {
    nvsKeys = keys;
    notifyListeners();
  }

  /// Baud rate for [startMonitor]: the app's console rate.
  int monitorBaud = 115200;

  /// The monitor's scrollback and filter. Outlives a monitor run, so the
  /// output is still there after stopping.
  final MonitorLog monitorLog = MonitorLog();

  StreamSubscription<List<int>>? _monitorSubscription;
  int _transportBaud = 115200;

  /// Set while monitoring when the port has gone away — a native-USB chip
  /// re-enumerating after a reset — and the session is waiting for it.
  ({int? vendor, int? product, DateTime since})? _awaitingPort;
  bool _reattaching = false;

  bool get monitorWaiting => _awaitingPort != null;

  void setMonitorBaud(int baud) {
    monitorBaud = baud;
    notifyListeners();
  }

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

  /// Changes queued for the connected device (see [FlashPlan]); also holds
  /// the device's layout once [readLayout] has run.
  final FlashPlan plan = FlashPlan();
  bool _layoutAttempted = false;

  EspLoader? get loader => _loader;

  /// The idftool device layer over [loader], while connected.
  IdfDevice? get device => _device;
  bool get connected => state == SessionState.connected || state == SessionState.busy;
  bool get busy => state == SessionState.busy || state == SessionState.connecting || _identifying;

  /// The chip is running its app and the port carries its console (see
  /// [startMonitor]). There is no loader, so nothing that talks to the
  /// bootloader is available.
  bool get monitoring => state == SessionState.monitoring;

  /// Whether the port is open, in either mode.
  bool get portOpen => connected || monitoring;

  void _onPortsChanged(web.Event _) => refreshPorts();

  Future<void> refreshPorts() async {
    final s = serial;
    if (s == null) return;
    ports = (await s.getPorts().toDart).toDart;
    if (_awaitingPort != null) {
      unawaited(_reattachMonitor());
    } else if (selectedPort != null && !ports.contains(selectedPort)) {
      if (connected) _lost('Port disconnected');
      if (monitoring) _monitorDropped();
      selectedPort = null;
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
    if (port == null || portOpen || busy) return;
    state = SessionState.connecting;
    notifyListeners();
    addLog('Connecting to ${describePort(port)} ...');
    try {
      final transport = await WebSerialTransport.open(port);
      _transport = transport;
      _transportBaud = 115200;
      await _startLoader(port, transport);
    } catch (e) {
      addLog('Connect failed: $e', error: true);
      await _close();
      state = SessionState.disconnected;
    }
    notifyListeners();
  }

  /// Reset into the bootloader over the open [transport], sync, and bring up
  /// the loader, device and stub. Leaves the session connected, or throws.
  Future<void> _startLoader(SerialPort port, WebSerialTransport transport) async {
    final stopwatch = Stopwatch()..start();
    {
      final info = port.getInfo();
      final usbOtg = _isNativeUsb(port) && EspChip.values.any((c) => c.imageChipId == info.usbProductId);
      final loader = EspLoader(transport, usbOtg: usbOtg);
      _loader = loader;

      final strategies = _strategies(port);
      EspChip? detected;
      Object? lastError;
      for (final (strategy, name) in strategies) {
        try {
          detected = await loader.connect(reset: strategy, attempts: 3).timeout(const Duration(seconds: 15), onTimeout: () => throw EspConnectException('$name reset timed out'));
          break;
        } on EspConnectException catch (e) {
          lastError = e;
          addLog('  $name reset: ${e.message}');
        }
      }
      if (detected == null) {
        throw EspConnectException('Could not sync with the chip. Hold BOOT and tap RESET, then connect with reset = none.', lastError);
      }
      chip = detected;
      flashSize = await loader.attachFlash();
      final device = IdfDevice(loader);
      _device = device;
      _layoutAttempted = false;
      for (final note in plan.attach(
        chip: detected,
        partitionTableOffset: device.partitionTableOffset,
        partitionTableSize: device.partitionTableSize,
        primaryBootloaderOffset: device.primaryBootloaderOffset,
      )) {
        addLog(note, error: true);
      }
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
    }
  }

  String? get macString => _formatMac(mac);
  static String? _formatMac(Uint8List? mac) => mac?.map((b) => b.toRadixString(16).padLeft(2, '0')).join(':');

  List<(EspReset, String)> _strategies(SerialPort port) => switch (reset) {
        ResetChoice.auto =>
          _isNativeUsb(port) ? [(EspResets.usbJtag(), 'USB-JTAG'), (EspResets.classic(), 'classic')] : [(EspResets.classic(), 'classic'), (EspResets.usbJtag(), 'USB-JTAG')],
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
        if (portOpen && port == selectedPort) continue;
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

  // --------------------------------------------------------------------------
  // Monitor
  // --------------------------------------------------------------------------

  /// Start monitoring the app's console at [monitorBaud]. From the
  /// bootloader, the chip is reset into its app on the open port; otherwise
  /// the port is opened and, unless [reset] is false, the chip reset.
  Future<void> startMonitor({bool reset = true}) async {
    final port = selectedPort;
    if (port == null || monitoring || busy) return;
    final fromLoader = connected;
    reset |= fromLoader;
    state = SessionState.connecting;
    notifyListeners();
    try {
      if (fromLoader) {
        await _loader?.dispose();
        _loader = null;
        _device = null;
        plan.detach();
        flashSize = null;
        flashId = null;
      } else {
        _transport = await WebSerialTransport.open(port, baudRate: monitorBaud);
        _transportBaud = monitorBaud;
      }
      final transport = _transport!;
      if (_transportBaud != monitorBaud) {
        await transport.setBaudRate(monitorBaud);
        _transportBaud = monitorBaud;
      }
      _listenMonitor(transport);
      monitorLog.note('── Monitoring at $monitorBaud baud${reset ? ', resetting into the app' : ''}');
      state = SessionState.monitoring;
      addLog('Monitoring ${describePort(port)} at $monitorBaud baud');
      if (reset) {
        await _resetOrDrop(transport);
      } else {
        await _releaseLines(transport);
      }
    } catch (e) {
      addLog('Monitor failed: $e', error: true);
      await _close();
      state = SessionState.disconnected;
    }
    notifyListeners();
  }

  /// Reboot the chip into its app while monitoring.
  Future<void> monitorReset() async {
    final transport = _transport;
    if (!monitoring || monitorWaiting || transport == null) return;
    monitorLog.note('── Reset');
    await _resetOrDrop(transport);
  }

  /// Send [text] to the app's console.
  Future<void> monitorSend(String text) async {
    final transport = _transport;
    if (!monitoring || monitorWaiting || transport == null) return;
    try {
      await transport.write(Uint8List.fromList(utf8.encode(text)));
    } catch (e) {
      addLog('Send failed: $e', error: true);
    }
  }

  /// Stop monitoring and close the port — or, with [enterBootloader], reset
  /// into the bootloader on the open port and connect as [connect] would.
  Future<void> stopMonitor({bool enterBootloader = false}) async {
    if (!monitoring) return;
    await _stopListening();
    monitorLog.flush();
    monitorLog.note('── Monitor stopped');
    final port = selectedPort;
    final transport = _transport;
    if (!enterBootloader || monitorWaiting || port == null || transport == null) {
      await _close();
      state = SessionState.disconnected;
      addLog('Monitor stopped');
      notifyListeners();
      return;
    }
    state = SessionState.connecting;
    notifyListeners();
    addLog('Entering the bootloader ...');
    try {
      if (_transportBaud != 115200) {
        await transport.setBaudRate(115200);
        _transportBaud = 115200;
      }
      await _startLoader(port, transport);
    } catch (e) {
      addLog('Connect failed: $e', error: true);
      await _close();
      state = SessionState.disconnected;
    }
    notifyListeners();
  }

  void _listenMonitor(WebSerialTransport transport) {
    _monitorSubscription = transport.input.listen(monitorLog.add, onError: (Object _) => _monitorDropped());
  }

  Future<void> _stopListening() async {
    final subscription = _monitorSubscription;
    _monitorSubscription = null;
    await subscription?.cancel();
  }

  /// Pulse EN with GPIO0 released (RTS high, DTR low, together), as
  /// `idf.py monitor` resets into the app. A native-USB chip may drop off the
  /// bus doing so; that is handled as a dropped port, not an error.
  Future<void> _resetOrDrop(WebSerialTransport transport) async {
    try {
      await transport.port.setSignals(SerialOutputSignals(dataTerminalReady: false, requestToSend: true)).toDart;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await transport.port.setSignals(SerialOutputSignals(dataTerminalReady: false, requestToSend: false)).toDart;
    } catch (e) {
      if (transport.port.connected) {
        addLog('Reset failed: $e', error: true);
      } else {
        _monitorDropped();
      }
    }
  }

  /// Deassert DTR and RTS together, which opening the port may have
  /// asserted, so the chip is neither held in reset nor reset.
  Future<void> _releaseLines(WebSerialTransport transport) async {
    try {
      await transport.port.setSignals(SerialOutputSignals(dataTerminalReady: false, requestToSend: false)).toDart;
    } catch (_) {}
  }

  /// The port went away while monitoring. Wait a while for the same kind of
  /// device to come back, and pick up where the monitor left off.
  void _monitorDropped() {
    if (!monitoring || _awaitingPort != null) return;
    final transport = _transport;
    final info = transport?.port.getInfo();
    final since = DateTime.now();
    _awaitingPort = (vendor: info?.usbVendorId, product: info?.usbProductId, since: since);
    monitorLog.flush();
    monitorLog.note('── Port lost, waiting for the device to come back');
    unawaited(_stopListening());
    _transport = null;
    if (transport != null) unawaited(_closeQuietly(transport));
    notifyListeners();
    unawaited(_reattachMonitor());
    Timer(const Duration(seconds: 15), () {
      if (_awaitingPort?.since != since) return;
      _awaitingPort = null;
      monitorLog.note('── The port did not come back');
      addLog('Monitor: the port did not come back', error: true);
      unawaited(_close());
      state = SessionState.disconnected;
      notifyListeners();
    });
  }

  Future<void> _reattachMonitor() async {
    final wanted = _awaitingPort;
    final s = serial;
    if (wanted == null || s == null || _reattaching) return;
    _reattaching = true;
    try {
      for (var attempt = 0; attempt < 20 && identical(_awaitingPort, wanted); attempt++) {
        final granted = (await s.getPorts().toDart).toDart;
        final matching = [
          for (final p in granted)
            if (p.connected && p.getInfo().usbVendorId == wanted.vendor && p.getInfo().usbProductId == wanted.product) p,
        ];
        final port = matching.contains(selectedPort) ? selectedPort : (matching.length == 1 ? matching.single : null);
        if (port != null) {
          try {
            final transport = await WebSerialTransport.open(port, baudRate: monitorBaud);
            if (!identical(_awaitingPort, wanted)) {
              await _closeQuietly(transport);
              return;
            }
            _transport = transport;
            _transportBaud = monitorBaud;
            selectedPort = port;
            _awaitingPort = null;
            _listenMonitor(transport);
            await _releaseLines(transport);
            monitorLog.note('── Reconnected');
            notifyListeners();
            return;
          } catch (_) {
            // Not openable yet; try again shortly.
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    } finally {
      _reattaching = false;
    }
  }

  static Future<void> _closeQuietly(WebSerialTransport transport) async {
    try {
      await transport.close().timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  void _lost(String why) {
    addLog(why, error: true);
    unawaited(_close());
    state = SessionState.disconnected;
  }

  Future<void> _close() async {
    await _stopListening();
    _awaitingPort = null;
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
  Future<T?> run<T>(String label, Future<T> Function(EspLoader loader) op) => runDevice(label, (device) => op(device.loader));

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

  /// Read the partition table, OTA selection and app descriptors into [plan].
  Future<void> readLayout() => runDevice('Read partition table', (device) async {
        final table = await device.partitionTable(refresh: true);
        OtaDataParameters? otadata;
        try {
          otadata = (await device.readOtadata()).otadata;
        } on IdfToolException {
          // no OTA layout on this table
        }
        // The app descriptor sits right after the image header and the first
        // segment header, so a small read per app partition names the firmware.
        final apps = <int, AppDescription>{};
        for (final p in table.where((p) => p.isApp)) {
          final head = await device.loader.readFlash(p.offset, ImageHeader.size + 8 + AppDescription.size);
          final desc = AppDescription.fromBytesOrNull(Uint8List.sublistView(head, ImageHeader.size + 8));
          if (desc != null) apps[p.offset] = desc;
        }
        for (final note in plan.setDeviceTable(table, apps: apps, otadata: otadata)) {
          addLog(note, error: true);
        }
      });

  /// [readLayout] once per connection, the first time a page asks while the
  /// device is idle. A failed read is not retried automatically.
  void ensureLayout() {
    if (!connected || busy || _layoutAttempted) return;
    _layoutAttempted = true;
    unawaited(readLayout());
  }

  /// `<chip>-<mac>`, for naming files dumped from the device.
  String get deviceStem => '${chip!.name.toLowerCase()}-${macString?.replaceAll(':', '') ?? 'device'}';

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
    monitorLog.dispose();
    super.dispose();
  }

  static String _hex(int v, int width) => '0x${v.toRadixString(16).padLeft(width, '0')}';
  static String _mb(int bytes) => '${bytes ~/ (1024 * 1024)} MB';
  static String _seconds(Duration d) => '${(d.inMilliseconds / 1000).toStringAsFixed(2)} s';
}
