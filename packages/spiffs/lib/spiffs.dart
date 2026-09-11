/// Pure-Dart SPIFFS filesystem images: read the files out of an ESP-IDF
/// `spiffs` partition ([SpiffsVolume]) and build one ([spiffsCreate]).
library;

export 'src/builder.dart' show SpiffsSource, spiffsCreate;
export 'src/layout.dart' show SpiffsConfig, SpiffsException, SpiffsFlags, SpiffsObjType;
export 'src/volume.dart' show SpiffsEntry, SpiffsVolume;
