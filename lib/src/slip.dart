import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

/// SLIP framing constants (RFC 1055), as used by the ESP ROM bootloader.
const int _slipEnd = 0xC0; // frame delimiter
const int _slipEsc = 0xDB; // escape byte
const int _slipEscEnd = 0xDC; // escaped 0xC0
const int _slipEscEsc = 0xDD; // escaped 0xDB

/// SLIP-encode [packet] into a single frame: a leading and trailing `0xC0`
/// delimiter with `0xC0`/`0xDB` bytes in the payload escaped.
///
/// @see [https://datatracker.ietf.org/doc/html/rfc1055]
Uint8List slipEncode(Uint8List packet) {
  final out = BytesBuilder(copy: false);
  out.addByte(_slipEnd);
  for (final b in packet) {
    if (b == _slipEnd) {
      out.addByte(_slipEsc);
      out.addByte(_slipEscEnd);
    } else if (b == _slipEsc) {
      out.addByte(_slipEsc);
      out.addByte(_slipEscEsc);
    } else {
      out.addByte(b);
    }
  }
  out.addByte(_slipEnd);
  return out.toBytes();
}

/// Streaming SLIP frame decoder over a raw byte [Stream].
///
/// Subscribes to the transport's input once and reassembles delimited frames,
/// exposing them one at a time via [read] with a timeout — the request/response
/// pattern the bootloader protocol needs.
///
/// Unlike a strict RFC 1055 reader, bytes seen while no frame is open (before
/// the first `0xC0`) are skipped rather than treated as errors, so ROM boot-log
/// output between frames doesn't derail decoding.
class SlipReader {
  SlipReader(Stream<List<int>> input) {
    _subscription = input.listen(
      _onData,
      onError: _onError,
      onDone: _onDone,
    );
  }

  late final StreamSubscription<List<int>> _subscription;

  final Queue<Uint8List> _frames = Queue<Uint8List>();
  final Queue<Completer<Uint8List>> _waiters = Queue<Completer<Uint8List>>();

  BytesBuilder? _partial; // non-null while inside a frame
  bool _inEscape = false;
  Object? _streamError;

  void _onData(List<int> data) {
    for (final b in data) {
      final partial = _partial;
      if (partial == null) {
        // Between frames: wait for a start delimiter, skip everything else.
        if (b == _slipEnd) _partial = BytesBuilder(copy: false);
      } else if (_inEscape) {
        _inEscape = false;
        if (b == _slipEscEnd) {
          partial.addByte(_slipEnd);
        } else if (b == _slipEscEsc) {
          partial.addByte(_slipEsc);
        } else {
          // Invalid escape — drop the malformed frame and resynchronise.
          _partial = null;
        }
      } else if (b == _slipEsc) {
        _inEscape = true;
      } else if (b == _slipEnd) {
        // End delimiter. Empty content means back-to-back delimiters; ignore.
        if (partial.length > 0) _emit(partial.toBytes());
        _partial = null;
      } else {
        partial.addByte(b);
      }
    }
  }

  void _emit(Uint8List frame) {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete(frame);
    } else {
      _frames.add(frame);
    }
  }

  void _onError(Object error, StackTrace stackTrace) {
    _streamError = error;
    while (_waiters.isNotEmpty) {
      _waiters.removeFirst().completeError(error, stackTrace);
    }
  }

  void _onDone() {
    _streamError ??= StateError('Transport input stream closed');
    while (_waiters.isNotEmpty) {
      _waiters.removeFirst().completeError(_streamError!);
    }
  }

  /// Await the next complete SLIP frame, failing with a [TimeoutException] if
  /// none arrives within [timeout].
  Future<Uint8List> read(Duration timeout) {
    if (_frames.isNotEmpty) return Future<Uint8List>.value(_frames.removeFirst());
    if (_streamError != null) return Future<Uint8List>.error(_streamError!);
    final completer = Completer<Uint8List>();
    _waiters.add(completer);
    return completer.future.timeout(timeout, onTimeout: () {
      _waiters.remove(completer);
      throw TimeoutException('No SLIP frame received', timeout);
    });
  }

  /// Discard any buffered frames and reset the in-progress frame state.
  void flush() {
    _frames.clear();
    _partial = null;
    _inEscape = false;
  }

  /// Cancel the underlying subscription. The [SlipReader] is unusable after.
  Future<void> dispose() => _subscription.cancel();
}
