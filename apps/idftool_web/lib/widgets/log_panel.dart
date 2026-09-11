import 'package:flutter/material.dart';

import '../session/device_session.dart';

/// The session log and the running operation's progress bar.
class LogPanel extends StatefulWidget {
  const LogPanel({super.key, required this.session});
  final DeviceSession session;

  @override
  State<LogPanel> createState() => _LogPanelState();
}

class _LogPanelState extends State<LogPanel> {
  final _scroll = ScrollController();
  int _lastLength = 0;

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final theme = Theme.of(context);
    if (session.log.length != _lastLength) {
      _lastLength = session.log.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
    final progress = session.progress;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (session.busy || progress != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(children: [
              Expanded(
                child: LinearProgressIndicator(value: progress?.fraction),
              ),
              const SizedBox(width: 12),
              Text(
                progress == null
                    ? (session.currentOperation ?? 'Working…')
                    : '${progress.label} ${progress.done.bytesString} / ${progress.total.bytesString}',
                style: theme.textTheme.labelMedium,
              ),
            ]),
          ),
        Expanded(
          child: Container(
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: theme.dividerColor),
            ),
            child: Stack(children: [
              SelectionArea(
                child: ListView.builder(
                  controller: _scroll,
                  itemCount: session.log.length,
                  itemBuilder: (context, i) {
                    final line = session.log[i];
                    final t = line.time;
                    final stamp = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:'
                        '${t.second.toString().padLeft(2, '0')}';
                    return Text(
                      '$stamp  ${line.message}',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        color: line.error ? theme.colorScheme.error : null,
                      ),
                    );
                  },
                ),
              ),
              Positioned(
                right: 0,
                top: 0,
                child: IconButton(
                  tooltip: 'Clear log',
                  icon: const Icon(Icons.clear_all, size: 18),
                  onPressed: session.clearLog,
                ),
              ),
            ]),
          ),
        ),
      ],
    );
  }
}
