import 'package:esp_monitor/esp_monitor.dart';
import 'package:flutter/material.dart';

import '../session/device_session.dart';
import '../util/files.dart';
import '../widgets/dropdown.dart';

/// The app's serial console: ESP-IDF log lines coloured and parsed, with
/// filtering, reset, and a line to send input. Monitoring is a session mode
/// of its own — the chip runs its app, so the bootloader pages are
/// unavailable until it is put back into the bootloader.
class MonitorPage extends StatefulWidget {
  const MonitorPage({super.key, required this.session});
  final DeviceSession session;

  @override
  State<MonitorPage> createState() => _MonitorPageState();
}

class _MonitorPageState extends State<MonitorPage> {
  final _scroll = ScrollController();
  late final _query = TextEditingController(text: log.filter.query);
  final _send = TextEditingController();
  bool _follow = true;
  bool _resetOnStart = true;
  bool _showTime = false;
  String _ending = '\r\n';
  String? _queryError;

  static const _bauds = [9600, 57600, 74880, 115200, 230400, 460800, 921600, 1500000, 2000000];
  static const _mono = TextStyle(fontFamily: 'RobotoMono', fontSize: 12, height: 1.35);

  DeviceSession get session => widget.session;
  MonitorLog get log => session.monitorLog;

  @override
  void dispose() {
    _scroll.dispose();
    _query.dispose();
    _send.dispose();
    super.dispose();
  }

  void _setFilter(MonitorFilter filter) {
    try {
      log.filter = filter;
      if (_queryError != null) setState(() => _queryError = null);
    } on FormatException catch (e) {
      setState(() => _queryError = e.message);
    }
  }

  void _toggleTag(String tag, bool visible) {
    final hidden = {...log.filter.hiddenTags};
    visible ? hidden.remove(tag) : hidden.add(tag);
    _setFilter(log.filter.copyWith(hiddenTags: hidden));
  }

  void _sendText() {
    session.monitorSend('${_send.text}$_ending');
    _send.clear();
  }

  Future<void> _save() async {
    final stem = session.chip == null ? 'monitor' : '${session.deviceStem}-monitor';
    final text = [for (final line in log.buffer.visible) '${_showTime ? '${_time(line.received)}  ' : ''}${line.text}'].join('\n');
    await saveText('$stem.log', '$text\n');
  }

  /// Follow new output while the view is at the bottom; scrolling up stops
  /// following, scrolling back down resumes it.
  bool _onScroll(ScrollUpdateNotification n) {
    final atEnd = n.metrics.pixels >= n.metrics.maxScrollExtent - 24;
    if (atEnd != _follow) setState(() => _follow = atEnd);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(padding: const EdgeInsets.fromLTRB(16, 16, 16, 8), child: _controls()),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: ListenableBuilder(listenable: log, builder: (context, _) => _filters(theme)),
      ),
      Expanded(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: theme.dividerColor),
          ),
          clipBehavior: Clip.antiAlias,
          child: ListenableBuilder(listenable: log, builder: (context, _) => _output(theme)),
        ),
      ),
      Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 16), child: _sendRow()),
    ]);
  }

  Widget _controls() {
    final busy = session.busy;
    final monitoring = session.monitoring;
    return Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
      AppDropdown<int>(
        value: session.monitorBaud,
        label: 'Baud',
        width: 150,
        enabled: !monitoring && !busy,
        entries: [for (final b in _bauds) DropdownMenuEntry(value: b, label: '$b')],
        onSelected: (b) {
          if (b != null) session.setMonitorBaud(b);
        },
      ),
      if (!monitoring) ...[
        if (!session.connected)
          FilterChip(
            label: const Text('Reset on start'),
            tooltip: 'Reboot the chip when the monitor starts, to see it from boot',
            selected: _resetOnStart,
            onSelected: (v) => setState(() => _resetOnStart = v),
          ),
        FilledButton.icon(
          onPressed: busy || session.selectedPort == null ? null : () => session.startMonitor(reset: _resetOnStart),
          icon: const Icon(Icons.play_arrow),
          label: Text(session.connected ? 'Reset into app & monitor' : 'Start monitor'),
        ),
        if (session.selectedPort == null) const Text('Choose a port in the bar above first.'),
      ] else ...[
        Chip(
          avatar: session.monitorWaiting
              ? const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.circle, size: 12, color: Colors.green),
          label: Text(session.monitorWaiting ? 'Waiting for the port…' : 'Monitoring${session.chip == null ? '' : ' ${session.chip!.name}'}'),
        ),
        FilledButton.tonalIcon(onPressed: session.monitorWaiting ? null : session.monitorReset, icon: const Icon(Icons.restart_alt), label: const Text('Reset')),
        FilledButton.tonalIcon(
            onPressed: busy ? null : () => session.stopMonitor(enterBootloader: true), icon: const Icon(Icons.memory), label: const Text('Enter bootloader')),
        OutlinedButton.icon(onPressed: busy ? null : session.stopMonitor, icon: const Icon(Icons.stop), label: const Text('Stop')),
      ],
    ]);
  }

  Widget _filters(ThemeData theme) {
    final filter = log.filter;
    final tags = log.buffer.tags;
    final names = tags.keys.toList()..sort();
    return Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
      AppDropdown<LogLevel>(
        value: filter.maxLevel,
        label: 'Level',
        width: 150,
        entries: [for (final l in LogLevel.values) DropdownMenuEntry(value: l, label: l.label)],
        onSelected: (l) {
          if (l != null) _setFilter(filter.copyWith(maxLevel: l));
        },
      ),
      SizedBox(
        width: 340,
        child: TextField(
          controller: _query,
          style: _mono,
          decoration: InputDecoration(
            isDense: true,
            labelText: 'Search',
            errorText: _queryError,
            prefixIcon: const Icon(Icons.search, size: 20),
            suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                tooltip: 'Match case',
                isSelected: filter.caseSensitive,
                icon: const Text('Aa'),
                onPressed: () => _setFilter(filter.copyWith(caseSensitive: !filter.caseSensitive)),
              ),
              IconButton(
                tooltip: 'Regular expression',
                isSelected: filter.regex,
                icon: const Text('.*'),
                onPressed: () => _setFilter(filter.copyWith(regex: !filter.regex)),
              ),
            ]),
          ),
          onChanged: (text) => _setFilter(log.filter.copyWith(query: text)),
        ),
      ),
      MenuAnchor(
        menuChildren: [
          for (final tag in names)
            CheckboxMenuButton(
              value: !filter.hiddenTags.contains(tag),
              closeOnActivate: false,
              onChanged: (v) => _toggleTag(tag, v ?? true),
              child: Text('$tag (${tags[tag]})', style: _mono),
            ),
        ],
        builder: (context, controller, _) => OutlinedButton.icon(
          onPressed: names.isEmpty ? null : () => controller.isOpen ? controller.close() : controller.open(),
          icon: const Icon(Icons.label_outline),
          label: Text(filter.hiddenTags.isEmpty ? 'Tags' : 'Tags (${filter.hiddenTags.length} hidden)'),
        ),
      ),
      FilterChip(label: const Text('Log lines only'), selected: filter.logOnly, onSelected: (v) => _setFilter(filter.copyWith(logOnly: v))),
      FilterChip(label: const Text('Host time'), selected: _showTime, onSelected: (v) => setState(() => _showTime = v)),
      if (!filter.isEmpty)
        TextButton(
          onPressed: () {
            _query.clear();
            _setFilter(MonitorFilter.none);
          },
          child: const Text('Clear filters'),
        ),
      Text('${log.buffer.visible.length} of ${log.buffer.lines.length} lines', style: theme.textTheme.labelMedium),
      IconButton(tooltip: 'Save the lines shown', icon: const Icon(Icons.download), onPressed: log.buffer.visible.isEmpty ? null : _save),
      IconButton(tooltip: 'Clear output', icon: const Icon(Icons.clear_all), onPressed: log.clear),
    ]);
  }

  Widget _output(ThemeData theme) {
    final lines = log.buffer.visible;
    final pending = log.buffer.pending;
    final count = lines.length + (pending.isEmpty ? 0 : 1);
    if (count == 0) {
      return Center(
        child: Text(
          session.monitoring ? 'Waiting for output…' : 'Start the monitor to see the device\'s console output.',
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline),
        ),
      );
    }
    if (_follow) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _follow && _scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
    final dark = theme.brightness == Brightness.dark;
    return Stack(children: [
      NotificationListener<ScrollUpdateNotification>(
        onNotification: _onScroll,
        child: SelectionArea(
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.all(8),
            itemCount: count,
            itemBuilder: (context, i) => i < lines.length
                ? _row(lines[i], i == 0 ? null : lines[i - 1], theme, dark)
                : Text(pending, style: _mono.copyWith(color: theme.colorScheme.outline)),
          ),
        ),
      ),
      if (!_follow)
        Positioned(
          right: 16,
          bottom: 16,
          child: FloatingActionButton.small(
            tooltip: 'Follow new output',
            onPressed: () => setState(() => _follow = true),
            child: const Icon(Icons.arrow_downward),
          ),
        ),
    ]);
  }

  Widget _row(MonitorLine line, MonitorLine? previous, ThemeData theme, bool dark) {
    final scheme = theme.colorScheme;
    // Firmware built without log colours still gets its levels coloured.
    final levelColour = line.kind == LineKind.log && line.spans.every((s) => s.style.foreground == null) ? _levelColour(line.level!, dark) : null;
    final base = switch (line.kind) {
      LineKind.panic => _mono.copyWith(color: scheme.error, fontWeight: FontWeight.bold),
      LineKind.note => _mono.copyWith(color: scheme.primary, fontStyle: FontStyle.italic),
      _ => _mono.copyWith(color: levelColour),
    };
    final text = Text.rich(
      TextSpan(children: [
        if (_showTime) TextSpan(text: '${_time(line.received)}  ', style: TextStyle(color: scheme.outline)),
        for (final span in line.spans) TextSpan(text: span.text, style: line.kind == LineKind.note ? null : _style(span.style, dark)),
      ]),
      style: base,
    );
    return switch (line.kind) {
      LineKind.reset when previous?.kind != LineKind.reset => Container(
          margin: const EdgeInsets.only(top: 6),
          padding: const EdgeInsets.only(top: 4),
          decoration: BoxDecoration(border: Border(top: BorderSide(color: scheme.primary, width: 1.5))),
          child: text,
        ),
      LineKind.panic => ColoredBox(color: scheme.errorContainer.withValues(alpha: 0.35), child: text),
      _ => text,
    };
  }

  static TextStyle? _style(AnsiStyle style, bool dark) {
    if (style.isPlain) return null;
    var foreground = ansiColour(style.foreground, dark);
    var background = ansiColour(style.background, dark);
    if (style.reverse) {
      final swapped = background ?? (dark ? const Color(0xFF1E1E1E) : Colors.white);
      background = foreground ?? (dark ? Colors.white : Colors.black);
      foreground = swapped;
    }
    return TextStyle(
      color: foreground,
      backgroundColor: background,
      fontWeight: style.bold ? FontWeight.bold : null,
      fontStyle: style.italic ? FontStyle.italic : null,
      decoration: style.underline ? TextDecoration.underline : null,
    );
  }

  static Color _levelColour(LogLevel level, bool dark) => switch (level) {
        LogLevel.error => ansiColour(1, dark)!,
        LogLevel.warning => ansiColour(3, dark)!,
        LogLevel.info => ansiColour(2, dark)!,
        LogLevel.debug || LogLevel.verbose => dark ? const Color(0xFF9E9E9E) : const Color(0xFF616161),
      };

  static String _time(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}.${t.millisecond.toString().padLeft(3, '0')}';

  Widget _sendRow() {
    final enabled = session.monitoring && !session.monitorWaiting;
    return Row(children: [
      Expanded(
        child: TextField(
          controller: _send,
          enabled: enabled,
          style: _mono,
          decoration: const InputDecoration(isDense: true, labelText: 'Send to device', prefixIcon: Icon(Icons.keyboard, size: 20)),
          onSubmitted: (_) => _sendText(),
        ),
      ),
      const SizedBox(width: 8),
      AppDropdown<String>(
        value: _ending,
        label: 'Line ending',
        width: 150,
        entries: const [
          DropdownMenuEntry(value: '', label: 'None'),
          DropdownMenuEntry(value: '\n', label: 'LF'),
          DropdownMenuEntry(value: '\r', label: 'CR'),
          DropdownMenuEntry(value: '\r\n', label: 'CR LF'),
        ],
        onSelected: (v) => setState(() => _ending = v ?? _ending),
      ),
      const SizedBox(width: 8),
      FilledButton.icon(onPressed: enabled ? _sendText : null, icon: const Icon(Icons.send), label: const Text('Send')),
    ]);
  }
}

/// A terminal palette colour for [index] (see [AnsiStyle]), readable on the
/// theme's background.
Color? ansiColour(int? index, bool dark) {
  if (index == null) return null;
  if (index & AnsiStyle.rgbFlag != 0) return Color(0xFF000000 | (index & 0xFFFFFF));
  if (index < 16) return (dark ? _darkPalette : _lightPalette)[index];
  if (index < 232) {
    final i = index - 16;
    int level(int v) => v == 0 ? 0 : 55 + v * 40;
    return Color.fromARGB(255, level(i ~/ 36), level(i ~/ 6 % 6), level(i % 6));
  }
  final grey = 8 + (index - 232) * 10;
  return Color.fromARGB(255, grey, grey, grey);
}

const _lightPalette = [
  Color(0xFF000000), Color(0xFFC62828), Color(0xFF2E7D32), Color(0xFF9A6700), //
  Color(0xFF1565C0), Color(0xFF8E24AA), Color(0xFF00838F), Color(0xFF616161),
  Color(0xFF424242), Color(0xFFE53935), Color(0xFF43A047), Color(0xFFB8860B),
  Color(0xFF1E88E5), Color(0xFFAB47BC), Color(0xFF00ACC1), Color(0xFF212121),
];

const _darkPalette = [
  Color(0xFF757575), Color(0xFFEF5350), Color(0xFF66BB6A), Color(0xFFFFCA28), //
  Color(0xFF42A5F5), Color(0xFFBA68C8), Color(0xFF26C6DA), Color(0xFFE0E0E0),
  Color(0xFF9E9E9E), Color(0xFFFF7961), Color(0xFF98EE99), Color(0xFFFFF176),
  Color(0xFF80D6FF), Color(0xFFE1BEE7), Color(0xFF84FFFF), Color(0xFFFFFFFF),
];
