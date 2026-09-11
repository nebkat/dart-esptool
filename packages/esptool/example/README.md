# esptool example — `libserialport` transport

A runnable CLI that drives [`EspLoader`] over a real serial port using
[`package:libserialport`](https://pub.dev/packages/libserialport), demonstrating
how to implement the `EspTransport` interface for a concrete backend.

- `libserialport_transport.dart` — a reusable `EspTransport` over libserialport
  (byte I/O, DTR/RTS reset lines, baud changes, input flush).
- `esptool_flex.dart` — the CLI that connects, detects the chip, and does
  ROM-level flash read / write / erase.

## Prerequisites

`package:libserialport` binds the native **libserialport** C library, which must
be installed and loadable at runtime:

- macOS: `brew install libserialport`
- Debian/Ubuntu: `sudo apt install libserialport0`
- Windows: ship `libserialport.dll` next to the executable

On Apple Silicon the Homebrew dylib lives in `/opt/homebrew/lib`, which isn't on
the default loader path (and macOS strips `DYLD_*` from the signed `dart`
binary). The example handles this automatically — `ensureLibserialportResolved()`
finds the library in the usual install dirs and points libserialport at it via
its `LIBSERIALPORT_PATH` override before anything loads it. No manual setup
needed as long as the library is installed.

## Usage

```sh
# List available serial ports
dart run example/esptool_flex.dart

# Chip info: model, MAC, flash JEDEC id + size, bootloader header dump
dart run example/esptool_flex.dart /dev/cu.usbserial-0001

# Read 64 KiB of flash starting at 0x0 into a file
dart run example/esptool_flex.dart /dev/cu.usbserial-0001 read 0x0 0x10000 dump.bin

# Write an image to the app partition and verify with an on-device MD5
dart run example/esptool_flex.dart /dev/cu.usbserial-0001 write 0x10000 app.bin

# Erase a region
dart run example/esptool_flex.dart /dev/cu.usbserial-0001 erase 0x9000 0x6000
```

Addresses and lengths accept `0x`-prefixed hex or decimal.

## Native-USB boards on macOS (`--no-reset`)

Chips with native USB (ESP32-S3/C3/C6/…, ports named `cu.usbmodem*` / `ttyACM*`)
reset by toggling DTR/RTS, which tears down and re-enumerates the USB device.
Real esptool reopens the port across that event; this example does not, and on
macOS the in-flight libserialport `ioctl` can hang. So auto-reset isn't reliable
here — put the board in download mode another way and pass `--no-reset` (which
skips all line control):

- **Buttons:** hold **BOOT**, tap **RESET/EN**, release **BOOT**, then run with
  `--no-reset`.
- **Via esptool** (leaves the ROM in download mode for us to pick up):

  ```sh
  esptool --port <port> --before default-reset --after no-reset --no-stub flash-id
  dart run example/esptool_flex.dart <port> --no-reset          # then, promptly
  ```

The tool hard-resets the chip back into its app when it finishes.

> This is the **ROM-only** loader (no flasher stub): writes are uncompressed and
> reads use the slow 64-byte-per-call ROM path, so large transfers are slow but
> require no stub upload.

[`EspLoader`]: ../lib/src/esp_loader.dart
