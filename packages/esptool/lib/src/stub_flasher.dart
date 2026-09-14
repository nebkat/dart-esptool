import 'dart:convert';
import 'dart:typed_data';
import 'package:esp_defs/esp_defs.dart';

import 'stub_flasher.g.dart';

/// A prebuilt flasher-stub binary for one chip: the small program esptool
/// uploads to RAM to replace the ROM loader's slow, feature-poor flash
/// routines (compressed writes, fast reads, erase, ...).
///
/// The images are vendored from esptool (see `tool/gen_stubs.dart`).
class StubFlasherImage {
  const StubFlasherImage({
    required this.entry,
    required this.textStart,
    required this.text,
    required this.dataStart,
    required this.data,
    required this.bssStart,
  });

  /// Look up the stub for [chip], or `null` if none is vendored.
  static StubFlasherImage? forChip(EspChip chip) => stubFlasherImages[chip];

  /// Entry point address to jump to once uploaded.
  final int entry;

  /// IRAM load address of [text].
  final int textStart;

  /// Base64 of the code segment.
  final String text;

  /// DRAM load address of [data].
  final int dataStart;

  /// Base64 of the initialised-data segment.
  final String data;

  /// Start of the stub's BSS; with [dataStart]+data length this bounds the
  /// DRAM the stub occupies.
  final int bssStart;

  Uint8List get textBytes => base64Decode(text);
  Uint8List get dataBytes => base64Decode(data);

  /// RAM ranges `(start, end)` the running stub occupies — code in IRAM,
  /// bss+data in DRAM. Used to refuse RAM loads that would clobber it.
  List<(int, int)> get residentRanges => [
        (bssStart, dataStart + dataBytes.length),
        (textStart, textStart + textBytes.length),
      ];
}
