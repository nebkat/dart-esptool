import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:esptool/esptool.dart';
import 'package:web/web.dart' as web;

/// `navigator.serial`, or `null` where the Web Serial API is unavailable
/// (non-Chromium browsers, or an insecure origin — it needs https/localhost).
@JS('navigator.serial')
external Serial? get serial;

/// Minimal bindings for the Web Serial API, which `package:web` doesn't cover.
///
/// @see [https://wicg.github.io/serial/]
extension type Serial._(JSObject _) implements web.EventTarget {
  /// Show the browser's port chooser. Requires a user gesture.
  external JSPromise<SerialPort> requestPort();

  /// Ports this origin has already been granted, no gesture needed.
  external JSPromise<JSArray<SerialPort>> getPorts();
}

extension type SerialPort._(JSObject _) implements web.EventTarget {
  external bool get connected;
  external web.ReadableStream? get readable;
  external web.WritableStream? get writable;
  external SerialPortInfo getInfo();
  external JSPromise<JSAny?> open(SerialOptions options);
  external JSPromise<JSAny?> close();
  external JSPromise<JSAny?> setSignals(SerialOutputSignals signals);
}

extension type SerialPortInfo._(JSObject _) implements JSObject {
  external int? get usbVendorId;
  external int? get usbProductId;
}

extension type SerialOptions._(JSObject _) implements JSObject {
  external factory SerialOptions({int baudRate, int bufferSize});
}

extension type SerialOutputSignals._(JSObject _) implements JSObject {
  external factory SerialOutputSignals({bool dataTerminalReady, bool requestToSend});
}

/// An [EspTransport] over the browser's Web Serial API.
///
/// Unlike the libserialport transport nothing here blocks: a device that
/// vanishes mid-operation (unplugged, or re-enumerated by a native-USB reset)
/// surfaces as a rejected promise / stream error rather than a hung call.
class WebSerialTransport extends EspTransport {
  WebSerialTransport._(this.port, this._baudRate, this.trace);

  final SerialPort port;
  int _baudRate;

  /// Optional sink for per-operation debug lines (line toggles, reopen, ...).
  final void Function(String message)? trace;

  final _input = StreamController<List<int>>.broadcast();
  web.ReadableStreamDefaultReader? _reader;
  web.WritableStreamDefaultWriter? _writer;
  Future<void>? _pumping;

  static Future<WebSerialTransport> open(
    SerialPort port, {
    int baudRate = 115200,
    void Function(String message)? trace,
  }) async {
    final transport = WebSerialTransport._(port, baudRate, trace);
    await transport._open();
    return transport;
  }

  Future<void> _open() async {
    await port.open(SerialOptions(baudRate: _baudRate, bufferSize: 64 * 1024)).toDart;
    trace?.call('port opened @ $_baudRate');
    _writer = port.writable!.getWriter();
    final reader = port.readable!.getReader() as web.ReadableStreamDefaultReader;
    _reader = reader;
    _pumping = _pump(reader);
  }

  Future<void> _pump(web.ReadableStreamDefaultReader reader) async {
    try {
      while (true) {
        final result = await reader.read().toDart;
        if (result.done) break; // reader cancelled by _release()
        final chunk = result.value as JSUint8Array?;
        if (chunk != null) _input.add(chunk.toDart);
      }
    } catch (e, st) {
      // Fatal errors (NetworkError: "The device has been lost") leave
      // port.readable null; framing/parity/break errors are recoverable but
      // the ROM protocol can't use the frame anyway, so fail the read.
      trace?.call('read loop error: $e');
      _input.addError(e, st);
    } finally {
      reader.releaseLock();
    }
  }

  @override
  Stream<List<int>> get input => _input.stream;

  @override
  Future<void> write(Uint8List data) async {
    await _writer!.write(data.toJS).toDart;
  }

  @override
  Future<void> setDtr(bool value) async {
    trace?.call('DTR=${value ? 1 : 0}');
    await port.setSignals(SerialOutputSignals(dataTerminalReady: value)).toDart;
  }

  @override
  Future<void> setRts(bool value) async {
    trace?.call('RTS=${value ? 1 : 0}');
    await port.setSignals(SerialOutputSignals(requestToSend: value)).toDart;
  }

  /// Web Serial fixes the baud rate at `open()`, so this closes and reopens
  /// the port. Note the OS may re-assert DTR/RTS on reopen.
  @override
  Future<void> setBaudRate(int baudRate) async {
    trace?.call('reopening @ $baudRate');
    _baudRate = baudRate;
    await _release();
    await port.close().toDart;
    await _open();
  }

  Future<void> _release() async {
    final reader = _reader;
    _reader = null;
    if (reader != null) {
      try {
        await reader.cancel().toDart;
      } catch (_) {}
      await _pumping;
    }
    _writer?.releaseLock();
    _writer = null;
  }

  /// Release the streams and close the port. Safe to call on a lost device.
  Future<void> close() async {
    await _release();
    try {
      await port.close().toDart;
      trace?.call('port closed');
    } catch (e) {
      trace?.call('port close failed: $e');
    }
    await _input.close();
  }
}
