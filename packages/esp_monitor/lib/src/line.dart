/// One monitor line, and recognising ESP-IDF log lines in it.
library;

import 'ansi.dart';

/// ESP-IDF log levels, most severe first.
enum LogLevel {
  error('E', 'Error'),
  warning('W', 'Warning'),
  info('I', 'Info'),
  debug('D', 'Debug'),
  verbose('V', 'Verbose');

  const LogLevel(this.letter, this.label);
  final String letter;
  final String label;

  static LogLevel? fromLetter(String letter) => switch (letter) {
        'E' => error,
        'W' => warning,
        'I' => info,
        'D' => debug,
        'V' => verbose,
        _ => null,
      };
}

/// What a line is, beyond its text.
enum LineKind {
  /// An ESP-IDF log line (`I (123) tag: message`), from the app or the
  /// second-stage bootloader.
  log,

  /// The ROM's reset banner (`ESP-ROM:…`, `ets …`, `rst:0x…`): the chip
  /// has just rebooted.
  reset,

  /// Part of a panic or abort report.
  panic,

  /// Anything else — `printf` output, the console.
  text,

  /// Added by the host, not received ("monitor started").
  note,
}

/// A received line.
class MonitorLine {
  MonitorLine._(this.seq, this.received, this.text, this.spans, this.kind, this.level, this.timestamp, this.tag, this.message);

  /// Parse [raw] (one line, without its ending, ANSI codes included) with
  /// [ansi], whose style state carries over from the previous line.
  factory MonitorLine.parse(int seq, DateTime received, String raw, AnsiDecoder ansi) {
    final spans = ansi.decode(raw);
    final text = spans.length == 1 ? spans.single.text : spans.map((s) => s.text).join();
    final log = _parseLog(text);
    final kind = log != null
        ? LineKind.log
        : _isReset(text)
            ? LineKind.reset
            : _isPanic(text)
                ? LineKind.panic
                : LineKind.text;
    return MonitorLine._(seq, received, text, spans, kind, log?.$1, log?.$2, log?.$3, log?.$4);
  }

  /// A line the host adds itself (see [LineKind.note]).
  factory MonitorLine.note(int seq, DateTime received, String text) =>
      MonitorLine._(seq, received, text, [AnsiSpan(text, AnsiStyle.plain)], LineKind.note, null, null, null, null);

  /// Position in the stream since the monitor started; never reused.
  final int seq;

  /// When the host received the line ending.
  final DateTime received;

  /// The text without ANSI codes.
  final String text;
  final List<AnsiSpan> spans;
  final LineKind kind;

  /// The log fields, for [LineKind.log].
  final LogLevel? level;

  /// As the device printed it: milliseconds since boot, `HH:MM:SS.sss`,
  /// `YY-MM-DD HH:MM:SS.sss` or Unix milliseconds. `null` when the firmware
  /// logs without timestamps.
  final String? timestamp;
  final String? tag;
  final String? message;

  // `L (timestamp) tag: message`. With Log v2 the timestamp and the tag are each optional, so
  // `L tag: message` and `L (timestamp) message` occur too. A tag is taken to run to the first
  // ": " and have no spaces when there is no timestamp, so ordinary text starting with a capital
  // E/W/I/D/V and a space isn't mistaken for a log line.
  static final _withTimestamp = RegExp(r'^([EWIDV]) \((\d+|\d{2}:\d{2}:\d{2}\.\d{3}|\d{2}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})\) (?:(.*?): )?(.*)$');
  static final _withoutTimestamp = RegExp(r'^([EWIDV]) ([^\s:()]+): (.*)$');

  static (LogLevel, String?, String?, String)? _parseLog(String text) {
    if (text.length < 3 || text.codeUnitAt(1) != 0x20) return null;
    final timed = _withTimestamp.firstMatch(text);
    if (timed != null) return (LogLevel.fromLetter(timed[1]!)!, timed[2], timed[3], timed[4]!);
    final untimed = _withoutTimestamp.firstMatch(text);
    if (untimed != null) return (LogLevel.fromLetter(untimed[1]!)!, null, untimed[2], untimed[3]!);
    return null;
  }

  static final _reset = RegExp(r'^(?:ESP-ROM:|ets [A-Z][a-z]{2} [ \d]\d \d{4}|rst:0x[0-9a-fA-F]+ \()');

  static bool _isReset(String text) => _reset.hasMatch(text);

  static final _panic = RegExp(r'Guru Meditation Error|^abort\(\) was called|^Backtrace:|^\*\*\*ERROR\*\*\*|^assert failed:|^Rebooting\.\.\.$|^Stack smashing protect failure');

  static bool _isPanic(String text) => _panic.hasMatch(text);

  @override
  String toString() => text;
}
