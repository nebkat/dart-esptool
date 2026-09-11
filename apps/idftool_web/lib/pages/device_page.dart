import 'package:esptool/esptool.dart';
import 'package:esptool/web.dart';
import 'package:flutter/material.dart';

import '../session/device_session.dart';
import '../util/files.dart';
import '../widgets/hex_field.dart';

/// Connection controls, chip facts, and raw flash operations by address.
class DevicePage extends StatelessWidget {
  const DevicePage({super.key, required this.session});
  final DeviceSession session;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _ConnectionCard(session: session),
        const SizedBox(height: 16),
        if (session.connected) ...[
          _ChipCard(session: session),
          const SizedBox(height: 16),
          _RawFlashCard(session: session),
        ],
      ],
    );
  }
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({required this.session});
  final DeviceSession session;

  @override
  Widget build(BuildContext context) {
    final locked = session.connected || session.busy;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Connection', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 320,
                  child: DropdownButtonFormField<SerialPort>(
                    key: ValueKey(session.selectedPort),
                    initialValue: session.selectedPort,
                    decoration: const InputDecoration(labelText: 'Port', border: OutlineInputBorder(), isDense: true),
                    items: [
                      for (final p in session.ports)
                        DropdownMenuItem(value: p, child: Text(DeviceSession.describePort(p), overflow: TextOverflow.ellipsis)),
                    ],
                    onChanged: locked ? null : session.selectPort,
                    hint: const Text('No port granted'),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: locked ? null : session.requestPort,
                  icon: const Icon(Icons.usb),
                  label: const Text('Add port…'),
                ),
                SizedBox(
                  width: 260,
                  child: DropdownButtonFormField<ResetChoice>(
                    key: ValueKey(session.reset),
                    initialValue: session.reset,
                    decoration: const InputDecoration(labelText: 'Reset', border: OutlineInputBorder(), isDense: true),
                    items: [for (final r in ResetChoice.values) DropdownMenuItem(value: r, child: Text(r.label))],
                    onChanged: locked ? null : (v) => session.setReset(v!),
                  ),
                ),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Checkbox(value: session.useStub, onChanged: locked ? null : (v) => session.setUseStub(v!)),
                  const Text('Flasher stub'),
                ]),
                if (!session.connected)
                  FilledButton.icon(
                    onPressed: session.busy || session.selectedPort == null ? null : session.connect,
                    icon: session.busy
                        ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.link),
                    label: Text(session.busy ? 'Connecting…' : 'Connect'),
                  )
                else ...[
                  FilledButton.tonalIcon(
                    onPressed: session.busy ? null : () => session.disconnect(hardReset: true),
                    icon: const Icon(Icons.restart_alt),
                    label: const Text('Reset & disconnect'),
                  ),
                  TextButton(
                    onPressed: session.busy ? null : () => session.disconnect(hardReset: false),
                    child: const Text('Disconnect'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ChipCard extends StatelessWidget {
  const _ChipCard({required this.session});
  final DeviceSession session;

  @override
  Widget build(BuildContext context) {
    final loader = session.loader!;
    final rows = <(String, String)>[
      ('Chip', session.chip?.name ?? '?'),
      ('MAC', session.macString ?? '?'),
      ('Flash', '${session.flashSize?.bytesString ?? 'unknown size'}  (JEDEC ${session.flashId ?? '?'})'),
      ('Loader', loader.isStub ? 'flasher stub (block ${loader.flashWriteSize.bytesString})' : 'ROM (no stub)'),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Device', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final (k, v) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(children: [
                  SizedBox(width: 80, child: Text(k, style: Theme.of(context).textTheme.labelLarge)),
                  SelectableText(v, style: const TextStyle(fontFamily: 'monospace')),
                ]),
              ),
          ],
        ),
      ),
    );
  }
}

class _RawFlashCard extends StatefulWidget {
  const _RawFlashCard({required this.session});
  final DeviceSession session;

  @override
  State<_RawFlashCard> createState() => _RawFlashCardState();
}

class _RawFlashCardState extends State<_RawFlashCard> {
  final _readAddr = TextEditingController(text: '0x0');
  final _readLen = TextEditingController(text: '0x1000');
  final _writeAddr = TextEditingController(text: '0x10000');
  final _eraseAddr = TextEditingController(text: '0x0');
  final _eraseLen = TextEditingController(text: '0x1000');
  PickedFile? _writeFile;

  DeviceSession get session => widget.session;

  @override
  void dispose() {
    for (final c in [_readAddr, _readLen, _writeAddr, _eraseAddr, _eraseLen]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _read() async {
    final addr = parseHex(_readAddr.text), len = parseHex(_readLen.text);
    if (addr == null || len == null) return;
    final data = await session.run('Read ${len.bytesString} at ${addr.hex}', (loader) {
      return loader.readFlash(addr, len, onProgress: (done, total) => session.reportProgress('Read', done, total));
    });
    if (data != null) await saveBytes('flash_${addr.toRadixString(16).padLeft(6, '0')}_${len.hex}.bin', data);
  }

  Future<void> _write() async {
    final addr = parseHex(_writeAddr.text);
    final file = _writeFile;
    if (addr == null || file == null) return;
    await session.run('Write ${file.name} (${file.bytes.length.bytesString}) at ${addr.hex}', (loader) async {
      await loader.writeFlash(addr, file.bytes,
          onProgress: (done, total) => session.reportProgress('Written', done, total));
      final device = await loader.flashMd5(addr, file.bytes.length);
      session.addLog('Device MD5 $device');
    });
  }

  Future<void> _erase() async {
    final addr = parseHex(_eraseAddr.text), len = parseHex(_eraseLen.text);
    if (addr == null || len == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Erase flash?'),
        content: Text('Erase ${len.bytesString} at ${addr.hex}. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Erase')),
        ],
      ),
    );
    if (ok != true) return;
    await session.run('Erase ${len.bytesString} at ${addr.hex}', (loader) => loader.eraseRegion(addr, len));
  }

  @override
  Widget build(BuildContext context) {
    final busy = session.busy;
    final romOnly = !(session.loader?.isStub ?? false) && session.chip != EspChip.esp32;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Raw flash', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              HexField(controller: _readAddr, label: 'Address'),
              HexField(controller: _readLen, label: 'Length'),
              FilledButton.tonalIcon(
                onPressed: busy || romOnly ? null : _read,
                icon: const Icon(Icons.download),
                label: const Text('Read to file'),
              ),
              if (romOnly) const Text('Reading needs the flasher stub on this chip'),
            ]),
            const Divider(height: 24),
            Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              OutlinedButton.icon(
                onPressed: busy
                    ? null
                    : () async {
                        final f = await pickFile(extensions: ['bin']);
                        if (f != null) setState(() => _writeFile = f);
                      },
                icon: const Icon(Icons.folder_open),
                label: Text(_writeFile == null ? 'Choose file…' : '${_writeFile!.name} (${_writeFile!.bytes.length.bytesString})'),
              ),
              HexField(controller: _writeAddr, label: 'Address'),
              FilledButton.tonalIcon(
                onPressed: busy || _writeFile == null ? null : _write,
                icon: const Icon(Icons.upload),
                label: const Text('Write'),
              ),
            ]),
            const Divider(height: 24),
            Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              HexField(controller: _eraseAddr, label: 'Address'),
              HexField(controller: _eraseLen, label: 'Length'),
              FilledButton.tonalIcon(
                onPressed: busy ? null : _erase,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Erase'),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

/// `0x`-hex or decimal, `null` if malformed.
int? parseHex(String text) {
  final s = text.trim().toLowerCase();
  if (s.startsWith('0x')) return int.tryParse(s.substring(2), radix: 16);
  return int.tryParse(s);
}
