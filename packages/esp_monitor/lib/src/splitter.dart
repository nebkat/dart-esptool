/// Turning a byte stream into text lines.
library;

import 'dart:convert';

/// Decodes UTF-8 bytes as they arrive and splits them into lines.
///
/// Lines end at `\n`; a `\r` before it is dropped, as is any other `\r`
/// (a device redrawing a line with a bare carriage return just gets the
/// redraws appended). Malformed UTF-8 — a baud rate mismatch, a boot ROM at
/// a different speed — becomes U+FFFD rather than an error.
class LineSplitter {
  final _pending = StringBuffer();
  late final _sink = const Utf8Decoder(allowMalformed: true).startChunkedConversion(_Collect(_onText));
  final _lines = <String>[];

  /// The text received since the last line ending — a prompt, or a line still
  /// being written.
  String get pending => _pending.toString();

  /// Feed [bytes]; returns the lines they completed.
  List<String> add(List<int> bytes) {
    _sink.add(bytes);
    if (_lines.isEmpty) return const [];
    final out = List.of(_lines);
    _lines.clear();
    return out;
  }

  /// Complete whatever is pending as a line (for example when the monitor
  /// stops), returning it if there was one.
  String? flush() {
    if (_pending.isEmpty) return null;
    final line = _pending.toString();
    _pending.clear();
    return line;
  }

  void _onText(String text) {
    var start = 0;
    for (var i = 0; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      if (c == 0x0A) {
        _append(text, start, i);
        _lines.add(_pending.toString());
        _pending.clear();
        start = i + 1;
      } else if (c == 0x0D) {
        _append(text, start, i);
        start = i + 1;
      }
    }
    _append(text, start, text.length);
  }

  void _append(String text, int start, int end) {
    if (end > start) _pending.write(text.substring(start, end));
  }
}

class _Collect implements Sink<String> {
  _Collect(this.onText);
  final void Function(String) onText;

  @override
  void add(String data) => onText(data);

  @override
  void close() {}
}
