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
  older `steps` form (a recipe naming its files, nothing derived from
  filenames) keeps loading; a bundle with no extras has no manifest.
  Whole-flash images are deliberately not a bundle concept. The Dart port
  (`FlashBundle.fromZip`, the one-click page) does all of this; single files
  are `edit-fs` (`partition`, `put` map of path → bundle file, `delete`
  list), which reads the partition, rebuilds the image and writes it back
  (SPIFFS and FAT; LittleFS images cannot be built yet). When the manifest
  names no chip, the chip the app or bootloader image was built for is
  checked instead.
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

## NVS

- **Encrypted NVS (HMAC key protection).** (nebkat/idftool#9) `create-nvs`, `write-nvs`,
  `read-nvs`, `extract-nvs`, `print-nvs`, `get-nvs` and `set-nvs` take
  `--hmac-key` (64 hex digits or a 32-byte file) and decrypt/encrypt the
  entries around the usual plaintext code. Upstream idftool has no NVS
  encryption; `nvs_partition_gen` can only generate or decrypt whole images.
  An image with written entries but no entry passing its CRC is reported
  once as "looks encrypted" rather than one CRC error per entry.
- **Erased entries are not purged.** Newer ESP-IDF firmware overwrites the
  entries of an erased item with zeros (`Page::purgeEntryRange`, raw, not
  encrypted); both idftools only flip the bitmap. Harmless — the firmware
  ignores erased entries either way — but it is a byte difference against a
  firmware-edited image.
- **`nvs_partition_gen decrypt` tweak.** It numbers entries for the XTS tweak
  by counting the non-0xFF entries it has decrypted on a page, where the
  firmware uses the entry's position. They agree as long as no all-0xFF
  entry sits before a written one, which append-only pages never have, so
  this is latent rather than a bug in practice. The Dart port goes by
  position and the bitmap.

## Behaviour

- **Differential writes by default** for every partition write, with
  `--diff auto|always|skip-flashed|never`. Upstream writes in full.
- **Change baud rate after the stub** is implemented in the loader but not
  yet used by either CLI; when it is, upstream should match the default.
