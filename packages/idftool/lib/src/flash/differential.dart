import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:esptool/esptool.dart';

/// Hashes [size] bytes of flash at [address] on the device and returns the
/// lowercase hex MD5 — [EspLoader.flashMd5]. Abstracted so the planning logic
/// can be tested against a fake flash.
typedef FlashMd5 = Future<String> Function(int address, int size);

/// Size of the first chunk [flashMatches] compares — one flash sector. An app
/// image keeps its header at 0 and its `esp_app_desc_t` (project name,
/// version, ELF SHA-256) at 0x20, so a different build almost always differs
/// inside this first sector and is caught by a single ~15 ms hash instead of
/// one covering the whole image.
const checkFirstChunkSize = 0x1000;

/// Size of every chunk after the first. `SPI_FLASH_MD5` costs a flat ~2 ms per
/// call on top of ~3.3 s/MB (ESP32-S3 stub), so chunking a 2 MB image this way
/// adds about 1% to the cost of a full match and buys a 32x earlier exit on a
/// mismatch.
const checkChunkSize = 0x10000;

/// Granularity of the differential scan — the flash erase sector, the smallest
/// region that can be rewritten on its own.
const diffSectorSize = 0x1000;

/// hash / (write + verify), the constant the bail-out rule is built on.
/// Measured on an ESP32-S3 over native USB: hashing 3.72 s/MB at sector
/// granularity, writing 8.60 s/MB, verifying 3.27 s/MB — a true ratio of
/// 0.318, nudged up so the threshold is exactly 0.70 at the first decision
/// point. It is the fast-transport figure deliberately: on a 115200 UART
/// bridge the true ratio is ~0.07 and scanning is almost always worth it, so
/// erring towards the fast case never gambles more than the quickest link
/// would justify.
const diffCostRatio = 0.343;

/// How much of a region is scanned before the bail-out rule is first
/// consulted (as a fraction 1/n), and the bounds that is clamped to. Changes
/// cluster at the front of an app image — a rebuild with only a new version
/// string rewrites the app descriptor and nothing else — so judged on its
/// first sector such an image looks 100% changed, and without a floor the scan
/// would be abandoned and megabytes rewritten to avoid writing one sector.
const diffMinSampleFraction = 8;
const diffMinSampleMin = 0x10000;
const diffMinSampleMax = 0x40000;

/// How many matching sectors are worth rewriting to keep one run going rather
/// than starting another. Each separate write costs ~69 ms fixed (erase
/// command, compression, round trips, its own verify) against ~31 ms to erase
/// and write one more sector inside a run — bridging a gap of two pays,
/// three does not.
const diffCoalesceSectors = 2;

/// Why a [SectorWrite] was planned.
enum SectorWriteReason {
  /// A run of sectors that differ from flash.
  changed,

  /// Everything left when the scan was abandoned as not worth continuing;
  /// nothing more follows it.
  remainder,
}

/// A write the sector-by-sector comparison calls for, relative to the region
/// start.
typedef SectorWrite = ({int offset, int length, SectorWriteReason reason});

String _md5(List<int> bytes) => md5.convert(bytes).toString();

/// The bytes the loader would put in flash for [data]: padded to a 4-byte
/// boundary. (esptool additionally rewrites the flash mode/size/frequency
/// header of an image at the bootloader offset; this port only supports
/// `keep`, so no rewrite happens.) Compare against these, not the input, or a
/// region that is already in flash never matches.
Uint8List bytesAsWritten(Uint8List data) {
  final padded = (data.length + 3) & ~3;
  if (padded == data.length) return data;
  return Uint8List(padded)
    ..setRange(0, data.length, data)
    ..fillRange(data.length, padded, 0xFF);
}

/// Whether flash at [address] already holds [data], without reading it back:
/// the device hashes each chunk itself, so the cost is its own flash read, not
/// the serial link. Chunked so a mismatch ends the comparison early — one
/// sector first, then [checkChunkSize] at a time. [data] must already be
/// [bytesAsWritten].
Future<bool> flashMatches(FlashMd5 flashMd5, int address, Uint8List data) async {
  var offset = 0;
  while (offset < data.length) {
    final size = (offset == 0 ? checkFirstChunkSize : checkChunkSize).clamp(0, data.length - offset);
    if (await flashMd5(address + offset, size) != _md5(Uint8List.sublistView(data, offset, offset + size))) {
      return false;
    }
    offset += size;
  }
  return true;
}

/// The writes a sector-by-sector comparison calls for, yielded as the scan
/// finds them so the caller can write each run while the scan continues. A
/// region already in flash yields nothing. [data] must be [bytesAsWritten] and
/// [address] sector-aligned. [onScanned] reports bytes compared so far.
///
/// Scanning costs ~3.7 s/MB and only pays if enough of the region matches,
/// which is learned while scanning: after `fraction` of the region is scanned
/// with `dirty` of it differing, the hashing already done is spent either way,
/// so it is worth carrying on while `dirty < 1 - diffCostRatio * (1 - fraction)`.
/// The threshold rises as the scan proceeds (0.70 an eighth in, 0.83 at half,
/// 0.97 at nine tenths) because a late abandonment throws away nearly all the
/// hashing and saves nearly none of it; [diffMinSampleFraction] holds the rule
/// off until enough has been seen to be worth believing.
Stream<SectorWrite> planSectorWrites(
  FlashMd5 flashMd5,
  int address,
  Uint8List data, {
  void Function(int scanned)? onScanned,
  int sectorSize = diffSectorSize,
  int coalesce = diffCoalesceSectors,
}) async* {
  final total = data.length;
  final minimum = (total ~/ diffMinSampleFraction).clamp(diffMinSampleMin, diffMinSampleMax);
  int? runStart, runEnd;
  var dirty = 0, sectors = 0, offset = 0;

  while (offset < total) {
    final size = sectorSize.clamp(0, total - offset);
    if (await flashMd5(address + offset, size) != _md5(Uint8List.sublistView(data, offset, offset + size))) {
      runStart ??= offset;
      runEnd = offset + size;
      dirty++;
    } else if (runEnd != null && offset - runEnd >= coalesce * sectorSize) {
      // Far enough past the open run that a fresh write is cheaper than bridging.
      yield (offset: runStart!, length: runEnd - runStart, reason: SectorWriteReason.changed);
      runStart = runEnd = null;
    }
    offset += size;
    sectors++;
    onScanned?.call(offset);

    if (minimum <= offset && offset < total && dirty / sectors >= 1 - diffCostRatio * (1 - offset / total)) {
      final start = runStart ?? offset;
      yield (offset: start, length: total - start, reason: SectorWriteReason.remainder);
      return;
    }
  }

  if (runStart != null) {
    yield (offset: runStart, length: runEnd! - runStart, reason: SectorWriteReason.changed);
  }
}

/// How a write should decide what actually needs writing.
enum WriteStrategy {
  /// Write everything, no comparison.
  always,

  /// Hash the whole region against flash first; skip the write if identical.
  skipFlashed,

  /// Compare a sector at a time and write only the runs that differ
  /// ([planSectorWrites]). Supersedes [skipFlashed].
  differential,
}

/// What a [writeFlashRegion] did.
class WriteOutcome {
  const WriteOutcome({required this.written, required this.runs, required this.abandoned, required this.elapsed});

  /// Bytes actually written (0 when the region was already in flash).
  final int written;

  /// Separate writes issued.
  final int runs;

  /// Whether the differential scan gave up part-way and wrote the rest in full.
  final bool abandoned;

  final Duration elapsed;

  bool get skipped => written == 0;
}

/// Progress of a [writeFlashRegion]: bytes compared so far (only advances on
/// the comparing strategies) and bytes written so far, both out of `total`.
typedef WriteProgress = void Function({required int scanned, required int written, required int total});

/// Write [data] to flash at [address] using [strategy], verifying each write
/// with an on-device MD5. The loader must be connected (ideally with the stub
/// running — compressed writes, and MD5 that is always available).
///
/// This is python idftool's `write_flash` with esptool's `write_flash` folded
/// in: for [WriteStrategy.differential] each run of changed sectors is written
/// and verified separately as the scan reaches it, so the verification covers
/// what was written rather than the whole region.
Future<WriteOutcome> writeFlashRegion(
  EspLoader loader,
  int address,
  Uint8List data, {
  WriteStrategy strategy = WriteStrategy.differential,
  WriteProgress? onProgress,
}) async {
  final prepared = bytesAsWritten(data);
  final total = prepared.length;
  final stopwatch = Stopwatch()..start();
  var written = 0, runs = 0;
  var scanned = 0;
  void report() => onProgress?.call(scanned: scanned, written: written, total: total);

  Future<void> writeRun(int offset, int length) async {
    final slice = Uint8List.sublistView(prepared, offset, offset + length);
    await loader.writeFlash(address + offset, slice, onProgress: (done, _) {
      onProgress?.call(scanned: scanned, written: written + done, total: total);
    });
    final expected = _md5(slice);
    final actual = await loader.flashMd5(address + offset, length);
    if (actual != expected) {
      throw EspException('Verification failed at 0x${(address + offset).toRadixString(16)}: '
          'device MD5 $actual, expected $expected');
    }
    written += length;
    runs++;
    report();
  }

  // A region not starting on a sector boundary can't be rewritten a sector at
  // a time: the write would erase the sector it starts inside, taking whatever
  // shares it. Rare (partition offsets are sector-aligned); fall back to the
  // whole-region comparison.
  if (strategy == WriteStrategy.differential && address % diffSectorSize == 0 && total > 0) {
    var abandoned = false;
    await for (final run in planSectorWrites(loader.flashMd5, address, prepared, onScanned: (n) {
      scanned = n;
      report();
    })) {
      if (run.reason == SectorWriteReason.remainder) abandoned = true;
      await writeRun(run.offset, run.length);
    }
    return WriteOutcome(written: written, runs: runs, abandoned: abandoned, elapsed: stopwatch.elapsed);
  }

  if (strategy != WriteStrategy.always && total > 0) {
    if (await flashMatches(loader.flashMd5, address, prepared)) {
      scanned = total;
      report();
      return WriteOutcome(written: 0, runs: 0, abandoned: false, elapsed: stopwatch.elapsed);
    }
  }
  if (total > 0) await writeRun(0, total);
  return WriteOutcome(written: written, runs: runs, abandoned: false, elapsed: stopwatch.elapsed);
}
