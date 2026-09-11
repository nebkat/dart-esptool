import 'dart:async';
import 'dart:typed_data';

import 'package:esptool/esptool.dart';
import 'package:test/test.dart';

/// A fake in-memory transport that lets a test push bytes to the loader's
/// input and capture what the loader writes.
class FakeTransport extends EspTransport {
  final _inputController = StreamController<List<int>>();
  final List<Uint8List> writes = [];

  @override
  Stream<List<int>> get input => _inputController.stream;

  @override
  Future<void> write(Uint8List data) async => writes.add(data);

  @override
  Future<void> setDtr(bool value) async {}

  @override
  Future<void> setRts(bool value) async {}

  /// Feed a full command response (direction=1) to the loader, SLIP-encoded.
  void feedResponse(EspCommand op, {int value = 0, List<int> payload = const []}) {
    final packet = Uint8List(8 + payload.length);
    final header = ByteData.sublistView(packet);
    header.setUint8(0, 0x01); // response
    header.setUint8(1, op.value);
    header.setUint16(2, payload.length, Endian.little);
    header.setUint32(4, value, Endian.little);
    packet.setRange(8, packet.length, Uint8List.fromList(payload));
    _inputController.add(slipEncode(packet));
  }

  Future<void> close() => _inputController.close();
}

void main() {
  group('SLIP', () {
    test('encodes with delimiters and escaping', () {
      final encoded = slipEncode(Uint8List.fromList([0x01, 0xC0, 0xDB, 0x02]));
      expect(encoded, [0xC0, 0x01, 0xDB, 0xDC, 0xDB, 0xDD, 0x02, 0xC0]);
    });

    test('decoder round-trips a frame through a reader', () async {
      final controller = StreamController<List<int>>();
      final reader = SlipReader(controller.stream);
      final original = Uint8List.fromList([0xC0, 0xDB, 0x00, 0xFF]);
      controller.add(slipEncode(original));
      expect(await reader.read(const Duration(seconds: 1)), original);
      await reader.dispose();
      await controller.close();
    });

    test('decoder skips noise before the start delimiter', () async {
      final controller = StreamController<List<int>>();
      final reader = SlipReader(controller.stream);
      controller.add([0x0A, 0x0B]); // boot-log noise
      controller.add(slipEncode(Uint8List.fromList([0x42])));
      expect(await reader.read(const Duration(seconds: 1)), [0x42]);
      await reader.dispose();
      await controller.close();
    });

    test('read times out when no frame arrives', () async {
      final controller = StreamController<List<int>>();
      final reader = SlipReader(controller.stream);
      expect(
        reader.read(const Duration(milliseconds: 10)),
        throwsA(isA<TimeoutException>()),
      );
      await reader.dispose();
      await controller.close();
    });
  });

  group('checksum', () {
    test('matches the ROM XOR definition', () {
      // 0xEF ^ 0x01 ^ 0x02 ^ 0x03
      expect(EspLoader.checksum(Uint8List.fromList([0x01, 0x02, 0x03])), 0xEF ^ 0x01 ^ 0x02 ^ 0x03);
      expect(EspLoader.checksum(Uint8List(0)), 0xEF);
    });
  });

  group('command protocol', () {
    test('readReg parses the response value and sends the address', () async {
      final transport = FakeTransport();
      final loader = EspLoader(transport);

      // Response: value = 0x00F01D83, empty payload + 2 status bytes (0,0).
      transport.feedResponse(EspCommand.readReg, value: 0x00F01D83, payload: [0x00, 0x00]);

      final value = await loader.readReg(0x40001000);
      expect(value, 0x00F01D83);

      // Verify the request that went out: SLIP frame wrapping READ_REG + addr.
      expect(transport.writes, hasLength(1));
      final sent = transport.writes.single;
      expect(sent.first, 0xC0);
      expect(sent.last, 0xC0);
      // Header inside the frame: dir=0, op=READ_REG.
      expect(sent[1], 0x00);
      expect(sent[2], EspCommand.readReg.value);

      await loader.dispose();
      await transport.close();
    });

    test('non-zero status raises EspCommandException', () async {
      final transport = FakeTransport();
      final loader = EspLoader(transport);
      transport.feedResponse(EspCommand.readReg, payload: [0x01, 0x05]); // fail, reason 5
      await expectLater(loader.readReg(0), throwsA(isA<EspCommandException>()));
      await loader.dispose();
      await transport.close();
    });
  });

  group('chip detection', () {
    test('matches ESP32 by magic register value', () async {
      final transport = FakeTransport();
      final loader = EspLoader(transport);
      transport.feedResponse(EspCommand.readReg, value: EspChip.esp32.magicValue!, payload: [0x00, 0x00]);
      expect(await loader.detectChip(), EspChip.esp32);
      expect(loader.chip, EspChip.esp32);
      await loader.dispose();
      await transport.close();
    });
  });
}
