import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

/// The app's name as a link to its repository: `@nebkat / ESP-IDF Flasher`.
class AppTitle extends StatelessWidget {
  const AppTitle({super.key});

  static const owner = 'nebkat';
  static const name = 'ESP-IDF Flasher';
  static const repository = 'https://github.com/nebkat/dart-esptool';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Tooltip(
      message: repository,
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: () => web.window.open(repository, '_blank'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Text.rich(
            TextSpan(children: [
              TextSpan(text: '@$owner', style: TextStyle(color: scheme.outline)),
              TextSpan(text: ' / ', style: TextStyle(color: scheme.outlineVariant)),
              TextSpan(text: name, style: TextStyle(color: scheme.onSurface, fontWeight: FontWeight.w600)),
            ]),
            style: theme.textTheme.titleMedium,
          ),
        ),
      ),
    );
  }
}
