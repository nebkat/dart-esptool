import 'package:esptool/web.dart';
import 'package:flutter/material.dart';

import '../session/device_session.dart';

/// A port in a picker: the adapter on the first line and, once known, the
/// chip and MAC (or why it couldn't be identified) as a subtitle.
class PortItem extends StatelessWidget {
  const PortItem({super.key, required this.session, required this.port});
  final DeviceSession session;
  final SerialPort port;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final identity = session.identities[port];
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(DeviceSession.describePort(port), overflow: TextOverflow.ellipsis),
      if (identity != null)
        Text(
          identity.label,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            fontFamily: 'RobotoMono',
            color: identity.error != null ? theme.colorScheme.error : theme.colorScheme.primary,
          ),
        ),
    ]);
  }
}

/// The same port as one line, for the closed field of a picker.
Widget portSummary(DeviceSession session, SerialPort port) => Text(session.labelFor(port), overflow: TextOverflow.ellipsis);
