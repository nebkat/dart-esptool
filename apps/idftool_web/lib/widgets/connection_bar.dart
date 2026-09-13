import 'package:flutter/material.dart';

import '../session/device_session.dart';
import 'dropdown.dart';
import 'port_picker.dart';

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
              PortPicker(session: session, enabled: !locked),
              Tooltip(
                message: 'Connect briefly to every granted port to learn its chip and MAC (each device is reset)',
                child: FilledButton.tonalIcon(
                  onPressed: session.busy || session.ports.isEmpty ? null : session.identifyAll,
                  icon: const Icon(Icons.search),
                  label: const Text('Identify all'),
                ),
              ),
              AppDropdown<ResetChoice>(
                value: session.reset,
                label: 'Reset',
                width: 240,
                entries: [for (final r in ResetChoice.values) DropdownMenuEntry(value: r, label: r.label)],
                enabled: !locked,
                onSelected: (v) {
                  if (v != null) session.setReset(v);
                },
              ),
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
