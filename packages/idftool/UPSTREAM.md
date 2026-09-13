# Changes to carry back to python idftool

The Dart port started as a straight port of the python idftool. Where the
port has grown beyond it, the upstream tool should follow so bundles and
behaviour stay interchangeable. Each entry should end up as an issue (or PR)
on https://github.com/nebkat/idftool; note the link here once filed.

## Bundle format

- **Bootloader in bundles.** (nebkat/idftool#6) `bootloader.bin` in a bundle is written at the
  chip's bootloader offset (a virtual partition, like `partition_table`).
  `dump-bundle` includes it. Python idftool only handles named partitions.
- **Role-based files: `@factory.bin` and `@ota.bin`.** (nebkat/idftool#7) Rather than naming a
  partition, these mean "factory-flash this app" (factory partition or
  `ota_0`, then clear otadata) and "OTA this app" (next slot, then switch
  boot). Fixed order: table, bootloader, `$factory`/`$ota`, named
  partitions. Both `@` files in one bundle, or a `@` file alongside a named
  write to the partition it would pick, is an error. `@` is reserved as a
  partition-name prefix so the role files can never collide.
- **`manifest.json` as optional extras.** (nebkat/idftool#8) `name`, `description`, `chip` and
  an `ops` list for what a file cannot express: set/delete NVS keys in an
  existing partition, put/delete a file in a filesystem partition, erase a
  partition, set/clear the boot slot. Ops run after the file operations. The
  current `steps` form (one-click bundles) keeps loading; a bundle with no
  extras has no manifest. Whole-flash images are deliberately not a bundle
  concept.
- **Plain bundles addressed by name need a matching table.** Tools should
  say whether a bundle carries its own table or relies on the device's.

- **CLI `write-bundle` / `dump-bundle`** in the Dart port still use the
  plain name-based reader in `device.dart`; they should move to
  `readBundle`/`encodeBundle` in `bundle.dart` so the CLI, the web app and
  python idftool agree.

## Device operations

- **`print-image` / `print-bundle` / `app-info` bootloader reporting.** The
  web Inspect tool reports the bootloader image found at 0x0 or 0x1000 and
  which chip it targets; upstream prints only the table and apps.
- **Filesystem partitions.** LittleFS, SPIFFS and FAT (with wear levelling)
  are readable, extractable and (FAT/SPIFFS) buildable in the Dart port;
  python idftool has no filesystem commands.

## Behaviour

- **Differential writes by default** for every partition write, with
  `--diff auto|always|skip-flashed|never`. Upstream writes in full.
- **Change baud rate after the stub** is implemented in the loader but not
  yet used by either CLI; when it is, upstream should match the default.
