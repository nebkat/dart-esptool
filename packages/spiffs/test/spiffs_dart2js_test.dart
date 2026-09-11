@TestOn('browser')
library;

// Reading and building must work when compiled to JavaScript (the web app),
// where integers are doubles and shifts are 32-bit. The fixtures are inlined
// because a browser test cannot read files.
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:spiffs/spiffs.dart';
import 'package:test/test.dart';

// test/fixtures/nested/image.bin.gz — built by the python idftool CLI.
const _nestedImage =
    'H4sICAAAAAAC/2ltYWdlLmJpbgDt119QVGUcxvGzyxKESTb+m5xIiTVMkUXQchsIRCZACXQESrEhdsWERBhBBglsgRQsTcYcBZNBRIgkQKQFzA0IQyT+mZmgkYOTAwGBgIqkyMY23HRB183Z7+fcnNvfed7zvu8j0UgEqUYqmGhMBMMj08gEU42poDcCSpleL9EIwujEu6kgCBLFzsjIGPuYuBhhalJxfRrJxEhjhrEt9EZJOpm/7J/8QxQxkVH/vQBk4spfash/YmgjjV9vMpn/O1JD/vGK7SHRMfaqsB1T5v+UYCaYi2cNmBjy//FtbWWgbV3CLyn9092Sh+TrmuQ1TaNHug7nD8/bttkrU2O9Maj517ZG83BPjySNdm2+59xD/qXJObdPPBvdVfzJ4ea+TpsX53hmpzUv8T2n7thbnTianftBpu4VH1fnms6ER08vUXlZtxaVFNuWqAtt9Gn3uzpt062j79YuzSps6StPPbB5RFqsP3nuysCfFzwqtNO/eNwdcr8hf0hW6fqo51LrcPE97f6srPMqr+N/fRY491izpZM8JS+oMcFryxvBf4S/d68+vGJ2fU76rojTd2dVOrvsOW12tj6xNf7NO1+VzjrVIlntoJx5SyrT5R1L6drrbuV6o3wgV71h/hpzR6HURJAIY37DvWsy3Np+f2FR1fWC+SUjzzeVLT96PGR2ut7t2of7OwO9iyquFvrpnM1m1MW+FpTzqpnigTbiTJvVvo12ZwNW1Va+/rWd43JtiPL65zOdLPJ+qt6/qmPTHOeGa4nKm7v8yqwGNl12l/Q1ugxeTD355U3/8oLrHcHfep8pXl8Ut1pnvSL8udvtg+2p3Q3xskvqbe/WXLZY2Ba7o8pnvMi3P9gqxXrBSrNvFH616oSBn20DLH3cNU9KLOZZ2sU5ChlRcsXSlopE2fKR8Q1HW7duTY5wDHYIyCzydV/2Vtr3qos3Dn7adqRgZMYyl4ThduXDhyW5233vVD8I2N0d1X5V3msmHDKZONDGGpSN4RfUSU9UgUmOOl3qoP8V7crFnaGC+uOzV0tPVMk105piu1aM23sqe50aBzrXJmU/XrEutWffqWm7PVrO93h4m/avPvjdR/V168PLXOqOFB3YaemwR/Nb1A82+4aCMoK6dLf+t+tfNvn/m0/u/ypFdJhqe9iO96c6BSzEtf8bzr2xyZGN8Qww/df9z5C/WrElNHTqS8Az4srfMPeYYWBjvQAAMEovy/gGAAAAAACInS39HwAAAAAA0ZPT/wEAAAAAEL2F9H8AAAAAAETvJfo/AAAAAACiZ0P/BwAAAABA9BbQ/wEAAAAAED1r+j8AAAAAAKJnT/8HAAAAAED0FPR/AAAAAABEz47+DwAAAACA6C2l/wMAAAAAIHqL6f8AAAAAAIjeEvo/AAAAAACit4j+DwAAAAAwEn8DHtm8NwAAAQA=';

// test/fixtures/nested/src/z/last.bin
const _lastBin =
    'yle1uFYnxXzVg+0NQILxJFDMJMDM+JTmkqbyGmhcSJmAIVlbzdvXywhqR0SBgLVLpkcXj1SxgqHhnA9z5q6Kks3r4CMeFkefiM0rTrJj3IW/ffifo2uZvClMPzzA4Hz6CStiSCHPra+uJ69jqyP/iPTm4CeQIXPvwi2dq87rtoeMXPYCrv+gstDu7LtEt7UNm/vnYfTJpvEEuD/66cbP8q7ztYmdnbliSJr5jlYXl80OMySDpVvLfEhkPl/oamDzx2q3FcehkHVtpO8UuDw9fqQHsMd9z3pG5KmxFKLOAUMwORPeAgS8pZeD5oVCHT/Ztu6jY1MfSggyALFP8upKmEDX4xwovtaoH6/2GcyzNJaaYRWQ/0DUe4ngVkmtt9KrT7w8BxDFdjdboTYHL/W1barXHYZZLLBVQcK4OqwsMjS1YTnWkxMzCqXRv4lB3FoWPMnUfTnadU+zHe5ayEIB68s98MOHoKfaVLao1txfukmqrlGteEO8ITVqEeHY8NiH58l6BMZjaF3AyAol13Zuvkz+rU7tXx2DISA4B7QvT8JjfO7TJ1UOTEKA/a8KGg4seDIAmHAkLy3Ot30ENPb+U5bPZmaCbTJfMFWZrU5CMU2IwWLD2Y2L15So9hAxPXzy2Dn396+jbE7kv/VVeedw2NIk6gcAj8k5y2q7Y4H9YlaBMry8h/BU0LU4KuBlAGOEsNKxnL4kgAvMduY1/i5HOeozy+7gS4Gf+zVQh+mGogt5RM656URJBe1Djb1/x8VRarM9xZStjHIOMH6A3XDEI4bxW5hb5rze';

Uint8List _text(String s) => Uint8List.fromList(utf8.encode(s));

/// The tree behind the fixture, in the order the python CLI packs it.
final List<SpiffsSource> _nestedSources = [
  (path: 'root.txt', bytes: _text('root\n')),
  (path: 'a/top.txt', bytes: _text('top\n')),
  (path: 'z/last.bin', bytes: base64Decode(_lastBin)),
  (path: 'a/b/sibling.txt', bytes: _text('sibling\n')),
  (path: 'a/b/c/deep.txt', bytes: _text('deep\n')),
];

Uint8List _pattern(int length, int seed) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = (i * 7 + seed * 13 + (i >> 8)) & 0xFF;
  }
  return out;
}

void main() {
  final image = Uint8List.fromList(const GZipDecoder().decodeBytes(base64Decode(_nestedImage)));

  test('mounts a python-generated image under dart2js', () {
    expect(SpiffsVolume.detect(image), isTrue);
    final volume = SpiffsVolume.mount(image, strict: true);
    expect(volume.errors, isEmpty);
    expect(volume.entries.map((e) => e.path), ['a/b/c/deep.txt', 'a/b/sibling.txt', 'a/top.txt', 'root.txt', 'z/last.bin']);
    for (final source in _nestedSources) {
      expect(volume.read(source.path), source.bytes, reason: source.path);
    }
  });

  test('builds the same bytes as python under dart2js', () {
    expect(spiffsCreate(_nestedSources, 0x10000), image);
  });

  test('a file spanning several index pages round-trips under dart2js', () {
    final big = _pattern(40 * 1024, 3);
    final sources = [(path: 'big.bin', bytes: big), (path: 'empty', bytes: Uint8List(0)), (path: 'tail.txt', bytes: _text('end'))];
    final built = spiffsCreate(sources, 0x40000);
    expect(SpiffsVolume.detect(built), isTrue);
    final volume = SpiffsVolume.mount(built, strict: true);
    expect({for (final e in volume.entries) e.path: e.size}, {'big.bin': big.length, 'empty': 0, 'tail.txt': 3});
    expect(volume.read('big.bin'), big);
    expect(volume.read('empty'), isEmpty);
    expect(volume.read('tail.txt'), _text('end'));
    expect(() => spiffsCreate(sources, 0x1000), throwsA(isA<SpiffsException>()));
  });
}
