# ESP Web Toolkit

Dart/Flutter tooling for Espressif chips, primarily targeting Chrome's Web
Serial API (desktop Chrome/Edge today; Android Chrome as its USB serial
support rolls out). A single [pub workspace](https://dart.dev/tools/pub/workspaces):

| Package | What |
|---|---|
| [`packages/esp_defs`](packages/esp_defs) | Chip definitions and firmware image formats — `EspChip`, `ImageMetadata`, `AppDescription`, reset reasons — with no I/O. What an app needs to read firmware files. |
| [`packages/esptool`](packages/esptool) | The esptool serial protocol in pure Dart: ROM + flasher-stub loader over a transport-agnostic `EspTransport`. Re-exports `esp_defs`. Transports: Web Serial (`package:esptool/web.dart`), libserialport (example). |
| `packages/idftool` | Port of python idftool — partition tables, NVS, OTA, differential flashing, bundles — as a library and CLI. |
| `apps/idftool_web` | The ESP Web Toolkit: partitions, flashing and bundles, NVS and filesystems, monitor, inspect, and the one-click flasher at `/oneclick`. Published to [nebkat.github.io/esp-web-toolkit](https://nebkat.github.io/esp-web-toolkit/). |

Everything above the transport is free of `dart:io`, so the same code runs in
the browser, in Flutter on any platform, and in a CLI.

```sh
fvm dart pub get          # once, at the root
cd packages/esptool && dart test
```

## Depending on a package from another project

Each package can be pinned from git with a `path`, and is tagged as
`<package>-v<version>`:

```yaml
esp_defs:
  git:
    url: https://github.com/nebkat/esp-web-toolkit.git
    ref: esp_defs-v0.1.0
    path: packages/esp_defs
```

## License

The ESP Web Toolkit app (`apps/idftool_web`) is [AGPL-3.0-or-later](apps/idftool_web/LICENSE).
`packages/esptool` is a port of Espressif's esptool and carries its
[GPL-2.0-or-later](packages/esptool/LICENSE). The other packages are
[BSD-3-Clause](packages/esp_defs/LICENSE), the usual license for Dart and Flutter
packages; `esp_defs` in particular reads firmware images without any esptool code.
See [LICENSE.md](LICENSE.md).
