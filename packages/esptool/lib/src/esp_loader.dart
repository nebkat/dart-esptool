import 'dart:async';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';

import 'chip.dart';
import 'slip.dart';
import 'stub_flasher.dart';
import 'transport.dart';

/// ESP bootloader command opcodes (`ESP_CMDS` in esptool). Opcodes from `0xD0`
/// are only understood by the flasher stub (see [EspLoader.runStub]).
enum EspCommand {
  flashBegin(0x02),
  flashData(0x03),
  flashEnd(0x04),
  memBegin(0x05),
  memEnd(0x06),
  memData(0x07),
  sync(0x08),
  writeReg(0x09),
  readReg(0x0A),
  spiSetParams(0x0B),
  spiAttach(0x0D),
  readFlashSlow(0x0E), // ROM only, 64 bytes per call
  changeBaudrate(0x0F),
  flashDeflBegin(0x10),
  flashDeflData(0x11),
  flashDeflEnd(0x12),
  spiFlashMd5(0x13),
  getSecurityInfo(0x14),

  // Stub-only commands.
  eraseFlash(0xD0),
  eraseRegion(0xD1),
  readFlash(0xD2),
  runUserCode(0xD3);

  const EspCommand(this.value);
  final int value;
}

/// Base class for all errors raised by [EspLoader].
class EspException implements Exception {
  EspException(this.message, [this.cause]);
  final String message;
  final Object? cause;
  @override
  String toString() => 'EspException: $message${cause != null ? ' (caused by: $cause)' : ''}';
}

/// A malformed or unexpected response at the protocol level.
class EspProtocolException extends EspException {
  EspProtocolException(super.message, [super.cause]);
}

/// The chip could not be reset into, or synced with, the download mode.
class EspConnectException extends EspException {
  EspConnectException(super.message, [super.cause]);
}

/// A command completed but the ROM reported a non-zero status.
///
/// [status] holds the two status bytes: `status[0]` is the failure flag and
/// `status[1]` the ROM-specific reason code.
class EspCommandException extends EspException {
  EspCommandException(String operation, this.status)
      : super('Failed to $operation'
            ' (status 0x${status.isNotEmpty ? status[0].toRadixString(16).padLeft(2, '0') : '??'}, '
            'reason 0x${status.length > 1 ? status[1].toRadixString(16).padLeft(2, '0') : '??'})');
  final Uint8List status;
}

/// The ROM reported that a command opcode is not supported.
class EspUnsupportedCommandException extends EspException {
  EspUnsupportedCommandException(this.command)
      : super('Command 0x${command.toRadixString(16).padLeft(2, '0')} '
            'is not supported by the ROM bootloader');
  final int command;
}

/// Talks to an ESP chip's bootloader over an [EspTransport], implementing the
/// core of Espressif's esptool: SLIP framing, the command/response protocol,
/// connection/sync, chip detection, flash read/write/erase, and uploading the
/// flasher stub.
///
/// After [connect] the loader talks to the ROM, which can only write
/// uncompressed and (on the original ESP32) read 64 bytes at a time. Call
/// [runStub] to upload the flasher stub; the same instance then transparently
/// switches to the stub's faster protocol ([isStub]).
///
/// @see [https://docs.espressif.com/projects/esptool/en/latest/esp32/advanced-topics/serial-protocol.html]
class EspLoader {
  /// [usbOtg] should be `true` when the chip is connected through its USB-OTG
  /// peripheral (the host sees Espressif VID `0x303A` with the chip's
  /// [EspChip.imageChipId] as PID) — the stub must then use smaller blocks.
  /// [baudRate] is the transport's current rate, needed by [changeBaudRate].
  EspLoader(this.transport, {this.usbOtg = false, int baudRate = 115200})
      : _reader = SlipReader(transport.input),
        _baudRate = baudRate;

  final EspTransport transport;
  final SlipReader _reader;
  final bool usbOtg;
  int _baudRate;
  bool _isStub = false;
  bool _syncStubDetected = false;

  /// Whether the flasher stub is running (see [runStub]).
  bool get isStub => _isStub;

  /// Bytes per `FLASH_DATA`/`FLASH_DEFL_DATA` block: `0x400` on the ROM,
  /// `0x4000` on the stub (`0x800` over USB-OTG).
  int get flashWriteSize => _isStub ? (usbOtg ? usbOtgBlockSize : stubFlashWriteSize) : romFlashWriteSize;

  /// Bytes per `MEM_DATA` block when loading to RAM.
  int get ramBlockSize => usbOtg ? usbOtgBlockSize : romRamBlockSize;

  /// Default per-command response timeout (`DEFAULT_TIMEOUT`).
  static const Duration defaultTimeout = Duration(seconds: 3);

  /// Timeout used while syncing (`SYNC_TIMEOUT`).
  static const Duration syncTimeout = Duration(milliseconds: 100);

  /// `ESP_ROM_CHECKSUM_INITIAL` — initial state of the ROM checksum.
  static const int checksumMagic = 0xEF;

  /// `FLASH_WRITE_SIZE` — bytes per `FLASH_DATA` block on the ROM loader.
  static const int romFlashWriteSize = 0x400;

  /// `StubMixin.FLASH_WRITE_SIZE` — bytes per flash block on the stub.
  static const int stubFlashWriteSize = 0x4000;

  /// `USB_RAM_BLOCK` — block size (RAM and flash) when connected over USB-OTG.
  static const int usbOtgBlockSize = 0x800;

  /// `ESP_RAM_BLOCK` — bytes per `MEM_DATA` block.
  static const int romRamBlockSize = 0x1800;

  /// `MEM_END_ROM_TIMEOUT` — the ROM may reset the UART before it finishes
  /// replying to `MEM_END`, so the reply is only waited for briefly.
  static const Duration memEndRomTimeout = Duration(milliseconds: 200);

  /// `CHIP_ERASE_TIMEOUT`.
  static const Duration chipEraseTimeout = Duration(seconds: 120);

  /// `FLASH_SECTOR_SIZE` — minimum flash erase unit.
  static const int flashSectorSize = 0x1000;

  /// Register that reads back a distinct magic value per chip model.
  static const int chipDetectMagicRegAddr = 0x40001000;

  /// Per-megabyte erase timeout (`ERASE_REGION_TIMEOUT_PER_MB`).
  static const Duration eraseTimeoutPerMb = Duration(seconds: 30);

  /// Per-megabyte MD5 timeout (`MD5_TIMEOUT_PER_MB`).
  static const Duration md5TimeoutPerMb = Duration(seconds: 8);

  /// Per-megabyte timeout for a stub block write, which erases as it goes
  /// (`ERASE_WRITE_TIMEOUT_PER_MB`).
  static const Duration eraseWriteTimeoutPerMb = Duration(seconds: 40);

  static const int _romInvalidRecvMsg = 0x05;
  static const int _statusBytesLength = 2;

  EspChip? _chip;

  /// The chip identified by [connect]/[detectChip], or `null` if not detected.
  EspChip? get chip => _chip;

  // --------------------------------------------------------------------------
  // Connection
  // --------------------------------------------------------------------------

  /// Reset the chip into download mode, sync with the ROM bootloader, and
  /// detect the chip model.
  ///
  /// [reset] defaults to [EspResets.classic]; pass [EspResets.none] if the chip
  /// is already in download mode or the transport can't toggle DTR/RTS.
  Future<EspChip> connect({
    EspReset? reset,
    int attempts = 7,
  }) async {
    reset ??= EspResets.classic();
    _isStub = false;
    Object? lastError;
    for (var attempt = 0; attempt < attempts; attempt++) {
      try {
        await reset(transport);
      } on UnsupportedError {
        // Transport can't drive the reset lines; assume already in download
        // mode and fall through to syncing.
      }
      await transport.flushInput();
      _reader.flush();

      for (var i = 0; i < 5; i++) {
        try {
          await sync();
          return await detectChip();
        } catch (e) {
          lastError = e;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    }
    throw EspConnectException('Failed to connect to an ESP chip after $attempts attempts', lastError);
  }

  /// Perform the SYNC handshake with the ROM bootloader.
  Future<void> sync() async {
    final syncPayload = Uint8List.fromList(
      [0x07, 0x07, 0x12, 0x20, ...List<int>.filled(32, 0x55)],
    );
    final (value, _) = await command(op: EspCommand.sync, data: syncPayload, timeout: syncTimeout);
    // ROMs reply with some non-zero value; the stub replies 0. All-zero
    // replies mean the reset didn't take and we're still talking to a stub.
    _syncStubDetected = value == 0;
    // The ROM queues up a handful of extra sync replies; drain them so they
    // don't get mistaken for the next command's response.
    for (var i = 0; i < 7; i++) {
      try {
        final (value, _) = await command(timeout: syncTimeout);
        _syncStubDetected &= value == 0;
      } catch (_) {
        break;
      }
    }
  }

  /// Identify the connected chip via its magic register, falling back to the
  /// `GET_SECURITY_INFO` chip id for newer chips.
  Future<EspChip> detectChip() async {
    final magic = await readReg(chipDetectMagicRegAddr);
    final byMagic = EspChip.values.firstWhereOrNull((c) => c.magicValue == magic);
    if (byMagic != null) return _chip = byMagic;

    try {
      final (_, info) = await checkCommand('get security info', op: EspCommand.getSecurityInfo, respDataLen: 20);
      final chipId = ByteData.sublistView(info).getUint32(12, Endian.little);
      final byId = EspChip.values.firstWhereOrNull((c) => c.imageChipId == chipId);
      if (byId != null) return _chip = byId;
      throw EspConnectException('Unknown chip (security-info id 0x${chipId.toRadixString(16)})');
    } on EspException {
      throw EspConnectException('Unknown chip (magic register 0x${magic.toRadixString(16)})');
    }
  }

  /// Reboot the chip out of the bootloader (pulses `EN` via RTS).
  Future<void> hardReset() => EspResets.hard()(transport);

  // --------------------------------------------------------------------------
  // RAM download / flasher stub
  // --------------------------------------------------------------------------

  /// Start a RAM download of [size] bytes to [offset], sent as [blocks] blocks
  /// of [blockSize] (`MEM_BEGIN`). Refuses ranges overlapping a running stub.
  Future<void> memBegin(int size, int blocks, int blockSize, int offset) async {
    final chip = _chip;
    if (_isStub && chip != null) {
      final stub = StubFlasherImage.forChip(chip);
      for (final (start, end) in stub?.residentRanges ?? const <(int, int)>[]) {
        if (offset < end && offset + size > start) {
          throw EspException('Stub flasher is resident at 0x${start.toRadixString(16)}-0x${end.toRadixString(16)}; '
              "can't load binary at overlapping range 0x${offset.toRadixString(16)}-0x${(offset + size).toRadixString(16)}");
        }
      }
    }
    await checkCommand('enter RAM download mode',
        op: EspCommand.memBegin, data: _bytes([_u32(size), _u32(blocks), _u32(blockSize), _u32(offset)]));
  }

  /// Send one block of a RAM download (`MEM_DATA`).
  Future<void> memBlock(Uint8List data, int seq) async {
    await checkCommand('write to target RAM',
        op: EspCommand.memData,
        data: _bytes([_u32(data.length), _u32(seq), _u32(0), _u32(0), data]),
        checksum: checksum(data));
  }

  /// Leave RAM download mode and, if [entrypoint] is non-zero, jump to it
  /// (`MEM_END`). The ROM may reset its UART before the reply is fully sent,
  /// so on the ROM a missing reply is tolerated.
  Future<void> memFinish([int entrypoint = 0]) async {
    final data = _bytes([_u32(entrypoint == 0 ? 1 : 0), _u32(entrypoint)]);
    try {
      await checkCommand('leave RAM download mode',
          op: EspCommand.memEnd, data: data, timeout: _isStub ? defaultTimeout : memEndRomTimeout);
    } on EspException {
      if (_isStub) rethrow;
    } on TimeoutException {
      if (_isStub) rethrow;
    }
  }

  /// Load [data] into RAM at [address] in [ramBlockSize] blocks.
  Future<void> loadRam(int address, Uint8List data) async {
    final blocks = (data.length + ramBlockSize - 1) ~/ ramBlockSize;
    await memBegin(data.length, blocks, ramBlockSize, address);
    for (var seq = 0; seq < blocks; seq++) {
      final start = seq * ramBlockSize;
      final end = start + ramBlockSize < data.length ? start + ramBlockSize : data.length;
      await memBlock(Uint8List.sublistView(data, start, end), seq);
    }
  }

  /// Upload and start the flasher stub for the connected chip, after which
  /// this loader speaks the stub protocol ([isStub]): compressed writes, fast
  /// [readFlash], [eraseRegion]/[eraseFlash], and larger blocks.
  ///
  /// Skipped if [sync] found a stub already running. Throws if no stub is
  /// vendored for the chip or the stub doesn't greet back.
  ///
  /// Not implemented: the ESP32-S3 secure-boot workaround (esptool hijacks a
  /// ROM function pointer there); such chips will fail to start the stub.
  Future<void> runStub() async {
    final chip = _chip;
    if (chip == null) throw EspException('Connect before running the stub');
    if (_syncStubDetected) {
      _isStub = true;
      return;
    }
    final stub = StubFlasherImage.forChip(chip);
    if (stub == null) throw EspException('No flasher stub available for ${chip.name}');

    await loadRam(stub.textStart, stub.textBytes);
    await loadRam(stub.dataStart, stub.dataBytes);
    await memFinish(stub.entry);

    final Uint8List greeting;
    try {
      greeting = await _reader.read(defaultTimeout);
    } on TimeoutException catch (e) {
      throw EspException('Failed to start stub flasher: no response', e);
    }
    if (String.fromCharCodes(greeting) != 'OHAI') {
      throw EspProtocolException('Failed to start stub flasher: unexpected response ${_hex(greeting)}');
    }
    _isStub = true;
  }

  // --------------------------------------------------------------------------
  // Command layer
  // --------------------------------------------------------------------------

  /// The ROM checksum: XOR of every byte in [data], seeded with
  /// [checksumMagic]. Used for the `FLASH_DATA`/`MEM_DATA` payloads.
  static int checksum(Uint8List data, [int state = checksumMagic]) {
    for (final b in data) {
      state ^= b;
    }
    return state & 0xFF;
  }

  /// Send a request packet and read its response.
  ///
  /// Returns `(value, data)` where `value` is the 32-bit word from the response
  /// header (used by e.g. `READ_REG`) and `data` is the trailing payload. Pass
  /// `op == null` to read the next response without sending anything (used to
  /// drain queued sync replies). Set [waitResponse] to `false` for
  /// fire-and-forget commands.
  Future<(int value, Uint8List data)> command({
    EspCommand? op,
    Uint8List? data,
    int checksum = 0,
    bool waitResponse = true,
    Duration timeout = defaultTimeout,
  }) async {
    data ??= Uint8List(0);
    if (op != null) {
      final packet = Uint8List(8 + data.length);
      final header = ByteData.sublistView(packet);
      header.setUint8(0, 0x00); // direction: request
      header.setUint8(1, op.value);
      header.setUint16(2, data.length, Endian.little);
      header.setUint32(4, checksum, Endian.little);
      packet.setRange(8, packet.length, data);
      await transport.write(slipEncode(packet));
    }
    if (!waitResponse) return (0, Uint8List(0));

    // Read responses until one matches the request (or, for op == null, the
    // first valid response). Some ROMs emit spurious frames in between.
    for (var retry = 0; retry < 100; retry++) {
      final frame = await _reader.read(timeout);
      if (frame.length < 8) continue;
      final header = ByteData.sublistView(frame);
      final direction = header.getUint8(0);
      final opRet = header.getUint8(1);
      final value = header.getUint32(4, Endian.little);
      if (direction != 1) continue; // not a response
      final payload = Uint8List.sublistView(frame, 8);
      if (op == null || opRet == op.value) return (value, payload);
      if (payload.length >= 2 && payload[0] != 0 && payload[1] == _romInvalidRecvMsg) {
        throw EspUnsupportedCommandException(op.value);
      }
    }
    throw EspProtocolException("Response doesn't match request");
  }

  /// Run [command] and validate the ROM status bytes, throwing
  /// [EspCommandException] on failure.
  ///
  /// Returns `(value, data)` where `data` is the first [respDataLen] bytes of
  /// the response payload (empty when [respDataLen] is 0).
  Future<(int value, Uint8List data)> checkCommand(
    String operation, {
    EspCommand? op,
    Uint8List? data,
    int checksum = 0,
    int respDataLen = 0,
    Duration timeout = defaultTimeout,
  }) async {
    final (value, payload) = await command(op: op, data: data, checksum: checksum, timeout: timeout);

    if (payload.length < respDataLen + _statusBytesLength) {
      if (payload.isNotEmpty && payload[0] != 0) {
        throw EspCommandException(operation, payload.sublist(0, payload.length.clamp(0, 2)));
      }
      throw EspProtocolException('Failed to $operation: only got ${payload.length}-byte status response');
    }

    final status = payload.sublist(respDataLen, respDataLen + _statusBytesLength);
    if (status[0] != 0) throw EspCommandException(operation, status);

    return (value, respDataLen > 0 ? payload.sublist(0, respDataLen) : Uint8List(0));
  }

  // --------------------------------------------------------------------------
  // Registers
  // --------------------------------------------------------------------------

  /// Read the 32-bit register / memory word at [address].
  Future<int> readReg(int address, {Duration timeout = defaultTimeout}) async {
    final (value, _) =
        await checkCommand('read register', op: EspCommand.readReg, data: _u32(address), timeout: timeout);
    return value;
  }

  /// Write [value] to the register / memory word at [address], optionally under
  /// [mask].
  Future<void> writeReg(int address, int value, {int mask = 0xFFFFFFFF, int delayUs = 0}) async {
    await checkCommand('write register',
        op: EspCommand.writeReg, data: _bytes([_u32(address), _u32(value), _u32(mask), _u32(delayUs)]));
  }

  // --------------------------------------------------------------------------
  // Flash write
  // --------------------------------------------------------------------------

  /// Enter flash download mode for a write of [size] bytes at [offset]. The ROM
  /// erases the target region up front (the stub erases as it writes). Returns
  /// the number of [flashWriteSize] blocks to send.
  Future<int> flashBegin(int size, int offset) async {
    final numBlocks = (size + flashWriteSize - 1) ~/ flashWriteSize;
    final params = <Uint8List>[
      _u32(size), // erase size (== size for ESP32-family ROMs)
      _u32(numBlocks),
      _u32(flashWriteSize),
      _u32(offset),
    ];
    if (_isStub || (_chip?.supportsExtendedFlashParams ?? true)) {
      params.add(_u32(0)); // encrypted-write flag
    }
    await checkCommand('enter flash download mode',
        op: EspCommand.flashBegin,
        data: _bytes(params),
        timeout: _isStub ? defaultTimeout : _timeoutPerMb(eraseTimeoutPerMb, size));
    return numBlocks;
  }

  /// Enter compressed flash download mode (`FLASH_DEFL_BEGIN`) for [size]
  /// uncompressed bytes at [offset], to be sent as [compressedSize] bytes of
  /// zlib data. Returns the number of [flashWriteSize] blocks to send.
  ///
  /// Supported by the stub and, of the ROMs, only the original ESP32.
  Future<int> flashDeflBegin(int size, int compressedSize, int offset) async {
    final numBlocks = (compressedSize + flashWriteSize - 1) ~/ flashWriteSize;
    final eraseBlocks = (size + flashWriteSize - 1) ~/ flashWriteSize;
    // The stub expects the byte count and erases internally; the ROM wants
    // the size rounded up to whole blocks and erases up front.
    final writeSize = _isStub ? size : eraseBlocks * flashWriteSize;
    final params = <Uint8List>[_u32(writeSize), _u32(numBlocks), _u32(flashWriteSize), _u32(offset)];
    if (_isStub || (_chip?.supportsExtendedFlashParams ?? true)) {
      params.add(_u32(0)); // encrypted-write flag
    }
    await checkCommand('enter compressed flash mode',
        op: EspCommand.flashDeflBegin,
        data: _bytes(params),
        timeout: _isStub ? defaultTimeout : _timeoutPerMb(eraseTimeoutPerMb, writeSize));
    return numBlocks;
  }

  /// Send one block of compressed flash data (`FLASH_DEFL_DATA`).
  Future<void> flashDeflBlock(Uint8List data, int seq, {Duration timeout = defaultTimeout}) async {
    final payload = _bytes([_u32(data.length), _u32(seq), _u32(0), _u32(0), data]);
    for (var attempt = 3; attempt > 0; attempt--) {
      try {
        await checkCommand('write compressed data to flash after seq $seq',
            op: EspCommand.flashDeflData, data: payload, checksum: checksum(data), timeout: timeout);
        return;
      } on EspException {
        if (attempt == 1) rethrow;
      }
    }
  }

  /// Leave compressed flash mode (`FLASH_DEFL_END`), optionally rebooting.
  /// On the ROM this command exits the bootloader, so without [reboot] it is
  /// skipped there (the stub stays resident either way).
  Future<void> flashDeflFinish({bool reboot = false}) async {
    if (!reboot && !_isStub) return;
    await checkCommand('leave compressed flash mode', op: EspCommand.flashDeflEnd, data: _u32(reboot ? 0 : 1));
  }

  /// Send one [flashWriteSize] block of flash data with sequence number [seq].
  Future<void> flashBlock(Uint8List data, int seq, {Duration timeout = defaultTimeout}) async {
    final payload = _bytes([
      _u32(data.length),
      _u32(seq),
      _u32(0),
      _u32(0),
      data,
    ]);
    // Retry a couple of times — block writes occasionally fail on noisy links.
    for (var attempt = 3; attempt > 0; attempt--) {
      try {
        await checkCommand('write to flash after seq $seq',
            op: EspCommand.flashData, data: payload, checksum: checksum(data), timeout: timeout);
        return;
      } on EspException {
        if (attempt == 1) rethrow;
      }
    }
  }

  /// Leave flash download mode. With [reboot] `true` the chip runs the flashed
  /// application; otherwise it stays in the bootloader.
  Future<void> flashFinish({bool reboot = false}) async {
    await checkCommand('leave flash download mode', op: EspCommand.flashEnd, data: _u32(reboot ? 0 : 1));
  }

  /// Write [data] to flash starting at [offset], erasing the region first.
  ///
  /// With [compress] (default: whenever the stub is running) the data is sent
  /// zlib-compressed and inflated on the chip, which is several times faster
  /// on real firmware images. [onProgress] is called with the number of
  /// *uncompressed* bytes written and the total after each block. [finish]
  /// controls whether flash mode is left (and optionally the chip rebooted via
  /// [reboot]) afterwards.
  Future<void> writeFlash(
    int offset,
    Uint8List data, {
    void Function(int written, int total)? onProgress,
    bool? compress,
    bool finish = true,
    bool reboot = false,
  }) async {
    final size = data.length;
    if (compress ?? _isStub) {
      final compressed = ZLibEncoder().encodeBytes(data, level: 9);
      final numBlocks = await flashDeflBegin(size, compressed.length, offset);
      for (var seq = 0; seq < numBlocks; seq++) {
        final start = seq * flashWriteSize;
        final end = start + flashWriteSize < compressed.length ? start + flashWriteSize : compressed.length;
        await flashDeflBlock(Uint8List.sublistView(compressed, start, end), seq,
            timeout: _isStub ? _timeoutPerMb(eraseWriteTimeoutPerMb, size ~/ numBlocks) : defaultTimeout);
        // Compressed progress is only known in input terms; scale it.
        onProgress?.call(size * end ~/ compressed.length, size);
      }
      if (finish) await flashDeflFinish(reboot: reboot);
      return;
    }
    final numBlocks = await flashBegin(size, offset);
    for (var seq = 0; seq < numBlocks; seq++) {
      final start = seq * flashWriteSize;
      final end = start + flashWriteSize < size ? start + flashWriteSize : size;
      Uint8List block = Uint8List.sublistView(data, start, end);
      if (block.length < flashWriteSize) {
        final padded = Uint8List(flashWriteSize)..fillRange(0, flashWriteSize, 0xFF);
        padded.setRange(0, block.length, block);
        block = padded;
      }
      await flashBlock(block, seq);
      onProgress?.call(end, size);
    }
    if (finish) await flashFinish(reboot: reboot);
  }

  // --------------------------------------------------------------------------
  // Flash read (ROM slow path)
  // --------------------------------------------------------------------------

  /// Read [length] bytes of flash from [offset]. [onProgress] reports
  /// `(read, total)`.
  ///
  /// With the stub running this streams sector-sized SLIP frames and verifies
  /// an MD5 trailer. Otherwise it falls back to the ROM's 64-byte
  /// `READ_FLASH_SLOW`, which only the original ESP32 ROM implements — later
  /// ROMs silently drop it, so this throws [EspUnsupportedCommandException]
  /// up front for those (run the stub first).
  Future<Uint8List> readFlash(
    int offset,
    int length, {
    void Function(int read, int total)? onProgress,
  }) async {
    if (_isStub) return _readFlashStub(offset, length, onProgress);
    if (_chip != EspChip.esp32) throw EspUnsupportedCommandException(EspCommand.readFlashSlow.value);
    const blockLen = 64; // ROM per-command limit
    final out = Uint8List(length);
    var read = 0;
    while (read < length) {
      final want = (length - read) < blockLen ? (length - read) : blockLen;
      final (_, block) = await checkCommand('read flash block',
          op: EspCommand.readFlashSlow, data: _bytes([_u32(offset + read), _u32(want)]), respDataLen: blockLen);
      out.setRange(read, read + want, block);
      read += want;
      onProgress?.call(read, length);
    }
    return out;
  }

  /// Stub `READ_FLASH`: the stub pushes [flashSectorSize] frames, we ack each
  /// with the running byte count, and it finishes with a 16-byte MD5.
  Future<Uint8List> _readFlashStub(int offset, int length, void Function(int, int)? onProgress) async {
    const maxInFlight = 64;
    await checkCommand('read flash',
        op: EspCommand.readFlash, data: _bytes([_u32(offset), _u32(length), _u32(flashSectorSize), _u32(maxInFlight)]));
    final out = BytesBuilder(copy: false);
    while (out.length < length) {
      final frame = await _reader.read(defaultTimeout);
      out.add(frame);
      if (out.length < length && frame.length < flashSectorSize) {
        throw EspProtocolException('Corrupt data: expected 0x${flashSectorSize.toRadixString(16)}-byte '
            'frame but received 0x${frame.length.toRadixString(16)} bytes');
      }
      await transport.write(slipEncode(_u32(out.length)));
      onProgress?.call(out.length, length);
    }
    if (out.length > length) throw EspProtocolException('Read more than expected');
    final data = out.toBytes();
    final digest = await _reader.read(defaultTimeout);
    if (digest.length != 16) throw EspProtocolException('Expected MD5 digest, got ${_hex(digest)}');
    final expected = _hex(digest);
    final actual = md5.convert(data).toString();
    if (expected != actual) throw EspProtocolException('Digest mismatch: device $expected, host $actual');
    return data;
  }

  // --------------------------------------------------------------------------
  // Erase
  // --------------------------------------------------------------------------

  /// Erase the flash region of [size] bytes at [offset].
  ///
  /// The stub has a dedicated `ERASE_REGION`. The ROM does not, so there this
  /// leverages the implicit erase performed by [flashBegin] (the ROM erases the
  /// target region up front). [size] is rounded up to [flashSectorSize] by the
  /// chip.
  Future<void> eraseRegion(int offset, int size) async {
    if (_isStub) {
      await checkCommand('erase region',
          op: EspCommand.eraseRegion,
          data: _bytes([_u32(offset), _u32(size)]),
          timeout: _timeoutPerMb(eraseTimeoutPerMb, size));
      return;
    }
    await flashBegin(size, offset);
    await flashFinish();
  }

  /// Erase the entire flash.
  ///
  /// The stub has a dedicated `ERASE_FLASH`. On the ROM this issues the raw
  /// SPI `Chip Erase` (0xC7) command and polls the status register until the
  /// write-in-progress bit clears, which requires a chip with a known SPI
  /// register layout (see [EspChip.spi]).
  Future<void> eraseFlash({Duration timeout = chipEraseTimeout}) async {
    if (_isStub) {
      await checkCommand('erase flash', op: EspCommand.eraseFlash, timeout: timeout);
      return;
    }
    const spiflashWren = 0x06;
    const spiflashChipErase = 0xC7;
    await runSpiFlashCommand(spiflashWren); // write enable
    await runSpiFlashCommand(spiflashChipErase);
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final status = await readFlashStatus();
      if (status & 0x01 == 0) return; // WIP cleared
      if (DateTime.now().isAfter(deadline)) {
        throw EspException('Timed out waiting for chip erase to complete');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  // --------------------------------------------------------------------------
  // Flash attach / parameters
  // --------------------------------------------------------------------------

  /// Prepare the SPI flash for ROM-mode access, as esptool does before any
  /// flash command: attach the flash pins, detect the size from the JEDEC id,
  /// and pass it to the ROM. Call after [connect].
  ///
  /// Returns the detected size in bytes, or `null` if the id doesn't encode
  /// one (the ROM's default geometry is then left in place).
  Future<int?> attachFlash() async {
    await spiAttach();
    final capacity = (await flashId() >> 16) & 0xFF;
    if (capacity < 0x12 || capacity > 0x1A) return null;
    final size = 1 << capacity;
    await flashSetParameters(size);
    return size;
  }

  /// Attach the SPI flash (`SPI_ATTACH`). The ROM loader leaves flash detached
  /// — reads return `0xFF` — until told otherwise. [hspiArg] `0` selects the
  /// default SPI pins; the original ESP32 with custom eFuse SPI pads would need
  /// those pads encoded here instead.
  Future<void> spiAttach([int hspiArg = 0]) async {
    // The ROM takes an extra 4-byte "is legacy" word after the pin config.
    await checkCommand('configure SPI flash pins',
        op: EspCommand.spiAttach, data: _bytes([_u32(hspiArg), Uint8List(4)]));
  }

  /// Tell the ROM the flash geometry (`SPI_SET_PARAMS`, the ROM's in-RAM
  /// `flashchip` struct) for a chip of [size] bytes.
  Future<void> flashSetParameters(int size) async {
    await checkCommand('set SPI params',
        op: EspCommand.spiSetParams,
        data: _bytes([
          _u32(0), // fl_id
          _u32(size), // total_size
          _u32(64 * 1024), // block_size
          _u32(4 * 1024), // sector_size
          _u32(256), // page_size
          _u32(0xFFFF), // status_mask
        ]));
  }

  // --------------------------------------------------------------------------
  // Raw SPI flash commands
  // --------------------------------------------------------------------------

  /// Read the SPI flash JEDEC id (RDID, 0x9F): a 24-bit value whose high byte
  /// is the manufacturer and low bytes the memory type/capacity.
  Future<int> flashId() async {
    const spiflashRdid = 0x9F;
    return runSpiFlashCommand(spiflashRdid, readBits: 24);
  }

  /// Read the SPI flash status register (RDSR, 0x05); the low bit is
  /// write-in-progress (WIP).
  Future<int> readFlashStatus() async {
    const spiflashRdsr = 0x05;
    return runSpiFlashCommand(spiflashRdsr, readBits: 8);
  }

  /// Issue an arbitrary SPI flash command byte via the chip's SPI peripheral
  /// "user command" mechanism, writing [data] and reading back [readBits] bits.
  ///
  /// This mirrors esptool's `run_spiflash_command` and drives the SPI
  /// controller registers directly, so it requires a chip with a known
  /// [EspChip.spi] layout.
  Future<int> runSpiFlashCommand(
    int spiflashCommand, {
    Uint8List? data,
    int readBits = 0,
  }) async {
    data ??= Uint8List(0);
    final spi = _chip?.spi;
    if (spi == null) {
      throw EspException('Raw SPI flash commands are not supported for '
          '${_chip?.name ?? 'this chip'}');
    }
    if (readBits > 32) {
      throw EspException('Cannot read more than 32 bits from a SPI flash command');
    }
    if (data.length > 64) {
      throw EspException('Cannot write more than 64 bytes with one SPI command');
    }

    const spiUsrCommand = 1 << 31;
    const spiUsrMiso = 1 << 28;
    const spiUsrMosi = 1 << 27;
    const spiCmdUsr = 1 << 18;
    const spiUsr2CommandLenShift = 28;

    final base = spi.regBase;
    final spiCmdReg = base + 0x00;
    final spiUsrReg = base + spi.usrOffset;
    final spiUsr1Reg = base + spi.usr1Offset;
    final spiUsr2Reg = base + spi.usr2Offset;
    final spiW0Reg = base + spi.w0Offset;
    final spiMosiDlenReg = base + spi.mosiDlenOffset;
    final spiMisoDlenReg = base + spi.misoDlenOffset;

    final dataBits = data.length * 8;
    final oldSpiUsr = await readReg(spiUsrReg);
    final oldSpiUsr2 = await readReg(spiUsr2Reg);

    // Data lengths (ESP32-family "DLEN register" variant).
    if (dataBits > 0) await writeReg(spiMosiDlenReg, dataBits - 1);
    if (readBits > 0) await writeReg(spiMisoDlenReg, readBits - 1);
    await writeReg(spiUsr1Reg, 0);

    var flags = spiUsrCommand;
    if (readBits > 0) flags |= spiUsrMiso;
    if (dataBits > 0) flags |= spiUsrMosi;
    await writeReg(spiUsrReg, flags);
    await writeReg(spiUsr2Reg, (7 << spiUsr2CommandLenShift) | spiflashCommand);

    if (dataBits == 0) {
      await writeReg(spiW0Reg, 0);
    } else {
      final padded = Uint8List(((data.length + 3) ~/ 4) * 4)..setRange(0, data.length, data);
      final words = Uint32List.sublistView(padded);
      for (var i = 0; i < words.length; i++) {
        await writeReg(spiW0Reg + i * 4, words[i]);
      }
    }

    await writeReg(spiCmdReg, spiCmdUsr); // trigger

    for (var i = 0; i < 10; i++) {
      if (await readReg(spiCmdReg) & spiCmdUsr == 0) break;
      if (i == 9) throw EspException('SPI command did not complete in time');
    }

    final status = await readReg(spiW0Reg);
    // Restore the registers we clobbered.
    await writeReg(spiUsrReg, oldSpiUsr);
    await writeReg(spiUsr2Reg, oldSpiUsr2);
    return status;
  }

  // --------------------------------------------------------------------------
  // Misc
  // --------------------------------------------------------------------------

  /// Compute the MD5 of [size] flash bytes at [addr]; returns a lowercase hex
  /// string. Handy to verify a [writeFlash] against a local image.
  Future<String> flashMd5(int addr, int size) async {
    // The ROM replies with 32 ASCII hex chars, the stub with the 16 raw bytes.
    final (_, digest) = await checkCommand('calculate MD5',
        op: EspCommand.spiFlashMd5,
        data: _bytes([_u32(addr), _u32(size), _u32(0), _u32(0)]),
        respDataLen: _isStub ? 16 : 32,
        timeout: _timeoutPerMb(md5TimeoutPerMb, size));
    return _isStub ? _hex(digest) : String.fromCharCodes(digest);
  }

  /// Read the factory BASE_MAC address as six bytes.
  Future<Uint8List> readMac() async {
    final reg = _chip?.macEfuseReg;
    if (reg == null) {
      throw EspException('MAC read is not supported for ${_chip?.name ?? 'this chip'}');
    }
    final mac0 = await readReg(reg);
    final mac1 = await readReg(reg + 4);
    final packed = ByteData(8)
      ..setUint32(0, mac1, Endian.big)
      ..setUint32(4, mac0, Endian.big);
    return packed.buffer.asUint8List(2, 6);
  }

  /// Ask the chip to switch to [baud], then update the host transport to match.
  Future<void> changeBaudRate(int baud) async {
    // ROM expects (new_baud, 0); the stub wants the current rate as the second
    // word. (The ESP32 crystal-drift workaround is not applied here.)
    await command(op: EspCommand.changeBaudrate, data: _bytes([_u32(baud), _u32(_isStub ? _baudRate : 0)]));
    _baudRate = baud;
    await transport.setBaudRate(baud);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await transport.flushInput();
    _reader.flush();
  }

  /// Release the transport subscription. Does not close the transport itself.
  Future<void> dispose() => _reader.dispose();

  // --------------------------------------------------------------------------
  // Helpers
  // --------------------------------------------------------------------------

  static Uint8List _u32(int value) {
    final bytes = Uint8List(4);
    ByteData.sublistView(bytes).setUint32(0, value, Endian.little);
    return bytes;
  }

  static Uint8List _bytes(List<Uint8List> parts) {
    final builder = BytesBuilder(copy: false);
    for (final part in parts) {
      builder.add(part);
    }
    return builder.toBytes();
  }

  static String _hex(Uint8List bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static Duration _timeoutPerMb(Duration perMb, int sizeBytes) {
    final scaled = perMb * (sizeBytes / (1024 * 1024));
    return scaled > defaultTimeout ? scaled : defaultTimeout;
  }
}
