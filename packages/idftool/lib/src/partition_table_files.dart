import 'int_literal.dart';
import 'partition_table.dart';

/// On-disk partition table formats.
enum PartitionTableFormat {
  csv,
  bin;

  /// Pick the output format from an explicit choice, else the output file's
  /// extension (`.csv`, `.bin`/`.img`), else CSV.
  static PartitionTableFormat resolve({String? outputFile, PartitionTableFormat? explicit}) {
    if (explicit != null) return explicit;
    if (outputFile == null) return csv;
    switch (_extension(outputFile).toLowerCase()) {
      case '.csv':
        return csv;
      case '.bin' || '.img':
        return bin;
      default:
        throw PartitionTableException(
            "Cannot infer partition table format from '$outputFile'; pass --format csv|bin or use a .csv/.bin extension");
    }
  }

  // `os.path.splitext`: the last dot of the basename, unless it's the
  // leading dot of a hidden file.
  static String _extension(String path) {
    final slash = path.lastIndexOf(RegExp(r'[/\\]'));
    final base = path.substring(slash + 1);
    final dot = base.lastIndexOf('.');
    if (dot <= 0) return '';
    if (base.substring(0, dot).codeUnits.every((c) => c == 0x2E)) return ''; // e.g. `..foo`
    return base.substring(dot);
  }
}

/// Recover the primary/recovery bootloader offsets from literal `bootloader`
/// rows in [csvText], if it has any with a numeric offset (first of each wins).
///
/// idftool writes those offsets into the CSV it dumps, so a dumped table can
/// be loaded again without re-specifying them.
({int? primary, int? recovery}) extractCsvBootloaderOffsets(String csvText) {
  int? primary, recovery;
  for (final rawLine in csvText.split(RegExp(r'\r\n|\r|\n'))) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final parts = line.split(',').map((p) => p.trim()).toList();
    if (parts.length < 4 || parts[1] != PartitionType.bootloader.keyword) continue;
    final offset = tryParseIntLiteral(parts[3]);
    if (offset == null) continue;
    if (parts[2] == BootloaderSubtype.primary.keyword) {
      primary ??= offset;
    } else if (parts[2] == BootloaderSubtype.recovery.keyword) {
      recovery ??= offset;
    }
  }
  return (primary: primary, recovery: recovery);
}

/// Parse partition-table CSV, filling in bootloader offsets the caller didn't
/// supply from the CSV's own bootloader rows ([extractCsvBootloaderOffsets]),
/// and rejecting an empty table. [source] names the origin for error messages.
///
/// A bootloader row whose offset can't be determined is reported with a hint
/// about the CLI flag that provides it, replacing the terse parser error.
PartitionTable parsePartitionTableCsv(
  String csvText, {
  required String source,
  int partitionTableOffset = PartitionTable.defaultOffset,
  int? primaryBootloaderOffset,
  int? recoveryBootloaderOffset,
  Map<String, String> variables = const {},
}) {
  if (primaryBootloaderOffset == null || recoveryBootloaderOffset == null) {
    final fromCsv = extractCsvBootloaderOffsets(csvText);
    primaryBootloaderOffset ??= fromCsv.primary;
    recoveryBootloaderOffset ??= fromCsv.recovery;
  }
  final PartitionTable table;
  try {
    table = PartitionTable.fromCsv(
      csvText,
      partitionTableOffset: partitionTableOffset,
      primaryBootloaderOffset: primaryBootloaderOffset,
      recoveryBootloaderOffset: recoveryBootloaderOffset,
      variables: variables,
    );
  } on PartitionTableException catch (e) {
    final message = e.message.toLowerCase();
    if (!message.contains('bootloader offset is not provided')) rethrow;
    final which = message.contains('recovery') ? 'recovery' : 'primary';
    final flag = which == 'primary'
        ? '--primary-bootloader-offset (an address or a chip name, e.g. esp32s3)'
        : '--recovery-bootloader-offset';
    final line = RegExp(r'line (\d+)').firstMatch(e.message);
    final where = line == null ? '' : ' (line ${line[1]})';
    throw PartitionTableException(
        'The $which bootloader entry in $source$where has no offset. Add the offset to the CSV, or pass $flag.');
  }
  return table.requireNotEmpty(source);
}
