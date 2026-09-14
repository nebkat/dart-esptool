import 'package:flutter/material.dart';

/// One flash operation as a row: an icon, the partition (or role) name and
/// its offset in monospace, then what happens there. [warning] turns the
/// icon into a warning sign and adds a line below. [onRemove] gives a
/// close button; [trailing] replaces it with something else. [leading]
/// goes before the icon (a step number or status).
class OpTile extends StatelessWidget {
  const OpTile({
    super.key,
    required this.icon,
    required this.name,
    required this.detail,
    required this.summary,
    this.warning,
    this.onRemove,
    this.trailing,
    this.leading,
  });
  final IconData icon;
  final String name;
  final String detail;
  final String summary;
  final String? warning;
  final VoidCallback? onRemove;
  final Widget? trailing;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Row(mainAxisSize: MainAxisSize.min, children: [
        if (leading != null) ...[leading!, const SizedBox(width: 8)],
        Icon(warning == null ? icon : Icons.warning_amber, color: warning == null ? null : scheme.error),
      ]),
      title: Row(children: [
        SizedBox(width: 160, child: Text(name, style: const TextStyle(fontFamily: 'RobotoMono', fontSize: 13))),
        SizedBox(width: 100, child: Text(detail, style: const TextStyle(fontFamily: 'RobotoMono', fontSize: 13))),
        Expanded(child: Text(summary)),
      ]),
      subtitle: warning == null ? null : Text(warning!, style: TextStyle(color: scheme.error)),
      trailing: trailing ?? (onRemove == null ? null : IconButton(tooltip: 'Remove from plan', icon: const Icon(Icons.close, size: 18), onPressed: onRemove)),
    );
  }
}
