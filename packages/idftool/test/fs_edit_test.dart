import 'dart:convert';
import 'dart:typed_data';

import 'package:idftool/idftool.dart';
import 'package:test/test.dart';

void main() {
  Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));
  const size = 0x10000;

  for (final type in [FsType.spiffs, FsType.fatfs]) {
    test('${type.label}: put, replace and delete files, starting from erased', () {
      final erased = Uint8List(size)..fillRange(0, size, 0xFF);
      final first = editFsImage(erased, type: type, size: size, put: {'a.txt': bytes('one'), '/dir/b.txt': bytes('two')});
      expect(first.put, 2);
      expect(first.deleted, 0);
      expect(first.image.length, size);
      var v = FsVolume.mount(first.image, type: type);
      expect(v.read('a.txt'), bytes('one'));
      expect(v.read('dir/b.txt'), bytes('two'));

      final second = editFsImage(first.image, type: type, size: size, put: {'a.txt': bytes('uno')}, delete: ['dir/b.txt', 'nope.txt']);
      expect(second.deleted, 1);
      expect(second.missing, ['nope.txt']);
      v = FsVolume.mount(second.image, type: type);
      expect(v.read('a.txt'), bytes('uno'));
      expect(v.entries.where((e) => !e.isDir).map((e) => e.path), ['a.txt']);
    });
  }

  test('littlefs cannot be rebuilt', () {
    expect(() => editFsImage(null, type: FsType.littlefs, size: size, put: {'a': Uint8List(1)}), throwsA(isA<IdfToolException>()));
  });
}
