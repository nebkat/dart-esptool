import 'package:esptool/esptool.dart';
import 'package:flutter/material.dart';
import 'package:idftool/idftool.dart';

import '../session/device_session.dart';
import '../util/files.dart';
import '../widgets/dialogs.dart';
import '../widgets/dropdown.dart';

/// Flash an app (factory or OTA), choose the boot slot, and move whole-flash
/// images and bundles.
class FirmwarePage extends StatefulWidget {
  const FirmwarePage({super.key, required this.session});
  final DeviceSession session;

  @override
  State<FirmwarePage> createState() => _FirmwarePageState();
}

class _FirmwarePageState extends State<FirmwarePage> {
  PickedFile? _app;
  ImageMetadata? _appImage;
  String? _appProblem;
  WriteStrategy _strategy = WriteStrategy.differential;
  bool _eraseBeforeImage = true;

  DeviceSession get session => widget.session;

  Future<void> _pickApp() async {
    final file = await pickFile(extensions: ['bin']);
    if (file == null) return;
    setState(() {
      _app = file;
      _appProblem = null;
      try {
        _appImage = ImageMetadata.fromBytes(file.bytes, appRequired: true);
      } catch (e) {
        _appImage = null;
        _appProblem = 'Not a valid application image: $e';
      }
    });
  }

  String _describe(WriteOutcome o) => o.skipped
      ? 'already in flash, nothing written'
      : 'wrote ${o.written.bytesString} in ${o.runs} region${o.runs == 1 ? '' : 's'} in ${(o.elapsed.inMilliseconds / 1000).toStringAsFixed(1)} s'
          '${o.abandoned ? ' (comparison abandoned part-way)' : ''}';

  Future<void> _factory() async {
    final app = _app!;
    if (!await confirm(context, title: 'Flash to factory?', message: 'Write ${app.name} to the factory partition and clear otadata so it boots.')) return;
    final o = await session.runDevice('Factory flash ${app.name}', (d) => d.factory(app.bytes, strategy: _strategy, onProgress: session.reportProgress));
    if (o != null) session.addLog('Factory: ${_describe(o)}');
  }

  Future<void> _ota() async {
    final app = _app!;
    if (!await confirm(context, title: 'OTA update?', message: 'Write ${app.name} to the next OTA slot and switch the bootloader to it.')) return;
    final r = await session.runDevice('OTA ${app.name}', (d) => d.ota(app.bytes, strategy: _strategy, onProgress: session.reportProgress));
    if (r != null) session.addLog('OTA to ${r.partition.name}: ${_describe(r.outcome)}');
  }

  Future<void> _dumpBundle() async {
    final zip = await session.runDevice('Dump bundle', (d) => d.dumpBundle(onProgress: session.reportProgress));
    if (zip != null) await saveBytes('${session.chip!.name.toLowerCase()}-${session.macString?.replaceAll(':', '')}.zip', zip, mimeType: 'application/zip');
  }

  Future<void> _writeBundle() async {
    final file = await pickFile(extensions: ['zip']);
    if (file == null || !mounted) return;
    if (!await confirm(context, title: 'Write bundle?', message: 'Flash every partition image in ${file.name}.')) return;
    final r = await session.runDevice('Write bundle ${file.name}', (d) => d.writeBundle(file.bytes, strategy: _strategy, onProgress: session.reportProgress));
    r?.forEach((name, o) => session.addLog('$name: ${_describe(o)}'));
  }

  Future<void> _dumpImage() async {
    final size = session.flashSize;
    if (size == null) return;
    final data = await session.runDevice('Dump full flash', (d) => d.dumpImage(flashSize: size, onProgress: session.reportProgress));
    if (data != null) await saveBytes('${session.chip!.name.toLowerCase()}-${session.macString?.replaceAll(':', '')}.img', data);
  }

  Future<void> _writeImage() async {
    final file = await pickFile(extensions: ['img', 'bin']);
    if (file == null || !mounted) return;
    if (!await confirm(context,
        title: 'Write whole-flash image?',
        message: 'Write ${file.name} (${file.bytes.length.bytesString}) from address 0.'
            '${_eraseBeforeImage ? ' The ENTIRE flash is erased first.' : ''}',
        destructive: true)) {
      return;
    }
    final o = await session.runDevice('Write image ${file.name}',
        (d) => d.writeImage(file.bytes, erase: _eraseBeforeImage, strategy: _strategy, onProgress: session.reportProgress));
    if (o != null) session.addLog('Image: ${_describe(o)}');
  }

  @override
  Widget build(BuildContext context) {
    if (!session.connected) return const Center(child: Text('Connect to a device first.'));
    final busy = session.busy;
    final theme = Theme.of(context);
    final image = _appImage;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Application', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              OutlinedButton.icon(
                onPressed: busy ? null : _pickApp,
                icon: const Icon(Icons.folder_open),
                label: Text(_app == null ? 'Choose app .bin…' : '${_app!.name} (${_app!.bytes.length.bytesString})'),
              ),
              AppDropdown<WriteStrategy>(
                value: _strategy,
                label: 'Strategy',
                entries: const [
                  DropdownMenuEntry(value: WriteStrategy.differential, label: 'Write changed sectors only'),
                  DropdownMenuEntry(value: WriteStrategy.skipFlashed, label: 'Skip if already flashed'),
                  DropdownMenuEntry(value: WriteStrategy.always, label: 'Always write everything'),
                ],
                onSelected: (s) => setState(() => _strategy = s ?? _strategy),
              ),
              FilledButton.icon(onPressed: busy || image == null ? null : _ota, icon: const Icon(Icons.system_update_alt), label: const Text('OTA to next slot')),
              FilledButton.tonalIcon(onPressed: busy || image == null ? null : _factory, icon: const Icon(Icons.factory_outlined), label: const Text('Flash to factory')),
            ]),
            if (_appProblem != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_appProblem!, style: TextStyle(color: theme.colorScheme.error))),
            if (image != null) ...[
              const SizedBox(height: 12),
              for (final (k, v) in [
                ('Project', image.appDescription!.projectName),
                ('Version', image.appDescription!.version),
                ('IDF', image.appDescription!.idfVersion),
                ('Compiled', '${image.appDescription!.date} ${image.appDescription!.time}'),
                ('Chip', '${image.header.chipId?.name ?? 'unknown'}'
                    '${image.header.chipId?.value == session.chip?.imageChipId ? '' : '  ⚠ does not match the connected ${session.chip?.name}'}'),
                ('ELF SHA256', image.appDescription!.elfSha256.map((b) => b.toRadixString(16).padLeft(2, '0')).join()),
              ])
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(children: [
                    SizedBox(width: 90, child: Text(k, style: theme.textTheme.labelLarge)),
                    Flexible(child: SelectableText(v, style: const TextStyle(fontFamily: 'RobotoMono'))),
                  ]),
                ),
            ],
          ]),
        ),
      ),
      const SizedBox(height: 16),
      _BootCard(session: session),
      const SizedBox(height: 16),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Whole device', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              OutlinedButton.icon(onPressed: busy ? null : _dumpBundle, icon: const Icon(Icons.archive_outlined), label: const Text('Dump bundle (zip)')),
              OutlinedButton.icon(onPressed: busy ? null : _writeBundle, icon: const Icon(Icons.unarchive_outlined), label: const Text('Write bundle…')),
              const SizedBox(width: 16),
              OutlinedButton.icon(
                  onPressed: busy || session.flashSize == null ? null : _dumpImage,
                  icon: const Icon(Icons.download),
                  label: Text('Dump full flash (${session.flashSize?.bytesString ?? '?'})')),
              OutlinedButton.icon(onPressed: busy ? null : _writeImage, icon: const Icon(Icons.upload), label: const Text('Write image…')),
              Tooltip(
                message: 'On: erase the entire chip first, so flash beyond the image (and anything it does not cover) is wiped '
                    'and the result is reproducible.\nOff: write only the image\'s span — with the differential strategy only the sectors that differ — '
                    'leaving the rest of flash (e.g. logs, data partitions past the image) untouched.',
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Checkbox(value: _eraseBeforeImage, onChanged: (v) => setState(() => _eraseBeforeImage = v!)),
                  const Text('Erase entire chip first (wipe everything the image doesn\'t cover)'),
                ]),
              ),
            ]),
          ]),
        ),
      ),
    ]);
  }
}

class _BootCard extends StatefulWidget {
  const _BootCard({required this.session});
  final DeviceSession session;

  @override
  State<_BootCard> createState() => _BootCardState();
}

class _BootCardState extends State<_BootCard> {
  OtaDataParameters? _otadata;
  List<PartitionDefinition> _slots = const [];
  String? _problem;
  bool _loaded = false;

  DeviceSession get session => widget.session;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (session.connected && !_loaded && !session.busy) {
      _loaded = true;
      _refresh();
    }
    if (!session.connected) _loaded = false;
  }

  Future<void> _refresh() async {
    await session.runDevice('Read boot slot', (d) async {
      final table = await d.partitionTable();
      final slots = table.where((p) => p.isOtaApp).toList();
      OtaDataParameters? otadata;
      String? problem;
      try {
        otadata = (await d.readOtadata()).otadata;
      } on IdfToolException catch (e) {
        problem = e.message;
      }
      if (mounted) {
        setState(() {
          _slots = slots;
          _otadata = otadata;
          _problem = problem;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final busy = session.busy;
    final otadata = _otadata;
    final active = otadata?.slot;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text('Boot slot', style: Theme.of(context).textTheme.titleMedium),
            IconButton(icon: const Icon(Icons.refresh, size: 20), onPressed: busy ? null : _refresh),
          ]),
          if (_problem != null)
            Text(_problem!)
          else if (otadata != null) ...[
            Text(active == null
                ? 'OTA slot not set — the factory app boots'
                : "Boots 'ota_$active' (seq ${otadata.entry!.seq}, state ${otadata.entry!.state.name})"),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final p in _slots)
                FilledButton.tonal(
                  onPressed: busy || active == p.subtype - AppSubtype.otaMin
                      ? null
                      : () async {
                          await session.runDevice('Set boot partition to ${p.name}', (d) => d.setBoot(p.name));
                          await _refresh();
                        },
                  child: Text('Boot ${p.name}'),
                ),
              OutlinedButton(
                onPressed: busy || active == null
                    ? null
                    : () async {
                        await session.runDevice('Clear boot slot', (d) => d.clearBoot());
                        await _refresh();
                      },
                child: const Text('Clear (boot factory)'),
              ),
            ]),
          ],
        ]),
      ),
    );
  }
}
