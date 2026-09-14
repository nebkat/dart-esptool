# esp_defs

Espressif chip definitions and firmware image formats in pure Dart, with no
I/O: the chip table (`EspChip`), the ESP image header and metadata
(`ImageMetadata`), the app descriptor (`AppDescription`) and reset reasons.

Depend on this to read firmware files or name chips; depend on `esptool`,
which re-exports it, to talk to a device.
