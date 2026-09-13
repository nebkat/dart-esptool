import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idftool_web/theme.dart';
import 'package:idftool_web/widgets/dropdown.dart';

void main() {
  testWidgets('buttons, dropdowns and text fields share one height', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: appTheme(Brightness.light),
      home: Scaffold(
        body: Row(children: [
          OutlinedButton.icon(onPressed: () {}, icon: const Icon(Icons.usb), label: const Text('Button')),
          FilledButton(onPressed: () {}, child: const Text('Filled')),
          AppDropdown<int>(
            key: const Key('dd'),
            value: 1,
            label: 'Label',
            entries: const [DropdownMenuEntry(value: 1, label: 'One'), DropdownMenuEntry(value: 2, label: 'Two')],
            onSelected: (_) {},
          ),
          const SizedBox(width: 160, child: TextField(key: Key('tf'), decoration: InputDecoration(labelText: 'Field'))),
        ]),
      ),
    ));
    final button = tester.getSize(find.byType(OutlinedButton));
    final filled = tester.getSize(find.byType(FilledButton));
    final dropdown = tester.getSize(find.byKey(const Key('dd')));
    final field = tester.getSize(find.byKey(const Key('tf')));
    expect(button.height, 40);
    expect(filled.height, 40);
    expect(dropdown.height, 40);
    expect(field.height, 40);
  });
}
