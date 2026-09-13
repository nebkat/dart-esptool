/// The monitor's scrollback: received lines, capped, with a filtered view.
library;

import 'ansi.dart';
import 'filter.dart';
import 'line.dart';
import 'splitter.dart';

/// Bytes in, lines out: splits, decodes and parses what the device sends,
/// keeps the last [capacity] lines, and maintains the lines that pass
/// [filter] so a UI can index them directly.
class MonitorBuffer {
  MonitorBuffer({this.capacity = 50000});

  final int capacity;

  final _splitter = LineSplitter();
  final _ansi = AnsiDecoder();
  final List<MonitorLine> _lines = [];
  final List<MonitorLine> _visible = [];
  final Map<String, int> _tags = {};
  var _seq = 0;
  var _filter = MonitorFilter.none;
  var _matches = MonitorFilter.none.matcher();

  /// Every line kept, oldest first.
  List<MonitorLine> get lines => _lines;

  /// The lines passing [filter], oldest first.
  List<MonitorLine> get visible => _visible;

  /// Tag → number of log lines kept with it.
  Map<String, int> get tags => _tags;

  /// Text after the last line ending (a prompt, or a line being written).
  String get pending => _splitter.pending;

  /// Lines received since the monitor started, including ones dropped from
  /// the scrollback.
  int get received => _seq;

  MonitorFilter get filter => _filter;

  /// Apply [filter] to every kept line. Throws [FormatException] for an
  /// invalid regular expression, leaving the previous filter in place.
  set filter(MonitorFilter filter) {
    final matches = filter.matcher();
    _filter = filter;
    _matches = matches;
    _visible
      ..clear()
      ..addAll(_lines.where(matches));
  }

  /// Feed received [bytes]. Returns how many lines they completed.
  int add(List<int> bytes, {DateTime? now}) {
    final raw = _splitter.add(bytes);
    if (raw.isEmpty) return 0;
    final at = now ?? DateTime.now();
    for (final text in raw) {
      _append(MonitorLine.parse(_seq++, at, text, _ansi));
    }
    _trim();
    return raw.length;
  }

  /// Add a line that didn't come from the device — a note such as "monitor
  /// started" — so it appears in sequence.
  MonitorLine note(String text, {DateTime? now}) {
    final line = MonitorLine.note(_seq++, now ?? DateTime.now(), text);
    _append(line);
    _trim();
    return line;
  }

  /// Complete the pending text as a line.
  void flush({DateTime? now}) {
    final text = _splitter.flush();
    if (text != null) {
      _append(MonitorLine.parse(_seq++, now ?? DateTime.now(), text, _ansi));
      _trim();
    }
  }

  void clear() {
    _lines.clear();
    _visible.clear();
    _tags.clear();
    _ansi.reset();
  }

  void _append(MonitorLine line) {
    _lines.add(line);
    final tag = line.tag;
    if (tag != null) _tags[tag] = (_tags[tag] ?? 0) + 1;
    if (_matches(line)) _visible.add(line);
  }

  /// Drop the oldest lines once over capacity, a tenth at a time so the
  /// front of the lists isn't shifted on every line.
  void _trim() {
    if (_lines.length <= capacity) return;
    final drop = _lines.length - capacity + capacity ~/ 10;
    final firstKept = _lines[drop].seq;
    for (final line in _lines.take(drop)) {
      final tag = line.tag;
      if (tag == null) continue;
      final count = _tags[tag]! - 1;
      if (count == 0) {
        _tags.remove(tag);
      } else {
        _tags[tag] = count;
      }
    }
    _lines.removeRange(0, drop);
    var cut = 0;
    while (cut < _visible.length && _visible[cut].seq < firstKept) {
      cut++;
    }
    _visible.removeRange(0, cut);
  }
}
