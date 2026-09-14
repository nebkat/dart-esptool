/// Espressif chip definitions and firmware image formats, with no I/O: the
/// chip table, the ESP image header and its metadata, the app descriptor
/// and the reset reasons. What a tool needs to read firmware files and name
/// chips without talking to a device; `package:esptool` builds the serial
/// protocol on top and re-exports this.
library;

export 'src/app_description.dart';
export 'src/chip.dart';
export 'src/image_metadata.dart';
export 'src/reset_reason.dart';
