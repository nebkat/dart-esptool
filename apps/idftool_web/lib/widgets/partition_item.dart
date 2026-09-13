import 'package:flutter/material.dart';
import 'package:idftool/idftool.dart';

import '../session/device_session.dart';
import 'partition_grid.dart';

/// A partition in a picker: its name, then type/subtype and size as a
/// subtitle in the subtype's colour (the same hues as the grid and map).
class PartitionItem extends StatelessWidget {
  const PartitionItem({super.key, required this.partition});
  final PartitionDefinition partition;

  /// The one-line form for a closed field.
  static String label(PartitionDefinition p) => '${p.name} (${p.subtypeName}, ${p.size.bytesString})';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = partition;
    final color = subtypeColor(p);
    final dark = theme.brightness == Brightness.dark;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(p.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: 'RobotoMono')),
      Text(
        '${p.typeName}/${p.subtypeName} · ${p.size.bytesString} at ${p.offset.hex}',
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          fontFamily: 'RobotoMono',
          color: dark ? Color.lerp(color, Colors.white, 0.35) : Color.lerp(color, Colors.black, 0.2),
        ),
      ),
    ]);
  }
}
