# Licenses

This repository holds several packages under different licenses; each
directory carries its own `LICENSE` file.

| Directory | License |
|---|---|
| `apps/idftool_web` (the ESP Web Toolkit app) | [GNU AGPL-3.0-or-later](apps/idftool_web/LICENSE) |
| `packages/esptool` (a port of Espressif's esptool, itself GPL-2.0-or-later) | [GPL-2.0-or-later](packages/esptool/LICENSE) |
| `packages/esp_defs`, `packages/esptool_libserialport`, `packages/idftool`, `packages/esp_monitor`, `packages/littlefs`, `packages/spiffs`, `packages/fatfs` | [BSD-3-Clause](packages/esp_defs/LICENSE) |

The flasher-stub binaries embedded in `packages/esptool` come from
[espressif/esp-flasher-stub](https://github.com/espressif/esp-flasher-stub)
(Apache-2.0 / MIT).

`esp_defs` reads firmware images and names chips without any of esptool's
code, so it can be used on its own under BSD. `idftool`'s device layer and
`esptool_libserialport` depend on `esptool`, so a program built with them
is bound by the GPL; `idftool`'s partition-table, NVS and filesystem code
does not touch `esptool`.
