import 'int_literal.dart';
import 'partition_table.dart';

/// A partition label could not be resolved, or a slice/offset falls outside it.
class PartitionLookupException implements Exception {
  PartitionLookupException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A byte range inside a partition: [address] is absolute in flash.
typedef PartitionSlice = ({PartitionDefinition partition, int address, int length});

/// An absolute flash [address] inside a partition.
typedef PartitionAddress = ({PartitionDefinition partition, int address});

/// Resolves the partition labels users type on the command line against a
/// [PartitionTable] plus the two regions that aren't rows in the table but
/// are addressed like partitions: the table sector itself and the bootloader.
///
/// Labels are a partition name (`nvs`), or a number matching a partition's
/// exact start offset (`0x9000`), optionally followed by a Python-style slice:
///
/// * `name[start:stop]` — bounds relative to the partition; negative bounds
///   count from its end.
/// * `name[start:+len]` — `+` makes the stop relative to the start.
/// * `name[start]` — from `start` to the end of the partition.
class PartitionResolver {
  const PartitionResolver(this.table, {required this.partitionTableEntry, this.bootloaderEntry});

  /// Build the resolver the CLI uses: the table's own `partition_table` and
  /// `bootloader` rows if the CSV had them, else virtual entries from the
  /// offsets. The bootloader entry is omitted when its offset is unknown (it
  /// is chip dependent).
  factory PartitionResolver.forTable(
    PartitionTable table, {
    int partitionTableOffset = PartitionTable.defaultOffset,
    int partitionTableSize = PartitionTable.size,
    int? primaryBootloaderOffset,
  }) {
    final tableEntry = table.firstWhere(
      (p) => p.isPrimaryPartitionTable,
      orElse: () => PartitionDefinition.partitionTable(offset: partitionTableOffset, size: partitionTableSize),
    );
    PartitionDefinition? bootloaderEntry;
    for (final p in table) {
      if (p.isPrimaryBootloader) bootloaderEntry = p;
    }
    if (bootloaderEntry == null && primaryBootloaderOffset != null) {
      bootloaderEntry = PartitionDefinition.bootloader(
        offset: primaryBootloaderOffset,
        size: partitionTableOffset - primaryBootloaderOffset,
      );
    }
    return PartitionResolver(table, partitionTableEntry: tableEntry, bootloaderEntry: bootloaderEntry);
  }

  final PartitionTable table;
  final PartitionDefinition partitionTableEntry;
  final PartitionDefinition? bootloaderEntry;

  // The bracket part is optional as a whole, so an unparsable suffix is
  // swallowed by the lazy `.+?` and reported as an unknown partition name,
  // as in the original tool.
  static final _sliceRegex = RegExp(r'^(?<partition>.+?)'
      r'(?:\[(?:(?<start>[-+]?(?:0x)?[0-9A-Fa-f]+)?(?::(?<stop>[-+]?(?:0x)?[0-9A-Fa-f]+)?)?)?\])?$');
  static final _offsetRegex = RegExp(r'^(?<partition>.+?)(?:\[(?:(?<start>[-+]?(?:0x)?[0-9A-Fa-f]+)?)?\])?$');

  /// Resolve a bare [label]: a numeric label must equal a real partition's
  /// offset (the virtual entries don't count); a name matches real partitions
  /// first, then the table/bootloader entries.
  PartitionDefinition partition(String label) {
    final address = tryParseIntLiteral(label);
    if (address != null) {
      return table.firstWhere(
        (p) => p.offset == address,
        orElse: () => throw PartitionLookupException('No partition at offset ${hex(address)}'),
      );
    }
    final named = table.findByName(label);
    if (named != null) return named;
    if (label == partitionTableEntry.name) return partitionTableEntry;
    if (bootloaderEntry case final bootloader? when label == bootloader.name) return bootloader;
    throw PartitionLookupException("No partition named '$label'");
  }

  /// Resolve `label[start:stop]` to an absolute range (see [PartitionResolver]).
  PartitionSlice slice(String spec) {
    final match = _sliceRegex.firstMatch(spec);
    if (match == null) throw PartitionLookupException('Invalid partition slice format: $spec');
    final name = match.namedGroup('partition')!;
    final startText = match.namedGroup('start');
    final stopText = match.namedGroup('stop');

    final part = partition(name);

    var start = startText == null ? 0 : _bound(startText, spec);
    if (start < 0) start += part.size;

    int stop;
    if (stopText == null) {
      stop = part.size;
    } else {
      stop = _bound(stopText, spec);
      if (stopText.startsWith('+')) stop += start;
      if (stop < 0) stop += part.size;
    }

    if (start < 0 || stop < 0 || start > part.size || stop > part.size || start > stop) {
      throw PartitionLookupException(
          'Invalid slice range [${hex(start)}:${hex(stop)}] for partition $name of size ${hex(part.size)}');
    }
    return (partition: part, address: part.offset + start, length: stop - start);
  }

  /// Resolve `label[offset]` to an absolute address (see [PartitionResolver]).
  /// Unlike [slice], the address may equal the partition's end.
  PartitionAddress address(String spec) {
    final match = _offsetRegex.firstMatch(spec);
    if (match == null) throw PartitionLookupException('Invalid partition offset format: $spec');
    final name = match.namedGroup('partition')!;
    final startText = match.namedGroup('start');

    final part = partition(name);

    var start = startText == null ? 0 : _bound(startText, spec);
    if (start < 0) start += part.size;

    if (start < 0 || start > part.size) {
      throw PartitionLookupException('Invalid offset [${hex(start)}] for partition $name of size ${hex(part.size)}');
    }
    return (partition: part, address: part.offset + start);
  }

  // The regex admits bare hex digits (`ff`) that aren't a valid literal
  // without a `0x` prefix; Python let `int()` raise on those.
  static int _bound(String text, String spec) =>
      tryParseIntLiteral(text) ?? (throw PartitionLookupException("Invalid slice bound '$text' in $spec"));
}
