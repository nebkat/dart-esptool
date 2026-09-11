/// Pure-Dart FAT filesystem images for ESP-IDF `fat` partitions, with the
/// wear levelling container they are normally wrapped in.
///
/// Reading: [FatVolume.mount] (which unwraps wear levelling by itself) gives
/// a listing and file contents. Building: [fatCreate] produces a whole
/// partition image, byte-identical to idftool's `create-fs`. The wear
/// levelling layer is also exposed on its own ([wlWrap], [wlUnwrap],
/// [looksLikeWl], [wlFilesystemSize]).
library;

export 'src/builder.dart' show FatSource, fatCreate, make8dot3Name;
export 'src/common.dart' show FatAttr, FatBits, FatException, FatLayout;
export 'src/geometry.dart' show FatGeometry, solveGeometry;
export 'src/volume.dart' show FatEntry, FatVolume;
export 'src/wear_levelling.dart' show WearLevellingException, WlLayout, looksLikeWl, wlFilesystemSize, wlUnwrap, wlWrap;
