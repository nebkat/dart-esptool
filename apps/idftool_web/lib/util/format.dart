/// Number formatting shared by the pages.
library;

extension SessionFormatting on int {
  String get hex => '0x${toRadixString(16)}';
  String get bytesString {
    if (this >= 1024 * 1024) return '${(this / (1024 * 1024)).toStringAsFixed(this % (1024 * 1024) == 0 ? 0 : 2)} MiB';
    if (this >= 1024) return '${(this / 1024).toStringAsFixed(this % 1024 == 0 ? 0 : 1)} KiB';
    return '$this B';
  }
}
