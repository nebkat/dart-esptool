enum ResetReason {
  unknown(0x00),
  powerOn(0x01),
  external(0x02),
  software(0x03),
  panic(0x04),
  interruptWatchdog(0x05),
  taskWatchdog(0x06),
  otherWatchdog(0x07),
  deepSleep(0x08),
  brownout(0x09),
  sdio(0x0A),
  usb(0x0B),
  jtag(0x0C),
  efuse(0x0D),
  powerGlitch(0x0E),
  cpuLockup(0x0F);

  const ResetReason(this.code);

  final int code;

  factory ResetReason.fromCode(int code) => ResetReason.values.firstWhere(
        (reason) => reason.code == code,
        orElse: () => ResetReason.unknown,
      );
}
