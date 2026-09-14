import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:idftool/idftool.dart';

import '../session/device_session.dart';
import '../session/flash_plan.dart';
import '../util/files.dart';
import '../widgets/empty_state.dart';
import '../widgets/op_tile.dart';
import '../widgets/port_picker.dart';

/// The one-click flasher at `/oneclick`: a bundle (from `?bundle=<url>` or a picked file),
/// an outline of what it will do, Connect, Flash, done. Any bundle works —
/// one by the filename convention, with or without a manifest of extras,
/// or an older recipe manifest. The bundle's name and description are the
/// page's only heading. None of the tool's machinery is shown; the log
/// stays behind a disclosure.
class OneClickPage extends StatefulWidget {
  const OneClickPage({super.key, required this.session, this.bundleUrl, this.bundle, this.onBack});
  final DeviceSession session;
  final Uri? bundleUrl;

  /// A bundle already in hand (the Flash page previewing its plan).
  final FlashBundle? bundle;

  /// Shown as a way back when this page was pushed over the full tool.
  final VoidCallback? onBack;

  @override
  State<OneClickPage> createState() => _OneClickPageState();
}

enum _Phase { loading, loadFailed, ready, flashing, done, failed }

class _OneClickPageState extends State<OneClickPage> {
  _Phase _phase = _Phase.loading;
  FlashBundle? _bundle;
  String? _problem;
  int _currentStep = -1;
  final _completed = <int>{};
  /// The log appears once a device has been connected and stays for good.
  bool _logShown = false;

  DeviceSession get session => widget.session;

  @override
  void initState() {
    super.initState();
    final url = widget.bundleUrl;
    if (widget.bundle case final bundle?) {
      _bundle = bundle;
      _phase = _Phase.ready;
    } else if (url != null) {
      _fetch(url);
    } else {
      _phase = _Phase.loadFailed;
      _problem = null; // no URL: offer the file picker
    }
  }

  Future<void> _fetch(Uri url) async {
    setState(() {
      _phase = _Phase.loading;
      _problem = null;
    });
    try {
      // The bundle host only needs CORS; the browser sends its cookies for
      // same-site hosts (Cloudflare Access) as usual.
      final response = await http.get(url);
      if (response.statusCode != 200) throw IdfToolException('HTTP ${response.statusCode} fetching the bundle');
      _use(response.bodyBytes, url.pathSegments.lastOrNull ?? 'bundle');
    } catch (e) {
      setState(() {
        _phase = _Phase.loadFailed;
        _problem = 'Could not load the bundle from $url: $e';
      });
    }
  }

  Future<void> _pick() async {
    final file = await pickFile(extensions: ['zip']);
    if (file == null) return;
    _use(file.bytes, file.name);
  }

  void _use(Uint8List bytes, String name) {
    try {
      final bundle = FlashBundle.fromZip(bytes, source: name);
      setState(() {
        _bundle = bundle;
        _phase = _Phase.ready;
        _problem = null;
        _completed.clear();
        _currentStep = -1;
      });
    } catch (e) {
      setState(() {
        _phase = _Phase.loadFailed;
        _problem = '$name is not a usable bundle: $e';
      });
    }
  }

  /// Drop the bundle and go back to the empty page.
  void _close() => setState(() {
        _bundle = null;
        _phase = _Phase.loadFailed;
        _problem = null;
        _completed.clear();
        _currentStep = -1;
      });

  Future<void> _flash() async {
    final bundle = _bundle!;
    setState(() {
      _phase = _Phase.flashing;
      _completed.clear();
      _currentStep = -1;
      _problem = null;
    });
    Object? failure;
    await session.runDevice('Flash ${bundle.name}', (device) async {
      try {
        await runFlashBundle(
          device,
          bundle,
          onStep: (i, _) => setState(() {
            if (_currentStep >= 0) _completed.add(_currentStep);
            _currentStep = i;
          }),
          onProgress: session.reportProgress,
          nvsKeys: session.nvsKeys,
          log: session.addLog,
        );
        _completed.add(_currentStep);
      } catch (e) {
        failure = e;
        rethrow;
      }
    });
    if (!mounted) return;
    if (failure == null && session.connected) {
      await session.disconnect(hardReset: true);
      setState(() => _phase = _Phase.done);
    } else {
      setState(() {
        _phase = _Phase.failed;
        _problem = failure == null ? 'The device disconnected during flashing' : '$failure';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bundle = _bundle;
    if (session.connected) _logShown = true;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(padding: const EdgeInsets.all(32), shrinkWrap: true, children: [
            if (widget.onBack case final onBack?)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: TextButton.icon(onPressed: onBack, icon: const Icon(Icons.arrow_back, size: 18), label: const Text('Back to the plan')),
                ),
              ),
            switch (_phase) {
              _Phase.loading => const LoadingState('Loading the update…'),
              _Phase.loadFailed => EmptyState(
                  icon: _problem == null ? Icons.unarchive_outlined : Icons.error_outline,
                  title: _problem == null ? 'No bundle opened' : 'Could not open the bundle',
                  message: _problem ?? 'Open a firmware bundle to review its steps, then connect a device and flash it.',
                  error: _problem != null,
                  actions: [
                    if (_problem != null && widget.bundleUrl != null)
                      FilledButton.tonalIcon(onPressed: () => _fetch(widget.bundleUrl!), icon: const Icon(Icons.refresh), label: const Text('Retry')),
                    FilledButton.tonalIcon(onPressed: _pick, icon: const Icon(Icons.folder_open), label: const Text('Open a bundle file…')),
                  ],
                ),
              _ => _bundleCard(bundle!, theme),
            },
            if (_logShown) ...[
              const SizedBox(height: 16),
              _log(theme),
            ],
          ]),
        ),
      ),
    );
  }

  Widget _bundleCard(FlashBundle bundle, ThemeData theme) {
    final flashing = _phase == _Phase.flashing;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: Text(bundle.name, style: theme.textTheme.titleLarge)),
            if (widget.bundle == null)
              IconButton(
                tooltip: 'Close this bundle',
                icon: const Icon(Icons.close),
                onPressed: flashing ? null : _close,
              ),
          ]),
          if (bundle.description != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(bundle.description!)),
          if (bundle.chip != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text('For ${bundle.chip!.name}', style: theme.textTheme.bodySmall)),
          const SizedBox(height: 16),
          Text('This update will:', style: theme.textTheme.labelLarge),
          for (var i = 0; i < bundle.steps.length; i++)
            if (_row(bundle, bundle.steps[i]) case final row)
              OpTile(
                icon: row.icon,
                name: row.name,
                detail: row.detail,
                summary: row.summary,
                leading: SizedBox(
                  width: 24,
                  child: Center(
                    child: _completed.contains(i)
                        ? const Icon(Icons.check_circle, size: 18, color: Colors.green)
                        : i == _currentStep && flashing
                            ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                            : _phase == _Phase.failed && i == _currentStep
                                ? Icon(Icons.error, size: 18, color: theme.colorScheme.error)
                                : Text('${i + 1}.', style: theme.textTheme.bodyMedium),
                  ),
                ),
              ),
          const SizedBox(height: 20),
          switch (_phase) {
            _Phase.done => Row(children: [
                const Icon(Icons.check_circle, color: Colors.green),
                const SizedBox(width: 8),
                const Expanded(child: Text('Done. The device has been reset and is running the update.')),
                TextButton(onPressed: () => setState(() => _phase = _Phase.ready), child: const Text('Flash another')),
              ]),
            _Phase.failed => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Flashing failed: $_problem', style: TextStyle(color: theme.colorScheme.error)),
                const SizedBox(height: 8),
                Text('Reconnect the device and try again. If it keeps failing, send the log below to support.', style: theme.textTheme.bodySmall),
                const SizedBox(height: 8),
                FilledButton.tonal(onPressed: () => setState(() => _phase = _Phase.ready), child: const Text('Try again')),
              ]),
            _ => _connectAndFlash(theme),
          },
        ]),
      ),
    );
  }

  /// A step as the Flash page shows a planned operation: where it lands
  /// (named against the bundle's own table when it carries one) and what
  /// is written there.
  ({IconData icon, String name, String detail, String summary}) _row(FlashBundle bundle, FlashStep step) {
    final table = bundle.contents.table;
    String size(String file) => bundle.files[file]?.length.bytesString ?? '?';
    PartitionDefinition? find(String name) => table?.findByName(name);
    String offset(String name) => find(name)?.offset.hex ?? 'by name';
    return switch (step) {
      WriteTableStep(:final file) => (icon: Icons.table_chart, name: 'partition_table', detail: PartitionTable.defaultOffset.hex, summary: 'Write $file (first)'),
      WriteBootloaderStep(:final file) => (
          icon: Icons.upload_file,
          name: 'bootloader',
          detail: bundle.chip?.bootloaderFlashOffset.hex ?? 'chip offset',
          summary: 'Write $file (${size(file)})',
        ),
      FactoryStep(:final file) => (
          icon: Icons.upload_file,
          name: FlashRole.factory.fileStem,
          detail: table == null ? FlashRole.factory.label : factoryTarget(table)?.name ?? FlashRole.factory.label,
          summary: 'Write $file (${size(file)}) to ${FlashRole.factory.description}',
        ),
      OtaStep(:final file) => (
          icon: Icons.upload_file,
          name: FlashRole.ota.fileStem,
          detail: FlashRole.ota.label,
          summary: 'Write $file (${size(file)}) to ${FlashRole.ota.description}',
        ),
      WritePartitionStep(:final partition, :final file) => (icon: Icons.upload_file, name: partition, detail: offset(partition), summary: 'Write $file (${size(file)})'),
      WriteFsStep(:final partition, :final file) => (icon: Icons.folder_outlined, name: partition, detail: offset(partition), summary: 'Write filesystem image $file (${size(file)})'),
      EraseStep(:final partition) => (
          icon: Icons.delete_outline,
          name: partition,
          detail: offset(partition),
          summary: switch (find(partition)) { final p? => 'Erase ${p.size.bytesString}', null => 'Erase' },
        ),
      SetNvsStep(:final partition, :final set, :final delete) => (
          icon: Icons.edit_note,
          name: partition ?? 'nvs',
          detail: partition == null ? 'first nvs' : offset(partition),
          summary: [for (final e in set.entries) 'Set ${e.key} = ${e.value}', for (final d in delete) 'Delete $d'].join(', '),
        ),
      EditFsStep(:final partition, :final put, :final delete) => (
          icon: Icons.folder_outlined,
          name: partition,
          detail: offset(partition),
          summary: [for (final e in put.entries) 'Put ${e.key} (${size(e.value)})', for (final d in delete) 'Delete $d'].join(', '),
        ),
      SetBootStep(:final partition) => (icon: Icons.restart_alt, name: partition, detail: offset(partition), summary: 'Boot from it next'),
      ClearBootStep() => (icon: Icons.restart_alt, name: 'otadata', detail: offset('otadata'), summary: 'Clear the OTA selection so the factory app boots'),
      WriteBundleStep() => (icon: Icons.unarchive_outlined, name: 'bundle', detail: '', summary: step.describe()),
    };
  }

  Widget _connectAndFlash(ThemeData theme) {
    final flashing = _phase == _Phase.flashing;
    if (!DeviceSession.supported) {
      return Text('This needs the Web Serial API — open this page in Chrome or Edge.', style: TextStyle(color: theme.colorScheme.error));
    }
    if (!session.connected) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Plug the device in over USB, then connect. Chrome will ask which port to use.'),
        const SizedBox(height: 12),
        Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          FilledButton.icon(
            onPressed: session.busy
                ? null
                : () async {
                    if (session.selectedPort == null) await session.requestPort();
                    if (session.selectedPort != null) await session.connect();
                  },
            icon: session.busy ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.usb),
            label: Text(session.busy ? 'Connecting…' : 'Connect device'),
          ),
          if (session.ports.isNotEmpty) PortPicker(session: session, width: 360, enabled: !session.busy),
        ]),
        if (session.log.any((l) => l.error)) ...[
          const SizedBox(height: 8),
          Text(session.log.lastWhere((l) => l.error).message, style: TextStyle(color: theme.colorScheme.error)),
        ],
      ]);
    }
    final chipMismatch = _bundle!.chip != null && session.chip != _bundle!.chip;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Icon(Icons.check_circle, size: 18, color: Colors.green),
        const SizedBox(width: 8),
        Text('Connected: ${session.chip?.name}, ${session.macString}'),
      ]),
      if (chipMismatch)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('This update is for ${_bundle!.chip!.name}, but the connected device is a ${session.chip?.name}.',
              style: TextStyle(color: theme.colorScheme.error)),
        ),
      const SizedBox(height: 12),
      Row(children: [
        FilledButton.icon(
          onPressed: flashing || chipMismatch ? null : _flash,
          icon: const Icon(Icons.flash_on),
          label: Text(flashing ? 'Flashing…' : 'Flash'),
        ),
        const SizedBox(width: 12),
        if (!flashing) TextButton(onPressed: () => session.disconnect(hardReset: false), child: const Text('Disconnect')),
      ]),
      if (flashing && session.progress != null) ...[
        const SizedBox(height: 12),
        LinearProgressIndicator(value: session.progress!.fraction),
        const SizedBox(height: 4),
        Text('${session.progress!.label}: ${session.progress!.done.bytesString} / ${session.progress!.total.bytesString}', style: theme.textTheme.bodySmall),
      ],
    ]);
  }

  Widget _log(ThemeData theme) => Container(
        height: 220,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(border: Border.all(color: theme.dividerColor), borderRadius: BorderRadius.circular(8)),
        child: SelectionArea(
          child: ListView(children: [
            for (final l in session.log)
              Text(l.message, style: TextStyle(fontFamily: 'RobotoMono', fontSize: 12, color: l.error ? theme.colorScheme.error : null)),
          ]),
        ),
      );
}
