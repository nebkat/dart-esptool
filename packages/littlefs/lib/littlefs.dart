/// Pure-Dart littlefs filesystem images.
///
/// [LittleFsVolume.mount] reads a littlefs v2 image (disk versions 2.0 and
/// 2.1, as written by `esp_littlefs` and littlefs-python) and lists and
/// reads its files. Nothing here touches `dart:io`, so it runs in the browser.
library;

export 'src/common.dart';
export 'src/volume.dart';
