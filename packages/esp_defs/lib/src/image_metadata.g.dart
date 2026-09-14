// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'image_metadata.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Map<String, dynamic> _$ImageMetadataToJson(ImageMetadata instance) =>
    <String, dynamic>{
      'header': instance.header,
      'segments': instance.segments
          .map((e) => <String, dynamic>{
                'address': e.address,
                'length': e.length,
                'offset': e.offset,
              })
          .toList(),
      'digest': _digestToString(instance.digest),
      'appDescription': instance.appDescription,
    };

Map<String, dynamic> _$ImageHeaderToJson(ImageHeader instance) =>
    <String, dynamic>{
      'segmentCount': instance.segmentCount,
      'spiMode': _$ImageSpiModeEnumMap[instance.spiMode],
      'spiFrequency': _$ImageSpiFrequencyEnumMap[instance.spiFrequency],
      'spiSize': _$ImageFlashSizeEnumMap[instance.spiSize],
      'entryAddress': instance.entryAddress,
      'wpPin': instance.wpPin,
      'spiPinDrv': <String, dynamic>{
        r'$1': instance.spiPinDrv.$1,
        r'$2': instance.spiPinDrv.$2,
        r'$3': instance.spiPinDrv.$3,
      },
      'chipId': _$ChipIdEnumMap[instance.chipId],
      'minChipRev': instance.minChipRev,
      'minChipRevFull': instance.minChipRevFull,
      'maxChipRevFull': instance.maxChipRevFull,
      'hashAppended': instance.hashAppended,
    };

const _$ImageSpiModeEnumMap = {
  ImageSpiMode.qio: 'qio',
  ImageSpiMode.qout: 'qout',
  ImageSpiMode.dio: 'dio',
  ImageSpiMode.dout: 'dout',
  ImageSpiMode.fastRead: 'fastRead',
  ImageSpiMode.slowRead: 'slowRead',
};

const _$ImageSpiFrequencyEnumMap = {
  ImageSpiFrequency.div1: 'div1',
  ImageSpiFrequency.div2: 'div2',
  ImageSpiFrequency.div3: 'div3',
  ImageSpiFrequency.div4: 'div4',
};

const _$ImageFlashSizeEnumMap = {
  ImageFlashSize.mb1: 'mb1',
  ImageFlashSize.mb2: 'mb2',
  ImageFlashSize.mb4: 'mb4',
  ImageFlashSize.mb8: 'mb8',
  ImageFlashSize.mb16: 'mb16',
  ImageFlashSize.mb32: 'mb32',
  ImageFlashSize.mb64: 'mb64',
  ImageFlashSize.mb128: 'mb128',
};

const _$ChipIdEnumMap = {
  ChipId.esp32: 'esp32',
  ChipId.esp32s2: 'esp32s2',
  ChipId.esp32c3: 'esp32c3',
  ChipId.esp32s3: 'esp32s3',
  ChipId.esp32c2: 'esp32c2',
  ChipId.esp32c6: 'esp32c6',
  ChipId.esp32h2: 'esp32h2',
  ChipId.esp32p4: 'esp32p4',
  ChipId.esp32c5: 'esp32c5',
};
