# ESP Web Toolkit

**[nebkat.github.io/esp-web-toolkit](https://nebkat.github.io/esp-web-toolkit/)**

Work on Espressif devices from the browser, over USB, with nothing to
install. Needs Chrome, Edge or Opera on a desktop computer.

- **Partitions** — view the device's partition table and flash map.
- **Flash** — plan and flash a partition table, bootloader, app (factory or OTA), partition images, erases, NVS values and filesystem files in one go. Only changed sectors are written.
- **Data** — browse and edit NVS (including encrypted) and LittleFS, SPIFFS and FAT filesystems.
- **Monitor** — serial monitor with ESP-IDF log colouring and filtering.
- **Inspect** — see what is inside a firmware, partition table, NVS, filesystem or bundle file.
- **One-click flashing** — [`/oneclick?bundle=<url>`](https://nebkat.github.io/esp-web-toolkit/oneclick) shows what a bundle will do, then Connect and Flash. Save one from the Flash page.

## License

The app is [AGPL-3.0-or-later](apps/idftool_web/LICENSE); the packages under
`packages/` have their own licenses, see [LICENSE.md](LICENSE.md).
