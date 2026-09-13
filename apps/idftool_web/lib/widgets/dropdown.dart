import 'package:flutter/material.dart';

/// The app's one dropdown: a Material 3 [DropdownMenu] with a floating
/// [label] and, while nothing is selected, a [hint] in the field. Height
/// comes from the theme's input decoration, which matches the buttons.
class AppDropdown<T> extends StatelessWidget {
  const AppDropdown({
    super.key,
    required this.value,
    required this.entries,
    required this.onSelected,
    this.label,
    this.hint,
    this.width,
    this.enabled = true,
  });

  final T? value;
  final List<DropdownMenuEntry<T>> entries;
  final ValueChanged<T?> onSelected;
  final String? label;
  final String? hint;
  final double? width;
  final bool enabled;

  @override
  Widget build(BuildContext context) => DropdownMenu<T>(
        initialSelection: value,
        dropdownMenuEntries: entries,
        onSelected: onSelected,
        width: width,
        enabled: enabled,
        requestFocusOnTap: false,
        // DropdownMenu only applies a decoration theme passed here, not the
        // ambient one, so hand it the app's.
        inputDecorationTheme: Theme.of(context).inputDecorationTheme,
        // DropdownMenu's own decoration puts its arrow in a padded
        // IconButton that is 48 px tall, which forces the field to 48 px
        // however dense the theme is. A plain icon lets the field follow
        // the theme (the whole field is the button anyway).
        decorationBuilder: (context, controller) => InputDecoration(
          label: label == null ? null : Text(label!),
          hintText: hint,
          suffixIcon: Icon(controller.isOpen ? Icons.arrow_drop_up : Icons.arrow_drop_down),
        ),
      );
}
