// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_description.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Map<String, dynamic> _$AppDescriptionToJson(AppDescription instance) {
  final val = <String, dynamic>{
    'projectName': instance.projectName,
    'version': instance.version,
    'idfVersion': instance.idfVersion,
    'secureVersion': instance.secureVersion,
  };

  void writeNotNull(String key, dynamic value) {
    if (value != null) {
      val[key] = value;
    }
  }

  writeNotNull('compiled', instance.compiled);
  return val;
}
