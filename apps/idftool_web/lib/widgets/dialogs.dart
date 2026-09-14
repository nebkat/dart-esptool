import 'package:flutter/material.dart';

/// A yes/no confirmation; `true` when the user chose [action].
Future<bool> confirm(BuildContext context, {required String title, required String message, String action = 'Continue', bool destructive = false}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SelectableText(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          style: destructive ? FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error) : null,
          onPressed: () => Navigator.pop(context, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// Show [text] in a scrollable monospace dialog.
Future<void> showText(BuildContext context, {required String title, required String text}) => showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 800,
          child: SingleChildScrollView(child: SelectableText(text, style: const TextStyle(fontFamily: 'RobotoMono', fontSize: 12))),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
      ),
    );

/// Ask for one line of text; `null` if cancelled.
Future<String?> prompt(BuildContext context, {required String title, String? label, String? hint, String initial = '', String action = 'OK'}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: label, hintText: hint, border: const OutlineInputBorder()),
          style: const TextStyle(fontFamily: 'RobotoMono', fontSize: 13),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: Text(action)),
      ],
    ),
  ).whenComplete(controller.dispose);
}
