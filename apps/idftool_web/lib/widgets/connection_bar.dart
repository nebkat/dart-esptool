import 'package:esptool/web.dart';
import 'package:flutter/material.dart';

import '../session/device_session.dart';
import 'port_item.dart';

/// The always-visible connection bar: port, reset strategy, stub toggle and
/// connect/disconnect, so any page can (re)connect.
class ConnectionBar extends StatelessWidget {
  const ConnectionBar({super.key, required this.session});
  final DeviceSession session;

  @override
  Widget build(BuildContext context) {
    final locked = session.connected || session.busy;
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: SizedBox(
          width: double.infinity,
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 420,
                child: DropdownButtonFormField<SerialPort>(
                  key: ValueKey(session.selectedPort),
                  initialValue: session.selectedPort,
                  isExpanded: true,
                  decoration: const InputDecoration(
                      labelText: 'Port',
                      border: OutlineInputBorder(),
                      isDense: true),
                  itemHeight: null,
                  items: [
                    for (final p in session.ports)
                      DropdownMenuItem(
                          value: p,
                          child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: PortItem(session: session, port: p))),
                  ],
                  // The closed field is one line tall; show the label flat there.
                  selectedItemBuilder: (context) => [
                    for (final p in session.ports)
                      Align(alignment: Alignment.centerLeft, child: portSummary(session, p)),
                  ],
                  onChanged: locked ? null : session.selectPort,
                  hint: const Text('No port granted'),
                ),
              ),
              OutlinedButton.icon(
                onPressed: locked ? null : session.requestPort,
                icon: const Icon(Icons.usb),
                label: const Text('Add port…'),
              ),
              Tooltip(
                message: 'Connect briefly to every granted port to learn its chip and MAC (each device is reset)',
                child: OutlinedButton.icon(
                  onPressed: session.busy || session.ports.isEmpty ? null : session.identifyAll,
                  icon: const Icon(Icons.search),
                  label: const Text('Identify all'),
                ),
              ),
              SizedBox(
                width: 240,
                child: DropdownButtonFormField<ResetChoice>(
                  key: ValueKey(session.reset),
                  initialValue: session.reset,
                  decoration: const InputDecoration(
                      labelText: 'Reset',
                      border: OutlineInputBorder(),
                      isDense: true),
                  items: [
                    for (final r in ResetChoice.values)
                      DropdownMenuItem(value: r, child: Text(r.label))
                  ],
                  onChanged: locked ? null : (v) => session.setReset(v!),
                ),
              ),
              Row(mainAxisSize: MainAxisSize.min, children: [
                Checkbox(
                    value: session.useStub,
                    onChanged: locked ? null : (v) => session.setUseStub(v!)),
                const Text('Flasher stub'),
              ]),
              if (!session.connected)
                FilledButton.icon(
                  onPressed: session.busy || session.selectedPort == null
                      ? null
                      : session.connect,
                  icon: session.busy
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.link),
                  label: Text(session.busy ? 'Connecting…' : 'Connect'),
                )
              else ...[
                Chip(
                  avatar: const Icon(Icons.check_circle,
                      size: 18, color: Colors.green),
                  label: Text(
                      '${session.chip?.name}  ·  ${session.flashSize?.bytesString ?? '?'}  ·  ${session.macString ?? ''}'),
                ),
                FilledButton.tonalIcon(
                  onPressed: session.busy
                      ? null
                      : () => session.disconnect(hardReset: true),
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('Reset & disconnect'),
                ),
                TextButton(
                  onPressed: session.busy
                      ? null
                      : () => session.disconnect(hardReset: false),
                  child: const Text('Disconnect'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
