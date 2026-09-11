import 'package:flutter/material.dart';

/// A compact text field for an address or length in `0x` hex.
class HexField extends StatelessWidget {
  const HexField({super.key, required this.controller, required this.label, this.width = 150});
  final TextEditingController controller;
  final String label;
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: TextField(
        controller: controller,
        style: const TextStyle(fontFamily: 'RobotoMono'),
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), isDense: true),
      ),
    );
  }
}
