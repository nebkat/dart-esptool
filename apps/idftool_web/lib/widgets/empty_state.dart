import 'package:flutter/material.dart';

/// What a page shows when there is nothing to show yet: an icon, a short
/// title, a sentence of guidance and, below them, the [actions] that would
/// fill the page — all centred. With no device and nothing opened a page
/// is just this; once there is content the toolbar takes over at the top.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.message, this.actions = const [], this.error = false});

  /// The state every device-backed page shows while nothing is connected.
  const EmptyState.noDevice({super.key, this.message, this.actions = const []})
      : icon = Icons.usb_off,
        title = 'No device connected',
        error = false;

  final IconData icon;
  final String title;
  final String? message;
  final List<Widget> actions;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tint = error ? scheme.error : scheme.outline;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 40, color: tint),
            const SizedBox(height: 12),
            Text(title, style: theme.textTheme.titleMedium?.copyWith(color: error ? scheme.error : null), textAlign: TextAlign.center),
            if (message != null) ...[
              const SizedBox(height: 6),
              Text(message!, style: TextStyle(color: scheme.outline), textAlign: TextAlign.center),
            ],
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 16),
              Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: actions),
            ],
          ]),
        ),
      ),
    );
  }
}

/// The body while a read is in flight.
class LoadingState extends StatelessWidget {
  const LoadingState(this.label, {super.key});
  final String label;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(label, style: TextStyle(color: Theme.of(context).colorScheme.outline)),
          ]),
        ),
      );
}
