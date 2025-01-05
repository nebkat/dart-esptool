import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:esptool/esptool.dart';
import 'package:json_annotation/json_annotation.dart';

part 'image_metadata.g.dart';

/// ESP-IDF firmware image metadata (`esp_image_metadata_t`)
///
/// @see [https://github.com/espressif/esp-idf/blob/master/components/bootloader_support/include/esp_image_format.h]
/// @see [https://docs.espressif.com/projects/esptool/en/latest/esp32/advanced-topics/firmware-image-format.html]
@JsonSerializable(createFactory: false)
class ImageMetadata {
  ///< `ESP_ROM_CHECKSUM_INITIAL` / `ESP_CHECKSUM_MAGIC`
  static const checksumMagic = 0xEF;

  ImageMetadata._({
    required this.header,
    required this.segments,
    required this.digest,
    this.appDescription,
  });

  factory ImageMetadata.fromBytes(Uint8List buffer) {
    final header = ImageHeader.fromBytes(Uint8List.sublistView(buffer, 0, ImageHeader.size));
    var offset = ImageHeader.size;
    final segments = <({int offset, int length, int address})>[];
    int checksum = ImageMetadata.checksumMagic;
    late final AppDescription? appDescription;
    for (int i = 0; i < header.segmentCount; i++) {
      final segmentHeaderView = ByteData.sublistView(buffer, offset, offset + 8);
      offset += 8;
      final segment = (
        offset: offset,
        length: segmentHeaderView.getUint32(4, Endian.little),
        address: segmentHeaderView.getUint32(4, Endian.little),
      );

      final data = Uint8List.sublistView(buffer, offset, offset + segment.length);

      checksum = data.fold(checksum, (a, b) => (a ^ b) & 0xFF);

      // Populate app description from first segment
      if (i == 0) {
        appDescription = AppDescription.fromBytesOrNull(data);
      }

      offset += segment.length;
      segments.add(segment);
    }

    // Add a byte for the checksum
    offset++;

    // Pad to next full 16 byte block
    offset = (offset + 15) & ~15;

    // Checksum (simple)
    final expectedChecksum = buffer[offset - 1];
    if (checksum != expectedChecksum) {
      // TODO custom error
      throw Exception("Checksum mismatch: "
          "expected 0x${expectedChecksum.toRadixString(16).padLeft(2, "0")}, "
          "got 0x${checksum.toRadixString(16).padLeft(2, "0")}");
    }

    // Hash (SHA-256)
    final digest = Uint8List.fromList(sha256.convert(buffer.sublist(0, offset)).bytes);
    if (header.hashAppended) {
      final expectedDigest = buffer.sublist(offset, offset + 32);

      if (!(const ListEquality<int>().equals(expectedDigest, digest))) {
        throw Exception("SHA-256 hash mismatch: "
            "expected ${_digestToString(expectedDigest)}, "
            "got ${_digestToString(digest)}");
      }
    }

    return ImageMetadata._(
      header: header,
      segments: segments,
      digest: digest,
      appDescription: appDescription,
    );
  }

  static ImageMetadata? fromBytesOrNull(Uint8List buffer) {
    try {
      return ImageMetadata.fromBytes(buffer);
    } catch (e) {
      return null;
    }
  }

  Map<String, dynamic> toJson() => _$ImageMetadataToJson(this);

  @override
  String toString() => "$runtimeType${toJson()}";

  final ImageHeader header;
  final List<({int offset, int length, int address})> segments;
  @JsonKey(toJson: _digestToString)
  Uint8List digest;
  final AppDescription? appDescription;
}

/// ESP-IDF firmware image header (`esp_image_header_t`)
///
/// @see [https://github.com/espressif/esp-idf/blob/master/components/bootloader_support/include/esp_app_format.h]
/// @see [https://docs.espressif.com/projects/esp-idf/en/stable/esp32/api-reference/system/app_image_format.html#application-image-structures]
/// @see [https://docs.espressif.com/projects/esp-idf/en/stable/esp32/api-reference/system/app_image_format.html#_CPPv418esp_image_header_t]
/// @see [https://docs.espressif.com/projects/esptool/en/latest/esp32/advanced-topics/firmware-image-format.html]
@JsonSerializable(createFactory: false)
class ImageHeader {
  /// `ESP_IMAGE_HEADER_MAGIC`
  static const magic = 0xE9;

  /// `ESP_IMAGE_MAX_SEGMENTS`
  static const maxSegments = 16;

  /// `sizeof(esp_image_header_t)`
  static const size = 24;

  /// `WP_PIN_DISABLED`
  static const wpPinDisabled = 0xEE;

  ImageHeader._({
    required this.segmentCount,
    required this.spiMode,
    required this.spiFrequency,
    required this.spiSize,
    required this.entryAddress,
    required this.wpPin,
    required this.spiPinDrv,
    required this.chipId,
    required this.minChipRev,
    required this.minChipRevFull,
    required this.maxChipRevFull,
    required this.hashAppended,
  });

  factory ImageHeader.fromBytes(Uint8List buffer) {
    if (buffer.lengthInBytes < 24) {
      throw FormatException("Invalid image header: expected >= 24 bytes, got ${buffer.lengthInBytes}");
    }

    final view = ByteData.sublistView(buffer);

    if (view.getUint8(0) != ImageHeader.magic) {
      throw FormatException("Invalid image header, magic not found: "
          "expected 0x${ImageHeader.magic.toRadixString(16)}, got "
          "0x${view.getUint8(0).toRadixString(16).padLeft(2, "0")}");
    }

    final segmentCount = view.getUint8(1);
    if (segmentCount == 0 || segmentCount > ImageHeader.maxSegments) {
      throw FormatException("Invalid image header, bad segment count: "
          "expected 1..${ImageHeader.maxSegments}, got $segmentCount");
    }

    final wpPin = view.getUint8(8);

    return ImageHeader._(
      segmentCount: segmentCount,
      spiMode: ImageSpiMode.fromValue(view.getUint8(2)),
      spiFrequency: ImageSpiFrequency.fromValue(view.getUint8(3) & 0xF),
      spiSize: ImageFlashSize.fromValue(view.getUint8(3) >> 4),
      entryAddress: view.getUint32(4, Endian.little),
      wpPin: wpPin == ImageHeader.wpPinDisabled ? null : wpPin,
      spiPinDrv: (view.getUint8(9), view.getUint8(10), view.getUint8(11)),
      chipId: ChipId.fromValue(view.getUint16(12, Endian.little)),
      minChipRev: view.getUint8(14),
      minChipRevFull: view.getUint16(15, Endian.little),
      maxChipRevFull: view.getUint16(17, Endian.little),
      hashAppended: view.getUint8(23) == 1,
    );
  }

  Map<String, dynamic> toJson() => _$ImageHeaderToJson(this);

  @override
  String toString() => "$runtimeType${toJson()}";

  final int segmentCount;
  final ImageSpiMode? spiMode;
  final ImageSpiFrequency? spiFrequency;
  final ImageFlashSize? spiSize;
  final int entryAddress;
  final int? wpPin;
  final (int, int, int) spiPinDrv;
  final ChipId? chipId;
  final int minChipRev;
  final int minChipRevFull;
  final int maxChipRevFull;
  final bool hashAppended;
}

/// `esp_image_spi_mode_t`
enum ImageSpiMode {
  qio(0x0),
  qout(0x1),
  dio(0x2),
  dout(0x3),
  fastRead(0x4),
  slowRead(0x5);

  const ImageSpiMode(this.value);
  static ImageSpiMode? fromValue(int value) => ImageSpiMode.values.firstWhereOrNull((e) => e.value == value);

  final int value;
}

/// `esp_image_spi_freq_t`
enum ImageSpiFrequency {
  div1(0xF),
  div2(0x0),
  div3(0x1),
  div4(0x2);

  const ImageSpiFrequency(this.value);
  static ImageSpiFrequency? fromValue(int value) => ImageSpiFrequency.values.firstWhereOrNull((e) => e.value == value);

  final int value;
}

/// `esp_image_flash_size_t`
enum ImageFlashSize {
  mb1(0x0),
  mb2(0x1),
  mb4(0x2),
  mb8(0x3),
  mb16(0x4),
  mb32(0x5),
  mb64(0x6),
  mb128(0x7);

  const ImageFlashSize(this.value);
  static ImageFlashSize? fromValue(int value) => ImageFlashSize.values.firstWhereOrNull((e) => e.value == value);

  final int value;
}

/// `esp_chip_id_t`
///
/// @see [https://github.com/espressif/esp-idf/blob/master/components/bootloader_support/include/esp_app_format.h]
enum ChipId {
  esp32(0x0000),
  esp32s2(0x0002),
  esp32c3(0x0005),
  esp32s3(0x0009),
  esp32c2(0x000C),
  esp32c6(0x000D),
  esp32h2(0x0010),
  esp32p4(0x0012),
  esp32c5(0x0017);

  const ChipId(this.value);
  static ChipId? fromValue(int value) => ChipId.values.firstWhereOrNull((e) => e.value == value);

  final int value;
}

_digestToString(Uint8List digest) => digest.map((e) => e.toRadixString(16).padLeft(2, "0")).join("");
