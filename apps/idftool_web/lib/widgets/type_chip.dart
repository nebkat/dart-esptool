import 'package:flutter/material.dart';

/// A small tinted label — used for partition types/subtypes, NVS namespaces
/// and value types, where colour lets the eye group rows by kind.
class TypeChip extends StatelessWidget {
  const TypeChip(this.label, this.color, {super.key});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: dark ? 0.45 : 0.22),
        border: Border.all(color: color.withValues(alpha: 0.8)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(label,
          style: TextStyle(
            fontSize: 12,
            fontFamily: 'RobotoMono',
            color: dark ? Color.lerp(color, Colors.white, 0.45) : Color.lerp(color, Colors.black, 0.35),
          )),
    );
  }
}

/// A stable, distinct hue for an arbitrary name (NVS namespaces), evenly
/// spread by hashing so similar names don't collide.
Color colorForName(String name) {
  var h = 0;
  for (final c in name.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return HSLColor.fromAHSL(1, (h % 360).toDouble(), 0.5, 0.45).toColor();
}
