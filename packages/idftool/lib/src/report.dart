/// Human-readable reports shared by the CLI and the web tool.
library;

import 'dart:typed_data';

import 'package:esptool/esptool.dart';

import 'int_literal.dart';
import 'otadata.dart';
import 'partition_table.dart';

/// The app descriptor of [image] (which must have one), one field per line.
String formatAppInfo(ImageMetadata image, {String indent = ''}) {
  final d = image.appDescription!;
  final h = image.header;
  return [
    '${indent}Project name:     ${d.projectName}',
    '${indent}Version:          ${d.version}',
    '${indent}IDF version:      ${d.idfVersion}',
    '${indent}Secure version:   ${d.secureVersion}',
    '${indent}Compiled:         ${d.date} ${d.time}',
    '${indent}ELF SHA256:       ${d.elfSha256.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}',
    '${indent}Chip:             ${h.chipId?.name ?? 'unknown'}',
  ].join('\n');
}

/// An ESP image's header and segments, plus its app descriptor if it is an
/// application (a bootloader has none).
String formatImageInfo(ImageMetadata image) {
  final h = image.header;
  final out = StringBuffer()
    ..writeln('Chip:             ${h.chipId?.name ?? 'unknown'}')
    ..writeln('Entry point:      ${hex(h.entryAddress)}')
    ..writeln('Min chip rev:     v${h.minChipRevFull ~/ 100}.${h.minChipRevFull % 100}')
    ..writeln('Hash appended:    ${h.hashAppended ? 'yes' : 'no'}')
    ..writeln('Segments:         ${image.segments.length}');
  for (final (i, s) in image.segments.indexed) {
    out.writeln('  ${i.toString().padLeft(2)}: ${hex(s.length).padLeft(8)} bytes at ${hex(s.address)} (file offset ${hex(s.offset)})');
  }
  if (image.appDescription != null) {
    out
      ..writeln()
      ..writeln('App descriptor:')
      ..write(formatAppInfo(image, indent: '  '));
  }
  return out.toString().trimRight();
}

/// The partition table plus app info for every app partition whose contents
/// parse as an application, reading each partition via [read].
Future<String> formatTableWithApps(PartitionTable table, Future<Uint8List> Function(int offset, int length) read,
    {OtaDataParameters? otadata}) async {
  final out = StringBuffer(table.format(otadata: otadata));
  for (final p in table.where((p) => p.isApp)) {
    final image = ImageMetadata.fromBytesOrNull(await read(p.offset, p.size), appRequired: true);
    if (image == null) continue;
    out.writeln("\n\nPartition '${p.name}' (offset=${hex(p.offset)}):");
    out.write(formatAppInfo(image, indent: '  '));
  }
  return out.toString();
}
