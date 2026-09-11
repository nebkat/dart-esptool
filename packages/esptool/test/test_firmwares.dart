import 'dart:io';

import 'package:esptool/esptool.dart';
import 'package:test/test.dart';

void main() {
  group('Firmware file tests', () {
    test('hello_world.bin', () {
      final image = ImageMetadata.fromBytes(
        File('test/hello_world.bin').readAsBytesSync(),
        appRequired: true,
      );
      print(image);
      expect(image.header.chipId, ChipId.esp32s3);
      expect(image.header.segmentCount, 5);
      expect(image.header.spiMode, ImageSpiMode.dio);
      expect(image.header.spiFrequency, ImageSpiFrequency.div1);
      expect(image.header.spiSize, ImageFlashSize.mb2);
      expect(image.header.hashAppended, true);

      expect(
        image.digest.map((i) => i.toRadixString(16).padLeft(2, "0")).join(''),
        '65a8b80507138ea1797e3e2f503fe514f0f896ba617b5808fa9294f9dcdb868c',
      );

      expect(image.appDescription!.projectName, 'hello_world');
      expect(image.appDescription!.version, 'v5.3.1-10-ga97660f327');
      expect(image.appDescription!.idfVersion, 'v5.3.1-10-ga97660f327');
      expect(image.appDescription!.time, '16:58:41');
      expect(image.appDescription!.date, 'Nov  3 2024');
      expect(image.appDescription!.dateTime, DateTime(2024, 11, 3, 16, 58, 41));
      expect(image.appDescription!.secureVersion, 0);
    });
  });
}
