import 'package:flutter/material.dart';
import 'package:idftool/idftool.dart';

import '../session/device_session.dart';
import 'partition_grid.dart';

/// The flash laid out as a bar, the way desktop partition editors draw a
/// disk: one segment per partition (virtual bootloader/table rows included)
/// in the same type/subtype colours as the grid, with unused gaps hatched.
///
/// Sizes span four orders of magnitude (a 4 KiB table on a 16 MiB chip), so
/// the bar is linear but every partition gets at least a minimum width and
/// the rest is scaled to fit — proportions stay readable without the small
/// ones vanishing.
class PartitionMap extends StatelessWidget {
  const PartitionMap({super.key, required this.rows, required this.flashSize, this.activeSlot, this.onTap});

  final List<PartitionDefinition> rows;

  /// Total flash, so trailing free space shows; falls back to the table's
  /// extent when unknown.
  final int? flashSize;
  final int? activeSlot;
  final ValueChanged<PartitionDefinition>? onTap;

  static const _height = 46.0;
  static const _minPartitionWidth = 10.0;
  static const _minGapWidth = 3.0;

  @override
  Widget build(BuildContext context) {
    final sorted = List.of(rows)..sort((a, b) => a.offset.compareTo(b.offset));
    final extent = sorted.fold(0, (n, p) => p.end > n ? p.end : n);
    final total = flashSize != null && flashSize! >= extent ? flashSize! : extent;
    if (total == 0) return const SizedBox.shrink();

    // Segments in address order, gaps included.
    final segments = <_Segment>[];
    var cursor = 0;
    for (final p in sorted) {
      if (p.offset > cursor) segments.add(_Segment.gap(cursor, p.offset - cursor));
      segments.add(_Segment.partition(p));
      if (p.end > cursor) cursor = p.end;
    }
    if (total > cursor) segments.add(_Segment.gap(cursor, total - cursor));

    final theme = Theme.of(context);
    return LayoutBuilder(builder: (context, constraints) {
      final widths = _fit(segments, total, constraints.maxWidth);
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          height: _height,
          child: Row(children: [
            for (var i = 0; i < segments.length; i++) SizedBox(width: widths[i], child: _segment(context, segments[i], widths[i])),
          ]),
        ),
        const SizedBox(height: 4),
        _ruler(theme, total),
      ]);
    });
  }

  /// Linear widths, then any partition narrower than the minimum is pinned
  /// there and the others shrink to make room, repeated until nothing new
  /// gets pinned. Gaps only get a hairline so they never steal the space.
  static List<double> _fit(List<_Segment> segments, int total, double width) {
    final pinned = List<bool>.filled(segments.length, false);
    final widths = List<double>.filled(segments.length, 0);
    while (true) {
      var pinnedWidth = 0.0;
      var freeBytes = 0;
      for (var i = 0; i < segments.length; i++) {
        if (pinned[i]) {
          pinnedWidth += widths[i];
        } else {
          freeBytes += segments[i].size;
        }
      }
      final scale = freeBytes == 0 ? 0.0 : (width - pinnedWidth).clamp(0, width) / freeBytes;
      var changed = false;
      for (var i = 0; i < segments.length; i++) {
        if (pinned[i]) continue;
        final min = segments[i].partition == null ? _minGapWidth : _minPartitionWidth;
        final w = segments[i].size * scale;
        if (w < min) {
          widths[i] = min;
          pinned[i] = true;
          changed = true;
        } else {
          widths[i] = w;
        }
      }
      if (!changed) break;
    }
    // Rounding can overshoot by a pixel or two; trim the widest.
    final excess = widths.fold(0.0, (a, b) => a + b) - width;
    if (excess > 0) {
      var widest = 0;
      for (var i = 1; i < widths.length; i++) {
        if (widths[i] > widths[widest]) widest = i;
      }
      widths[widest] = (widths[widest] - excess).clamp(0, width);
    }
    return widths;
  }

  Widget _segment(BuildContext context, _Segment s, double width) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final p = s.partition;
    if (p == null) {
      return Tooltip(
        message: 'Unused: ${s.offset.hex} – ${(s.offset + s.size).hex} (${s.size.bytesString})',
        child: CustomPaint(painter: _HatchPainter(theme.colorScheme.outlineVariant)),
      );
    }
    final fill = subtypeColor(p);
    final border = typeColor(p.type);
    final active = p.isOtaApp && activeSlot == p.subtype - AppSubtype.otaMin;
    final label = width >= 60;
    return Tooltip(
      richMessage: TextSpan(children: [
        TextSpan(text: '${p.name}\n', style: const TextStyle(fontWeight: FontWeight.bold)),
        TextSpan(text: '${p.typeName} / ${p.subtypeName}\n${p.offset.hex} – ${p.end.hex}  ·  ${p.size.bytesString}${active ? '\nboots this slot' : ''}'),
      ]),
      child: InkWell(
        onTap: onTap == null ? null : () => onTap!(p),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 0.5),
          decoration: BoxDecoration(
            color: fill.withValues(alpha: dark ? 0.5 : 0.28),
            border: Border.all(color: border.withValues(alpha: 0.9), width: active ? 2 : 1),
            borderRadius: BorderRadius.circular(3),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: label
              ? Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    if (active) const Padding(padding: EdgeInsets.only(right: 2), child: Icon(Icons.play_arrow, size: 12, color: Colors.green)),
                    Flexible(child: Text(p.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: 'RobotoMono', fontSize: 12))),
                  ]),
                  Text(p.size.bytesString, overflow: TextOverflow.ellipsis, style: TextStyle(fontFamily: 'RobotoMono', fontSize: 10, color: theme.hintColor)),
                ])
              : active
                  ? const Center(child: Icon(Icons.play_arrow, size: 12, color: Colors.green))
                  : null,
        ),
      ),
    );
  }

  /// Address ticks along the bottom: start, quarters, end.
  Widget _ruler(ThemeData theme, int total) {
    final style = TextStyle(fontFamily: 'RobotoMono', fontSize: 10, color: theme.hintColor);
    return Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      for (var i = 0; i <= 4; i++) Text((total * i ~/ 4).hex, style: style),
    ]);
  }
}

class _Segment {
  const _Segment.partition(PartitionDefinition this.partition)
      : offset = 0,
        _size = 0;
  const _Segment.gap(this.offset, this._size) : partition = null;

  final PartitionDefinition? partition;
  final int offset;
  final int _size;

  int get size => partition?.size ?? _size;
}

/// Diagonal hatching for unused flash.
class _HatchPainter extends CustomPainter {
  const _HatchPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.6)
      ..strokeWidth = 1;
    canvas.drawRect(Offset.zero & size, Paint()..color = color.withValues(alpha: 0.12));
    for (var x = -size.height; x < size.width; x += 6) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), paint);
    }
  }

  @override
  bool shouldRepaint(_HatchPainter old) => old.color != color;
}
