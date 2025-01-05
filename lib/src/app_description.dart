import 'dart:typed_data';

import 'package:json_annotation/json_annotation.dart';
import 'package:pub_semver/pub_semver.dart';

part 'app_description.g.dart';

/// ESP-IDF firmware app description `esp_app_desc_t`
/// @see [https://github.com/espressif/esp-idf/blob/master/components/esp_app_format/include/esp_app_desc.h]
/// @see [https://docs.espressif.com/projects/esp-idf/en/stable/esp32/api-reference/system/app_image_format.html#application-description]
/// @see [https://docs.espressif.com/projects/esp-idf/en/stable/esp32/api-reference/system/misc_system_api.html#_CPPv414esp_app_desc_t]
@JsonSerializable(createFactory: false, includeIfNull: false)
class AppDescription {
  /// `ESP_APP_DESC_MAGIC_WORD`
  static const magic = 0xABCD5432;

  /// `sizeof(esp_app_desc_t)`
  static const size = 256;

  const AppDescription({
    required this.projectName,
    required this.version,
    required this.idfVersion,
    required this.secureVersion,
    required this.compiled,
    required this.elfSha256,
  });

  factory AppDescription.fromBytes(Uint8List buffer) {
    if (buffer.lengthInBytes < 256) {
      throw FormatException("Invalid app description, expected >= 256 bytes, got ${buffer.length}");
    }

    final view = ByteData.sublistView(buffer);

    if (view.getUint32(0, Endian.little) != AppDescription.magic) {
      throw FormatException("Invalid firmware file, magic not found");
    }

    final time = String.fromCharCodes(buffer.sublist(80, 80 + 16).takeWhile((v) => v != 0));
    final date = String.fromCharCodes(buffer.sublist(96, 96 + 16).takeWhile((v) => v != 0));

    return AppDescription(
      projectName: String.fromCharCodes(buffer.sublist(48, 48 + 32).takeWhile((v) => v != 0)),
      version: String.fromCharCodes(buffer.sublist(16, 16 + 32).takeWhile((v) => v != 0)),
      idfVersion: String.fromCharCodes(buffer.sublist(112, 112 + 32).takeWhile((v) => v != 0)),
      secureVersion: view.getUint32(4, Endian.little),
      compiled: date.isNotEmpty && time.isNotEmpty ? "$date $time" : null,
      elfSha256: buffer.sublist(144, 144 + 32),
    );
  }

  static AppDescription? fromBytesOrNull(Uint8List buffer) {
    try {
      return AppDescription.fromBytes(buffer);
    } catch (e) {
      return null;
    }
  }

  final String projectName;
  final String version;
  final String idfVersion;
  final int secureVersion;
  final String? compiled;
  @JsonKey(includeToJson: false)
  final Uint8List elfSha256;

  String get _versionWithoutV => version.startsWith("v") ? version.substring(1) : version;

  @JsonKey(includeFromJson: false, includeToJson: false)
  Version get semver => Version.parse(_versionWithoutV);
  @JsonKey(name: "elfSha256", includeFromJson: false)
  String get elfSha256String => elfSha256.map((e) => e.toRadixString(16).padLeft(2, '0')).join("");

  Map<String, dynamic> toJson() => _$AppDescriptionToJson(this);

  @override
  String toString() => "$runtimeType${toJson()}";
}
