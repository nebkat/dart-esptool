/// Port of python idftool: partition tables, NVS, OTA data, differential
/// flashing and bundles for ESP-IDF devices, on top of `package:esptool`.
///
/// Everything in `lib/` is pure Dart (no `dart:io`) so it runs in the
/// browser; the CLI in `bin/` adds the desktop serial transport.
library;

export 'src/bundle.dart';
export 'src/device.dart';
export 'src/flash/differential.dart';
export 'src/fs/fs.dart';
export 'src/int_literal.dart';
export 'src/manifest.dart';
export 'src/nvs/nvs.dart';
export 'src/otadata.dart';
export 'src/partition_slice.dart';
export 'src/partition_table.dart';
export 'src/partition_table_files.dart';
export 'src/report.dart';
