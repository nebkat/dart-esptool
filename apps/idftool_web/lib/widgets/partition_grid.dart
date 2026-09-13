import 'package:esptool/esptool.dart';
import 'package:flutter/material.dart';
import 'package:idftool/idftool.dart';

import '../session/device_session.dart';
import 'type_chip.dart';

/// The partition table as a grid: name, type, subtype, offset, size, flags,
/// a caller-supplied contents column, an optional extra column, and a
/// right-aligned actions column. Rows not in [table] itself (the virtual
/// bootloader and partition-table entries) are shown in italics.
class PartitionGrid extends StatelessWidget {
  const PartitionGrid({
    super.key,
    required this.rows,
    required this.table,
    required this.contents,
    required this.actions,
    this.activeSlot,
    this.extraColumn,
    this.extra,
    this.rowColor,
    this.rowKey,
    this.highlighted = false,
  });

  final List<PartitionDefinition> rows;
  final PartitionTable table;

  /// The OTA slot that boots, to mark its `ota_N` row.
  final int? activeSlot;
  final Widget Function(PartitionDefinition p) contents;
  final List<Widget> Function(PartitionDefinition p) actions;

  /// Heading and cell builder for one more column before the actions.
  final String? extraColumn;
  final Widget Function(PartitionDefinition p)? extra;
  final Color? Function(PartitionDefinition p)? rowColor;

  /// A key for the name cell, so callers can hit-test rows.
  final Key? Function(PartitionDefinition p)? rowKey;

  /// Draw a primary-coloured border (a drag is over the grid).
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      shape: highlighted ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(4), side: BorderSide(color: scheme.primary, width: 2)) : null,
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: constraints.maxWidth),
            child: DataTable(
              columnSpacing: 20,
              dataTextStyle: const TextStyle(fontFamily: 'RobotoMono', fontSize: 13),
              headingTextStyle: const TextStyle(fontFamily: 'RobotoMono', fontWeight: FontWeight.bold, fontSize: 13),
              columns: [
                const DataColumn(label: Text('Name')),
                const DataColumn(label: Text('Type')),
                const DataColumn(label: Text('Subtype')),
                const DataColumn(label: Text('Offset')),
                const DataColumn(label: Text('Size')),
                const DataColumn(label: Text('Flags')),
                const DataColumn(label: Text('Contents')),
                if (extraColumn != null) DataColumn(label: Text(extraColumn!)),
                const DataColumn(label: Text(''), numeric: true),
              ],
              rows: [for (final p in rows) _row(p, scheme)],
            ),
          ),
        ),
      ),
    );
  }

  DataRow _row(PartitionDefinition p, ColorScheme scheme) {
    final virtual = !table.any((t) => identical(t, p));
    final color = rowColor?.call(p) ?? (virtual ? scheme.surfaceContainerHighest.withValues(alpha: 0.5) : null);
    return DataRow(
      color: color == null ? null : WidgetStatePropertyAll(color),
      cells: [
        DataCell(Row(key: rowKey?.call(p), children: [
          Text(p.name, style: virtual ? const TextStyle(fontStyle: FontStyle.italic) : null),
          if (p.isOtaApp && activeSlot == p.subtype - AppSubtype.otaMin)
            const Padding(padding: EdgeInsets.only(left: 6), child: Icon(Icons.play_arrow, size: 16, color: Colors.green)),
        ])),
        DataCell(TypeChip(p.typeName, typeColor(p.type))),
        DataCell(TypeChip(p.subtypeName, subtypeColor(p))),
        DataCell(Text(p.offset.hex)),
        DataCell(Text('${p.size.hex} (${p.size.bytesString})')),
        DataCell(Text(p.flagNames.join(', '))),
        DataCell(contents(p)),
        if (extraColumn != null) DataCell(extra!(p)),
        DataCell(Row(mainAxisSize: MainAxisSize.min, children: actions(p))),
      ],
    );
  }
}

/// The app descriptor text for [p] from [apps] (by offset), or nothing.
String appContents(Map<int, AppDescription> apps, PartitionDefinition p) {
  final app = apps[p.offset];
  return app == null || !p.isApp ? '' : '${app.projectName} ${app.version}';
}

/// One hue per partition type, so the table scans by kind; each subtype
/// sits at its own point in a narrow band around that hue (ordered by the
/// subtype's position among its type's known subtypes), so kinds stay
/// grouped while subtypes remain distinguishable.
double _typeHue(int type) => switch (PartitionType.fromValue(type)) {
      PartitionType.bootloader => 20, // orange
      PartitionType.partitionTable => 45, // amber
      PartitionType.app => 140, // green
      PartitionType.data => 215, // blue
      null => 0,
    };

Color typeColor(int type) => PartitionType.fromValue(type) == null ? Colors.grey : HSLColor.fromAHSL(1, _typeHue(type), 0.6, 0.45).toColor();

Color subtypeColor(PartitionDefinition p) {
  if (p.knownType == null) return Colors.grey;
  final known = subtypeKeywords(p.type).values.toList()..sort();
  final index = known.indexOf(p.subtype);
  if (index < 0) return typeColor(p.type);
  // Spread the known subtypes over ±25° of hue and a little lightness, so
  // neighbours differ but never leave the type's colour family.
  final t = known.length == 1 ? 0.5 : index / (known.length - 1);
  return HSLColor.fromAHSL(1, (_typeHue(p.type) - 25 + 50 * t) % 360, 0.55, 0.38 + 0.2 * t).toColor();
}
