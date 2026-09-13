/// A serial monitor model for ESP-IDF devices: bytes in, styled and parsed
/// lines out, with filtering. No I/O and no Flutter — the web app and a CLI
/// both drive it.
library;

export 'src/ansi.dart';
export 'src/buffer.dart';
export 'src/filter.dart';
export 'src/line.dart';
export 'src/splitter.dart';
