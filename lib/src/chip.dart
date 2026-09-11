/// Register layout of an ESP chip's SPI0/SPI1 flash controller, used to issue
/// arbitrary SPI flash commands ("USR_COMMAND") from the ROM bootloader.
///
/// Values are chip-specific; see the per-chip `targets/*.py` files in esptool.
class SpiRegisters {
  const SpiRegisters({
    required this.regBase,
    required this.usrOffset,
    required this.usr1Offset,
    required this.usr2Offset,
    required this.mosiDlenOffset,
    required this.misoDlenOffset,
    required this.w0Offset,
  });

  /// `SPI_REG_BASE`
  final int regBase;

  /// `SPI_USR_OFFS`
  final int usrOffset;

  /// `SPI_USR1_OFFS`
  final int usr1Offset;

  /// `SPI_USR2_OFFS`
  final int usr2Offset;

  /// `SPI_MOSI_DLEN_OFFS`
  final int mosiDlenOffset;

  /// `SPI_MISO_DLEN_OFFS`
  final int misoDlenOffset;

  /// `SPI_W0_OFFS`
  final int w0Offset;
}

/// A supported ESP chip target and the constants [EspLoader] needs to talk to
/// its ROM bootloader.
///
/// The [imageChipId] matches `esp_chip_id_t` (see `ChipId` in
/// `image_metadata.dart`). [magicValue] is the value read from
/// [EspLoader.chipDetectMagicRegAddr] for the older chips that support that
/// detection path; newer chips are `null` here and identified via
/// `GET_SECURITY_INFO` instead.
///
/// @see [https://github.com/espressif/esptool/tree/master/esptool/targets]
enum EspChip {
  esp32(
    name: 'ESP32',
    imageChipId: 0x00,
    magicValue: 0x00F01D83,
    bootloaderFlashOffset: 0x1000,
    // ESP32 (and ESP8266) ROM don't accept the extended FLASH_BEGIN parameter.
    supportsExtendedFlashParams: false,
    macEfuseReg: 0x3FF5A004,
    spi: SpiRegisters(
      regBase: 0x3FF42000,
      usrOffset: 0x1C,
      usr1Offset: 0x20,
      usr2Offset: 0x24,
      mosiDlenOffset: 0x28,
      misoDlenOffset: 0x2C,
      w0Offset: 0x80,
    ),
  ),
  esp32s2(
    name: 'ESP32-S2',
    imageChipId: 0x02,
    magicValue: 0x000007C6,
    bootloaderFlashOffset: 0x1000,
    macEfuseReg: 0x3F41A044,
    spi: SpiRegisters(
      regBase: 0x3F402000,
      usrOffset: 0x18,
      usr1Offset: 0x1C,
      usr2Offset: 0x20,
      mosiDlenOffset: 0x24,
      misoDlenOffset: 0x28,
      w0Offset: 0x58,
    ),
  ),
  esp32s3(
    name: 'ESP32-S3',
    imageChipId: 0x09,
    macEfuseReg: 0x60007044,
    spi: SpiRegisters(
      regBase: 0x60002000,
      usrOffset: 0x18,
      usr1Offset: 0x1C,
      usr2Offset: 0x20,
      mosiDlenOffset: 0x24,
      misoDlenOffset: 0x28,
      w0Offset: 0x58,
    ),
  ),
  esp32c3(
    name: 'ESP32-C3',
    imageChipId: 0x05,
    macEfuseReg: 0x60008844,
    spi: SpiRegisters(
      regBase: 0x60002000,
      usrOffset: 0x18,
      usr1Offset: 0x1C,
      usr2Offset: 0x20,
      mosiDlenOffset: 0x24,
      misoDlenOffset: 0x28,
      w0Offset: 0x58,
    ),
  ),
  esp32c2(
    name: 'ESP32-C2',
    imageChipId: 0x0C,
    macEfuseReg: 0x60008840,
    spi: SpiRegisters(
      regBase: 0x60002000,
      usrOffset: 0x18,
      usr1Offset: 0x1C,
      usr2Offset: 0x20,
      mosiDlenOffset: 0x24,
      misoDlenOffset: 0x28,
      w0Offset: 0x58,
    ),
  ),
  esp32c6(
    name: 'ESP32-C6',
    imageChipId: 0x0D,
    macEfuseReg: 0x600B0844,
    spi: SpiRegisters(
      regBase: 0x60003000,
      usrOffset: 0x18,
      usr1Offset: 0x1C,
      usr2Offset: 0x20,
      mosiDlenOffset: 0x24,
      misoDlenOffset: 0x28,
      w0Offset: 0x58,
    ),
  ),
  esp32h2(
    name: 'ESP32-H2',
    imageChipId: 0x10,
  ),
  esp32p4(
    name: 'ESP32-P4',
    imageChipId: 0x12,
    macEfuseReg: 0x5012D044,
    spi: SpiRegisters(
      regBase: 0x5008D000,
      usrOffset: 0x18,
      usr1Offset: 0x1C,
      usr2Offset: 0x20,
      mosiDlenOffset: 0x24,
      misoDlenOffset: 0x28,
      w0Offset: 0x58,
    ),
  );

  const EspChip({
    required this.name,
    required this.imageChipId,
    this.magicValue,
    this.supportsExtendedFlashParams = true,
    this.bootloaderFlashOffset = 0x0,
    this.macEfuseReg,
    this.spi,
  });

  /// Human-readable chip name, e.g. `ESP32-S3`.
  final String name;

  /// `esp_chip_id_t` / `IMAGE_CHIP_ID`.
  final int imageChipId;

  /// Value read from [EspLoader.chipDetectMagicRegAddr] on chips that support
  /// magic-register detection, or `null` for chips detected via security info.
  final int? magicValue;

  /// Whether `FLASH_BEGIN`/`FLASH_DEFL_BEGIN` accept the trailing
  /// encrypted-write word. False for the original ESP32 (and ESP8266) ROM.
  final bool supportsExtendedFlashParams;

  /// Flash offset of the second-stage bootloader image (`BOOTLOADER_FLASH_OFFSET`):
  /// `0x1000` on ESP32/ESP32-S2, `0x0` on later chips.
  final int bootloaderFlashOffset;

  /// Base-0 read address of the BASE_MAC eFuse words, or `null` if unknown.
  final int? macEfuseReg;

  /// SPI flash controller register layout, or `null` if raw SPI flash commands
  /// (flash id, chip erase) aren't supported for this chip yet.
  final SpiRegisters? spi;
}
