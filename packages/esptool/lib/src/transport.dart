import 'dart:async';
import 'dart:typed_data';

/// Byte-level serial transport used by [EspLoader] to talk to an ESP chip's
/// ROM bootloader.
///
/// The package is deliberately transport-agnostic: implement this over
/// whatever serial API your platform provides — `dart_serial_port` /
/// `flutter_libserialport` on desktop, `usb_serial` on Android, the Web Serial
/// API in the browser, or a mock for testing.
///
/// Only [input] and [write] are mandatory. The modem-control methods
/// ([setDtr]/[setRts]) are needed for automatic entry into download mode via
/// [EspResets.classic]; transports that cannot toggle them can be driven with
/// [EspResets.none] and a manual boot-button reset. Override [flushInput] and
/// [setBaudRate] where the backend supports them.
abstract class EspTransport {
  /// Incoming bytes from the device, emitted as they arrive.
  ///
  /// May be single-subscription or broadcast; [EspLoader] subscribes once for
  /// the lifetime of the loader.
  Stream<List<int>> get input;

  /// Write [data] to the device. Should complete once the bytes have been
  /// handed to the OS (not necessarily transmitted).
  Future<void> write(Uint8List data);

  /// Set the DTR modem-control line, following pyserial's convention where
  /// `true` asserts the line. On the standard auto-reset circuit DTR drives the
  /// chip's `GPIO0` (boot-mode strapping pin).
  ///
  /// The default throws [UnsupportedError]; connect with [EspResets.none] if
  /// your transport cannot control it.
  Future<void> setDtr(bool value) => throw UnsupportedError('setDtr is not supported by this transport');

  /// Set the RTS modem-control line (`true` asserts). On the standard
  /// auto-reset circuit RTS drives the chip's `EN`/`CHIP_PU` (reset) pin.
  Future<void> setRts(bool value) => throw UnsupportedError('setRts is not supported by this transport');

  /// Change the host-side serial baud rate. Optional — only required to use
  /// [EspLoader.changeBaudRate].
  Future<void> setBaudRate(int baudRate) => throw UnsupportedError('setBaudRate is not supported by this transport');

  /// Discard any buffered input. Called before syncing so stale boot-log bytes
  /// don't get mistaken for a response. Default is a no-op.
  Future<void> flushInput() async {}
}

/// A reset strategy: drives [EspTransport]'s control lines to put the chip into
/// (or out of) the ROM download mode. See [EspResets].
typedef EspReset = Future<void> Function(EspTransport transport);

/// Built-in [EspReset] sequences, mirroring esptool's reset strategies.
abstract final class EspResets {
  /// The classic, portable DTR/RTS bootloader reset (sequential line writes).
  ///
  /// Drives `GPIO0` low while pulsing `EN`, then releases both, leaving the
  /// chip in download mode. Matches esptool's `ClassicReset` /
  /// `esp-pylib`'s `classic_bootloader_reset`.
  static EspReset classic({
    Duration enterBootDelay = const Duration(milliseconds: 100),
    Duration resetDelay = const Duration(milliseconds: 50),
  }) {
    return (transport) async {
      await transport.setDtr(false); // GPIO0 = HIGH
      await transport.setRts(true); //  EN = LOW, chip held in reset
      await Future<void>.delayed(enterBootDelay);
      await transport.setDtr(true); //  GPIO0 = LOW
      await transport.setRts(false); // EN = HIGH, chip released
      await Future<void>.delayed(resetDelay);
      await transport.setDtr(false); // GPIO0 = HIGH, done
    };
  }

  /// Reset sequence for chips using the internal USB-Serial/JTAG peripheral
  /// (native-USB ESP32-C3/S3/C6/H2/P4, i.e. ports that enumerate as
  /// `usbmodem`/`ttyACM`). These react to a different DTR/RTS pulse train than
  /// an external UART bridge. Matches esptool's `USBJTAGSerialReset`.
  static EspReset usbJtag({Duration settleDelay = const Duration(milliseconds: 100)}) {
    return (transport) async {
      await transport.setRts(false);
      await transport.setDtr(false); // idle
      await Future<void>.delayed(settleDelay);
      await transport.setDtr(true); //  set GPIO0
      await transport.setRts(false);
      await Future<void>.delayed(settleDelay);
      await transport.setRts(true); //  reset
      await transport.setDtr(false);
      await transport.setRts(true); //  RTS re-write so the DTR change propagates
      await Future<void>.delayed(settleDelay);
      await transport.setDtr(false);
      await transport.setRts(false); // chip out of reset
    };
  }

  /// No reset — assumes the chip is already in download mode (e.g. entered
  /// manually with the BOOT button, or via a pass-through device).
  static EspReset none = (transport) async {};

  /// Pulse `EN` (via RTS) to reboot the chip, e.g. to run the flashed app after
  /// programming. Matches esptool's `HardReset`.
  static EspReset hard({
    Duration holdDelay = const Duration(milliseconds: 100),
  }) {
    return (transport) async {
      await transport.setRts(true); //  EN = LOW
      await Future<void>.delayed(holdDelay);
      await transport.setRts(false); // EN = HIGH
    };
  }
}
