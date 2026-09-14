# ESP Web Toolkit

**[nebkat.github.io/esp-web-toolkit](https://nebkat.github.io/esp-web-toolkit/)**

Work on Espressif devices from the browser, over USB, with nothing to
install: read and edit partition tables, flash firmware, edit NVS values and
filesystem files in place, watch the serial monitor, and inspect firmware
files. It runs on Web Serial, so it needs Chrome, Edge or Opera on a desktop
computer.

## Pages

| Page | What it does |
|---|---|
| **Partitions** | The device's partition table as a grid and a map of the flash. Open a table file to view or plan one without a device. |
| **Flash** | Plan changes to the flash — a partition table, the bootloader, an app (factory or OTA), files for named partitions, erases, NVS value edits and filesystem file edits — then flash them in one go. Writes are differential: sectors already holding the same data are skipped. Save the plan as a bundle, or open one. |
| **Data** | Browse and edit NVS partitions (plain or HMAC-encrypted) and LittleFS, SPIFFS and FAT filesystems on the device or in image files. |
| **Monitor** | Serial monitor with ESP-IDF's log colouring and filtering. |
| **Inspect** | What is in a file: partition tables, whole-flash images, app and bootloader images, bundles, NVS images and filesystem images. |

## One-click flashing

[`/oneclick`](https://nebkat.github.io/esp-web-toolkit/oneclick) is a
stripped-down page for handing someone a firmware update: it shows what a
bundle will do, then Connect and Flash. Point it at a bundle with a link,

```
https://nebkat.github.io/esp-web-toolkit/oneclick?bundle=https://example.com/firmware/device-v1.2.0.zip
```

or open a bundle file on the page. The bundle's host must allow CORS. The
Flash page's **Preview** shows how a plan will look there before you save it.

## Bundles

A bundle is a ZIP whose filenames say what to flash, in this order:

| File | Operation |
|---|---|
| `partition_table.csv` or `.bin` | Replace the partition table (written first; the other names resolve against it) |
| `bootloader.bin` | Write at the chip's bootloader offset |
| `@factory.bin` | Flash the factory partition (or `ota_0`) and clear the OTA selection so it boots |
| `@ota.bin` | Write the next OTA slot and switch boot to it |
| `<name>.bin` | Write the partition called `name` |

Anything else is ignored, except an optional `manifest.json` for what a
file cannot say: a name and description shown as the one-click page's
heading, the chip the bundle is for, and `ops` run after the files —
`erase` a partition, `set-nvs` values, `edit-fs` to put or delete single
files in a filesystem partition, `set-boot`, `clear-boot`. The Flash page's
**Save as bundle** writes all of this for you.

## Building

A Flutter web app in a [pub workspace](https://dart.dev/tools/pub/workspaces)
of pure-Dart packages:

```sh
dart pub get                                   # once, at the root
cd apps/idftool_web && flutter build web       # or: flutter run -d chrome
```

Pushes to `main` publish the app to GitHub Pages.

## Packages

Everything above the serial transport is free of `dart:io`, so the same code
runs in the browser, in Flutter on any platform, and in a CLI.

| Package | What |
|---|---|
| [`esp_defs`](packages/esp_defs) | Chip definitions and firmware image formats — `EspChip`, `ImageMetadata`, `AppDescription`, reset reasons. No I/O; what an app needs to read firmware files. |
| [`esptool`](packages/esptool) | The esptool serial protocol: ROM and flasher-stub loader over a transport-agnostic `EspTransport`, with Web Serial and libserialport transports. |
| [`idftool`](packages/idftool) | Port of python idftool: partition tables, NVS, OTA data, differential flashing, bundles — as a library and a CLI. |
| [`esp_monitor`](packages/esp_monitor) | The serial monitor's line handling, colouring and filters. |
| [`littlefs`](packages/littlefs), [`spiffs`](packages/spiffs), [`fatfs`](packages/fatfs) | Pure-Dart readers (and, for SPIFFS and FAT, builders) for the filesystem images ESP-IDF uses. |

Pin a package from another project with a git `path`; each is tagged as
`<package>-v<version>`:

```yaml
esp_defs:
  git:
    url: https://github.com/nebkat/esp-web-toolkit.git
    ref: esp_defs-v0.1.0
    path: packages/esp_defs
```

## License

The app is [AGPL-3.0-or-later](apps/idftool_web/LICENSE). `esptool` is a
port of Espressif's esptool and carries its
[GPL-2.0-or-later](packages/esptool/LICENSE). The other packages are
[BSD-3-Clause](packages/esp_defs/LICENSE). See [LICENSE.md](LICENSE.md).
