import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:esptool/esptool.dart';
import 'package:ffi/ffi.dart';
import 'package:libserialport/libserialport.dart';

/// An [EspTransport] backed by `package:libserialport`, suitable for desktop
/// (Linux/macOS/Windows) and any other platform libserialport supports.
///
/// This is the glue the core `esptool` package deliberately leaves out: it maps
/// [EspLoader]'s byte/DTR/RTS needs onto a real serial port. Use it as a
/// template for other backends (`usb_serial` on Android, Web Serial, ...).
class LibSerialPortTransport extends EspTransport {
  LibSerialPortTransport._(this._port, this._reader, this._input);

  final SerialPort _port;
  final SerialPortReader _reader;
  final Stream<Uint8List> _input;

  /// Open [name] at [baudRate] (the ROM bootloader auto-bauds, so the exact
  /// value only needs to be one both ends can sustain).
  factory LibSerialPortTransport.open(String name, {int baudRate = 115200}) {
    final port = SerialPort(name);
    if (!port.openReadWrite()) {
      final error = SerialPort.lastError;
      port.dispose();
      throw StateError('Failed to open $name: $error');
    }

    // 8-N-1, flow control off so we own the DTR/RTS lines for the reset dance.
    final config = SerialPortConfig()
      ..baudRate = baudRate
      ..bits = 8
      ..parity = SerialPortParity.none
      ..stopBits = 1
      ..setFlowControl(SerialPortFlowControl.none);
    port.config = config;
    config.dispose();

    final reader = SerialPortReader(port);
    return LibSerialPortTransport._(port, reader, reader.stream.asBroadcastStream());
  }

  /// Names of the serial ports currently available on this machine.
  static List<String> get availablePorts => SerialPort.availablePorts;

  @override
  Stream<List<int>> get input => _input;

  @override
  Future<void> write(Uint8List data) async {
    // Blocking write with a generous timeout; libserialport returns the number
    // of bytes actually accepted.
    _port.write(data, timeout: 1000);
  }

  @override
  Future<void> setDtr(bool value) async => _setLine('dtr', _spSetDtr, value);

  @override
  Future<void> setRts(bool value) async => _setLine('rts', _spSetRts, value);

  @override
  Future<void> setBaudRate(int baudRate) async {
    final config = SerialPortConfig()..baudRate = baudRate;
    _port.config = config;
    config.dispose();
  }

  @override
  Future<void> flushInput() async => _port.flush(SerialPortBuffer.input);

  /// Flip a single modem-control line via libserialport's `sp_set_dtr` /
  /// `sp_set_rts`, which the high-level `SerialPort` class doesn't expose.
  ///
  /// These do a targeted line change (a `TIOCMBIS`/`TIOCMBIC` ioctl on POSIX)
  /// rather than the full `sp_set_config` port reconfigure that `port.config =`
  /// triggers. The lighter call is what pyserial/esptool use, and it avoids the
  /// heavy reconfigure that can wedge on native-USB boards mid-reset.
  void _setLine(String name, _SpSetLine fn, bool asserted) {
    // enum sp_dtr/sp_rts: OFF = 0, ON = 1.
    final rc = fn(Pointer<Void>.fromAddress(_port.address), asserted ? 1 : 0);
    if (rc != 0) throw StateError('sp_set_$name failed (sp_return $rc)');
  }

  /// Stop the reader and release the port.
  void close() {
    _reader.close();
    if (_port.isOpen) _port.close();
    _port.dispose();
  }
}

/// Locate the native libserialport C library and point `package:libserialport`
/// at it via its `LIBSERIALPORT_PATH` override, so the example "just works"
/// without the caller exporting env vars.
///
/// This is needed because Homebrew (`/opt/homebrew/lib` on Apple Silicon),
/// MacPorts, and Linux multiarch dirs aren't always on the default dynamic
/// loader search path — and macOS strips `DYLD_*` from the signed `dart`
/// binary, so those can't help either.
///
/// libserialport reads `LIBSERIALPORT_PATH` through [Platform.environment],
/// which Dart snapshots on first access, so we inject it with `setenv` up front.
/// **Call this as the very first statement in `main`**, before anything else
/// reads the environment or touches libserialport. An explicit
/// `LIBSERIALPORT_PATH` set by the caller is respected (we don't overwrite it).
void ensureLibserialportResolved() {
  if (Platform.isWindows) return; // the DLL is normally found beside the exe
  final path = _findNativeLibrary();
  if (path == null) return; // fall back to libserialport's own resolution
  final key = 'LIBSERIALPORT_PATH'.toNativeUtf8();
  final value = path.toNativeUtf8();
  try {
    _setenv(key, value, 0); // overwrite = 0: don't clobber a caller's value
  } finally {
    malloc.free(key);
    malloc.free(value);
  }
}

/// libc `int setenv(const char *name, const char *value, int overwrite)`.
final int Function(Pointer<Utf8>, Pointer<Utf8>, int) _setenv =
    DynamicLibrary.process().lookupFunction<Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32),
        int Function(Pointer<Utf8>, Pointer<Utf8>, int)>('setenv');

/// `enum sp_return sp_set_dtr/sp_set_rts(struct sp_port *port, enum sp_xtr xtr)`
/// — takes the native `sp_port*` (via [SerialPort.address]) and a 0/1 line state.
typedef _SpSetLine = int Function(Pointer<Void>, int);

/// The libserialport C library, opened by the same resolved path
/// [ensureLibserialportResolved] hands to the wrapper (dlopen refcounts, so this
/// shares the already-loaded image rather than loading a second copy).
final DynamicLibrary _libserialport = () {
  final path = _findNativeLibrary();
  if (path != null) return DynamicLibrary.open(path);
  return DynamicLibrary.open(Platform.isWindows
      ? 'libserialport.dll'
      : Platform.isMacOS
          ? 'libserialport.dylib'
          : 'libserialport.so');
}();

final _SpSetLine _spSetDtr =
    _libserialport.lookupFunction<Int32 Function(Pointer<Void>, Int32), _SpSetLine>('sp_set_dtr');
final _SpSetLine _spSetRts =
    _libserialport.lookupFunction<Int32 Function(Pointer<Void>, Int32), _SpSetLine>('sp_set_rts');

String? _findNativeLibrary() {
  final candidates = Platform.isMacOS
      ? const [
          '/opt/homebrew/lib/libserialport.dylib', // Homebrew (Apple Silicon)
          '/usr/local/lib/libserialport.dylib', //    Homebrew (Intel)
          '/opt/local/lib/libserialport.dylib', //    MacPorts
        ]
      : const [
          '/usr/lib/x86_64-linux-gnu/libserialport.so.0',
          '/usr/lib/aarch64-linux-gnu/libserialport.so.0',
          '/usr/local/lib/libserialport.so.0',
          '/usr/lib/libserialport.so.0',
          '/usr/local/lib/libserialport.so',
          '/usr/lib/libserialport.so',
        ];
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}
