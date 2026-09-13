import 'dart:convert';

import 'package:esp_monitor/esp_monitor.dart';
import 'package:test/test.dart';

MonitorLine parse(String raw) => MonitorLine.parse(0, DateTime(2026), raw, AnsiDecoder());

void main() {
  group('ANSI', () {
    test('an ESP-IDF coloured line', () {
      final spans = AnsiDecoder().decode('\x1b[0;32mI (312) wifi: started\x1b[0m');
      expect(spans, hasLength(1));
      expect(spans.single.text, 'I (312) wifi: started');
      expect(spans.single.style, const AnsiStyle(foreground: 2));
    });

    test('styles, bright, 256 and truecolour, and a reset mid-line', () {
      final spans = AnsiDecoder().decode('a\x1b[1;91mb\x1b[38;5;208mc\x1b[48;2;1;2;3md\x1b[me');
      expect(spans.map((s) => s.text), ['a', 'b', 'c', 'd', 'e']);
      expect(spans[1].style, const AnsiStyle(foreground: 9, bold: true));
      expect(spans[2].style, const AnsiStyle(foreground: 208, bold: true));
      expect(spans[3].style.background, AnsiStyle.rgbFlag | 0x010203);
      expect(spans[4].style, AnsiStyle.plain);
    });

    test('a style carries over to the next line until reset', () {
      final ansi = AnsiDecoder();
      ansi.decode('\x1b[0;31mE (1) x: first line');
      expect(ansi.decode('continued').single.style.foreground, 1);
    });

    test('other escape sequences are dropped', () {
      expect(AnsiDecoder().decode('\x1b[2J\x1b[Hhello\x1b[K').map((s) => s.text).join(), 'hello');
    });
  });

  group('line splitting', () {
    test('CRLF, bare CR, and lines across chunks', () {
      final s = LineSplitter();
      expect(s.add(utf8.encode('one\r\ntw')), ['one']);
      expect(s.pending, 'tw');
      expect(s.add(utf8.encode('o\nthr\ree\n')), ['two', 'three']);
      expect(s.add(utf8.encode('esp32> ')), isEmpty);
      expect(s.pending, 'esp32> ');
      expect(s.flush(), 'esp32> ');
      expect(s.pending, '');
    });

    test('UTF-8 split across chunks, and malformed bytes', () {
      final s = LineSplitter();
      final bytes = utf8.encode('✓\n');
      expect(s.add(bytes.sublist(0, 1)), isEmpty);
      expect(s.add(bytes.sublist(1)), ['✓']);
      expect(s.add([0xFF, 0x41, 0x0A]), ['�A']);
    });
  });

  group('ESP-IDF log lines', () {
    test('milliseconds since boot', () {
      final line = parse('\x1b[0;33mW (1234) wifi:sta: reconnecting: attempt 3\x1b[0m');
      expect(line.kind, LineKind.log);
      expect(line.level, LogLevel.warning);
      expect(line.timestamp, '1234');
      expect(line.tag, 'wifi:sta');
      expect(line.message, 'reconnecting: attempt 3');
    });

    test('system time, full date, no tag, no timestamp', () {
      expect(parse('I (12:34:56.789) main: hi').timestamp, '12:34:56.789');
      expect(parse('E (26-09-13 12:34:56.789) main: hi').timestamp, '26-09-13 12:34:56.789');
      final noTag = parse('D (99) just a message');
      expect((noTag.tag, noTag.message), (null, 'just a message'));
      final noTime = parse('V heap: free 1234');
      expect((noTime.level, noTime.timestamp, noTime.tag, noTime.message), (LogLevel.verbose, null, 'heap', 'free 1234'));
    });

    test('bootloader lines are log lines too', () {
      expect(parse('I (29) boot: ESP-IDF v5.4 2nd stage bootloader').tag, 'boot');
    });

    test('ordinary text is not mistaken for a log line', () {
      expect(parse('I think so: yes').kind, LineKind.text);
      expect(parse('Hello world').kind, LineKind.text);
      expect(parse('E').kind, LineKind.text);
    });

    test('reset banners', () {
      for (final text in ['ESP-ROM:esp32s3-20210327', 'ets Jul 29 2019 12:21:46', 'rst:0xc (SW_CPU_RESET),boot:0x13 (SPI_FAST_FLASH_BOOT)']) {
        expect(parse(text).kind, LineKind.reset, reason: text);
      }
    });

    test('panics', () {
      for (final text in [
        "Guru Meditation Error: Core  0 panic'ed (LoadProhibited). Exception was unhandled.",
        'abort() was called at PC 0x4200a1b2 on core 0',
        'Backtrace: 0x40081e4a:0x3fc9a1c0 0x4200a1b2:0x3fc9a1e0',
        'assert failed: app_main main.c:10 (x == 1)',
        'Rebooting...',
      ]) {
        expect(parse(text).kind, LineKind.panic, reason: text);
      }
    });
  });

  group('filter and buffer', () {
    final input = [
      'rst:0x1 (POWERON),boot:0x8 (SPI_FAST_FLASH_BOOT)',
      '\x1b[0;32mI (10) boot: start\x1b[0m',
      '\x1b[0;31mE (20) wifi: failed\x1b[0m',
      'D (30) wifi: retry',
      'printf output',
      '\x1b[0;33mW (40) nvs: low space\x1b[0m',
    ].join('\r\n');

    MonitorBuffer filled({int capacity = 1000}) => MonitorBuffer(capacity: capacity)..add(utf8.encode('$input\r\n'));

    test('counts tags and shows everything by default', () {
      final b = filled();
      expect(b.visible, hasLength(6));
      expect(b.tags, {'boot': 1, 'wifi': 2, 'nvs': 1});
    });

    test('level, tags, text, regex and log-only', () {
      final b = filled();
      b.filter = const MonitorFilter(maxLevel: LogLevel.warning);
      expect(b.visible.map((l) => l.text), [startsWith('rst:'), 'E (20) wifi: failed', 'printf output', 'W (40) nvs: low space']);
      b.filter = const MonitorFilter(hiddenTags: {'wifi'}, logOnly: true);
      expect(b.visible.map((l) => l.tag), ['boot', 'nvs']);
      b.filter = const MonitorFilter(query: 'WIFI');
      expect(b.visible, hasLength(2));
      b.filter = const MonitorFilter(query: 'WIFI', caseSensitive: true);
      expect(b.visible, isEmpty);
      b.filter = const MonitorFilter(query: r'\((1|4)0\)', regex: true);
      expect(b.visible.map((l) => l.tag), ['boot', 'nvs']);
    });

    test('notes sit in sequence and are not log lines', () {
      final b = filled();
      final note = b.note('I (1) looks: like a log line');
      expect((note.kind, note.level, b.lines.last), (LineKind.note, null, note));
      b.filter = const MonitorFilter(logOnly: true);
      expect(b.visible, isNot(contains(note)));
    });

    test('an invalid regex leaves the filter alone', () {
      final b = filled();
      expect(() => b.filter = const MonitorFilter(query: '(', regex: true), throwsFormatException);
      expect(b.filter.isEmpty, isTrue);
      expect(b.visible, hasLength(6));
    });

    test('new lines are filtered as they arrive', () {
      final b = filled()..filter = const MonitorFilter(maxLevel: LogLevel.error, logOnly: true);
      b.add(utf8.encode('E (50) x: again\nI (60) x: fine\n'));
      expect(b.visible.map((l) => l.message), ['failed', 'again']);
    });

    test('capacity drops the oldest lines, tags and visible lines with them', () {
      final b = MonitorBuffer(capacity: 10);
      for (var i = 0; i < 25; i++) {
        b.add(utf8.encode('I ($i) t${i % 2}: line $i\n'));
      }
      expect(b.lines.length, lessThanOrEqualTo(10));
      expect(b.lines.last.message, 'line 24');
      expect(b.visible, b.lines);
      expect(b.tags.values.fold(0, (a, n) => a + n), b.lines.length);
      expect(b.received, 25);
    });
  });
}
