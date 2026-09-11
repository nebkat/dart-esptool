import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;
import 'package:esptool/esptool.dart' show EspLoader;

/// `esp_ota_img_states_t` — recorded in [OtaDataSelectEntry.state].
enum OtaImageState {
  /// `ESP_OTA_IMG_NEW` — written by the OTA update; the bootloader turns it
  /// into [pendingVerify] on first boot when rollback is enabled.
  newImage(0x0),
  pendingVerify(0x1),
  valid(0x2),
  invalid(0x3),
  aborted(0x4),

  /// `ESP_OTA_IMG_UNDEFINED` — also what any unknown value decodes to.
  undefined(0xFFFFFFFF);

  const OtaImageState(this.value);
  final int value;

  static OtaImageState fromValue(int value) =>
      values.firstWhere((s) => s.value == value, orElse: () => OtaImageState.undefined);
}

/// Which of the two otadata copies (one per sector of the 8K partition) an
/// entry lives in.
enum OtaDataCopy {
  a,
  b;

  /// Byte offset of this copy within the otadata partition.
  int get offset => this == a ? 0 : EspLoader.flashSectorSize;

  OtaDataCopy get other => this == a ? b : a;
}

/// One `esp_ota_select_entry_t`: the boot sequence counter and image state
/// the bootloader uses to pick an OTA slot. Layout (little-endian):
/// `seq:u32`, 20 bytes of `0xFF` (`seq_label`), `ota_state:u32`, `crc:u32`.
class OtaDataSelectEntry {
  const OtaDataSelectEntry(this.seq, [this.state = OtaImageState.newImage]);

  /// The entry that makes [otaSlot] resolve to [slot] with the lowest sequence.
  const OtaDataSelectEntry.fromOtaSlot(int slot) : this(slot + 1);

  /// `sizeof(esp_ota_select_entry_t)`.
  static const int size = 32;

  /// Boot sequence number; the bootloader boots the copy with the highest one
  /// and derives the slot from it (see [otaSlot]).
  final int seq;
  final OtaImageState state;

  /// CRC over the little-endian [seq] with initial value `0xFFFFFFFF`
  /// (`bootloader_common_ota_select_crc`).
  static int crcOf(int seq) => getCrc32(Uint8List(4)..buffer.asByteData().setUint32(0, seq, Endian.little), 0xFFFFFFFF);

  int get crc => crcOf(seq);

  /// Decode the entry at [start], or `null` if the copy is blank/invalid: an
  /// erased sequence (`0xFFFFFFFF`) or a CRC mismatch.
  static OtaDataSelectEntry? fromBytes(Uint8List bytes, [int start = 0]) {
    final data = ByteData.sublistView(bytes, start, start + size);
    final seq = data.getUint32(0, Endian.little);
    final state = data.getUint32(24, Endian.little);
    final crc = data.getUint32(28, Endian.little);
    if (seq == 0xFFFFFFFF || crc != crcOf(seq)) return null;
    return OtaDataSelectEntry(seq, OtaImageState.fromValue(state));
  }

  Uint8List toBytes() {
    final out = Uint8List(size)..fillRange(4, 24, 0xFF);
    final data = ByteData.sublistView(out);
    data.setUint32(0, seq, Endian.little);
    data.setUint32(24, state.value, Endian.little);
    data.setUint32(28, crc, Endian.little);
    return out;
  }

  /// Pick the live entry the way the bootloader does: the valid copy with the
  /// higher sequence, `b` winning ties. Both `null` when neither is valid.
  static ({OtaDataSelectEntry? entry, OtaDataCopy? copy}) select(OtaDataSelectEntry? a, OtaDataSelectEntry? b) {
    if (a == null && b == null) return (entry: null, copy: null);
    if (b == null) return (entry: a, copy: OtaDataCopy.a);
    if (a == null) return (entry: b, copy: OtaDataCopy.b);
    return a.seq > b.seq ? (entry: a, copy: OtaDataCopy.a) : (entry: b, copy: OtaDataCopy.b);
  }

  /// The `ota_N` slot this sequence number selects among [otaAppCount] slots.
  int otaSlot(int otaAppCount) => (seq - 1) % otaAppCount;

  /// The next entry that selects [otaSlot]: the smallest increase of [seq]
  /// (1..[otaAppCount]) that lands on that slot.
  OtaDataSelectEntry incremented(int otaSlot, int otaAppCount) {
    final diff = ((otaSlot - this.otaSlot(otaAppCount)) + otaAppCount - 1) % otaAppCount + 1;
    return OtaDataSelectEntry(seq + diff);
  }

  @override
  bool operator ==(Object other) => other is OtaDataSelectEntry && other.seq == seq && other.state == state;

  @override
  int get hashCode => Object.hash(seq, state);

  @override
  String toString() => 'OtaDataSelectEntry(seq: $seq, state: ${state.name})';
}

/// The decoded otadata state of a device: the live [entry] (if any), the
/// [copy] it was read from, and how many OTA app slots the table has.
class OtaDataParameters {
  const OtaDataParameters({required this.entry, required this.copy, required this.appCount});

  /// Combine the two copies read from the otadata partition (see
  /// [OtaDataSelectEntry.select]).
  factory OtaDataParameters.select(OtaDataSelectEntry? a, OtaDataSelectEntry? b, {required int appCount}) {
    final selected = OtaDataSelectEntry.select(a, b);
    return OtaDataParameters(entry: selected.entry, copy: selected.copy, appCount: appCount);
  }

  final OtaDataSelectEntry? entry;
  final OtaDataCopy? copy;
  final int appCount;

  /// The parameters to write to switch the device to [otaSlot]: a bumped
  /// sequence written into the *other* copy, so the old entry survives until
  /// the new one is complete (a fresh entry, into copy `b`, if none is valid).
  OtaDataParameters incrementedAndSwapped(int otaSlot) => OtaDataParameters(
        entry: entry?.incremented(otaSlot, appCount) ?? OtaDataSelectEntry.fromOtaSlot(otaSlot),
        copy: copy == OtaDataCopy.b ? OtaDataCopy.a : OtaDataCopy.b,
        appCount: appCount,
      );

  /// The currently selected OTA slot, or `null` when no entry is valid (the
  /// bootloader then falls back to the factory/first app).
  int? get slot => entry?.otaSlot(appCount);

  /// The slot an OTA update would target next.
  int get nextSlot => entry == null ? 0 : (entry!.otaSlot(appCount) + 1) % appCount;

  @override
  bool operator ==(Object other) =>
      other is OtaDataParameters && other.entry == entry && other.copy == copy && other.appCount == appCount;

  @override
  int get hashCode => Object.hash(entry, copy, appCount);

  @override
  String toString() => 'OtaDataParameters(entry: $entry, copy: ${copy?.name}, appCount: $appCount)';
}
