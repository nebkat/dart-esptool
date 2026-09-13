import 'package:flutter/material.dart';

import '../session/device_session.dart';
import 'dropdown.dart';
import 'port_item.dart';

/// The granted serial ports as a dropdown, with a last entry that asks the
/// browser for access to another one (Web Serial only exposes ports the
/// user has explicitly granted).
class PortPicker extends StatefulWidget {
  const PortPicker({super.key, required this.session, this.width = 420, this.enabled = true});
  final DeviceSession session;
  final double width;
  final bool enabled;

  @override
  State<PortPicker> createState() => _PortPickerState();
}

/// The "grant another" entry's value; ports are their index in the list
/// (a JS interop type can't be the entry value without runtime checks).
const _grant = -1;

class _PortPickerState extends State<PortPicker> {
  /// Bumped when the grant entry is chosen so the field's text goes back to
  /// the selected port even if the user cancels the browser's chooser.
  int _nonce = 0;

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final selected = session.selectedPort;
    final index = selected == null ? null : session.ports.indexOf(selected);
    return AppDropdown<int>(
      key: ValueKey((selected == null ? null : session.labelFor(selected), _nonce)),
      value: index == null || index < 0 ? null : index,
      label: 'Port',
      hint: session.ports.isEmpty ? 'No port granted' : 'Select…',
      width: widget.width,
      enabled: widget.enabled,
      entries: [
        for (final (i, p) in session.ports.indexed)
          DropdownMenuEntry(value: i, label: session.labelFor(p), labelWidget: PortItem(session: session, port: p)),
        const DropdownMenuEntry(value: _grant, label: 'Grant access to another port…', leadingIcon: Icon(Icons.usb)),
      ],
      onSelected: (v) {
        if (v == null) return;
        if (v == _grant) {
          setState(() => _nonce++);
          session.requestPort();
        } else if (v < session.ports.length) {
          session.selectPort(session.ports[v]);
        }
      },
    );
  }
}
