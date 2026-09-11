# ESP tools

Dart/Flutter tooling for Espressif chips, primarily targeting Chrome's Web
Serial API (desktop Chrome/Edge today; Android Chrome as its USB serial
support rolls out). A single [pub workspace](https://dart.dev/tools/pub/workspaces):

| Package | What |
|---|---|
| [`packages/esptool`](packages/esptool) | The esptool serial protocol in pure Dart: ROM + flasher-stub loader over a transport-agnostic `EspTransport`, plus ESP image / app-descriptor parsing. Transports: Web Serial (`package:esptool/web.dart`), libserialport (example). |
| `packages/idftool` | Port of python idftool — partition tables, NVS, OTA, differential flashing, bundles — as a library and CLI. |
| `apps/` | Flutter web apps built on the above. |

Everything above the transport is free of `dart:io`, so the same code runs in
the browser, in Flutter on any platform, and in a CLI.

```sh
fvm dart pub get          # once, at the root
cd packages/esptool && dart test
```
