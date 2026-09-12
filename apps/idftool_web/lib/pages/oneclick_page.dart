import 'dart:typed_data';

import 'package:esptool/web.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:idftool/idftool.dart';

import '../session/device_session.dart';
import '../util/files.dart';

/// The one-click flasher: a bundle (from `?bundle=<url>` or a picked file),
/// an outline of what it will do, Connect, Flash, done. None of the tool's
/// machinery is shown; the log stays behind a disclosure.
class OneClickPage extends StatefulWidget {
  const OneClickPage({super.key, required this.session, this.bundleUrl});
  final DeviceSession session;
  final Uri? bundleUrl;

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
  bool _showLog = false;

  DeviceSession get session => widget.session;

  @override
  void initState() {
    super.initState();
    final url = widget.bundleUrl;
    if (url != null) {
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
      final bundle = FlashBundle.fromZip(bytes);
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

  Future<void> _flash() async {
    final bundle = _bundle!;
    setState(() {
      _phase = _Phase.flashing;
      _completed.clear();
      _currentStep = -1;
      _problem = null;
    });
    Object? failure;
    await session.runDevice('Flash ${bundle.manifest.name}', (device) async {
      try {
        await runFlashBundle(
          device,
          bundle,
          onStep: (i, _) => setState(() {
            if (_currentStep >= 0) _completed.add(_currentStep);
            _currentStep = i;
          }),
          onProgress: session.reportProgress,
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
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(padding: const EdgeInsets.all(32), shrinkWrap: true, children: [
            Text('FarmTRX device flasher', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 24),
            switch (_phase) {
              _Phase.loading => const Row(children: [
                  SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 12),
                  Text('Loading the update…'),
                ]),
              _Phase.loadFailed => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (_problem != null) ...[
                    Text(_problem!, style: TextStyle(color: theme.colorScheme.error)),
                    const SizedBox(height: 12),
                  ],
                  Wrap(spacing: 8, children: [
                    if (widget.bundleUrl != null) FilledButton.tonal(onPressed: () => _fetch(widget.bundleUrl!), child: const Text('Retry')),
                    OutlinedButton.icon(onPressed: _pick, icon: const Icon(Icons.folder_open), label: const Text('Open a bundle file…')),
                  ]),
                ]),
              _ => _bundleCard(bundle!, theme),
            },
            const SizedBox(height: 16),
            _logDisclosure(theme),
          ]),
        ),
      ),
    );
  }

  Widget _bundleCard(FlashBundle bundle, ThemeData theme) {
    final m = bundle.manifest;
    final flashing = _phase == _Phase.flashing;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(m.name, style: theme.textTheme.titleLarge),
          if (m.description != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(m.description!)),
          if (m.chip != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text('For ${m.chip!.name}', style: theme.textTheme.bodySmall)),
          const SizedBox(height: 16),
          Text('This update will:', style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          for (var i = 0; i < m.steps.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(
                  width: 28,
                  child: _completed.contains(i)
                      ? const Icon(Icons.check_circle, size: 18, color: Colors.green)
                      : i == _currentStep && flashing
                          ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : _phase == _Phase.failed && i == _currentStep
                              ? Icon(Icons.error, size: 18, color: theme.colorScheme.error)
                              : Text('${i + 1}.', style: theme.textTheme.bodyMedium),
                ),
                Expanded(child: Text(m.steps[i].describe())),
              ]),
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
                FilledButton(onPressed: () => setState(() => _phase = _Phase.ready), child: const Text('Try again')),
              ]),
            _ => _connectAndFlash(theme),
          },
        ]),
      ),
    );
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
          if (session.ports.length > 1)
            DropdownButton<SerialPort>(
              value: session.selectedPort,
              items: [for (final p in session.ports) DropdownMenuItem(value: p, child: Text(DeviceSession.describePort(p)))],
              onChanged: session.busy ? null : session.selectPort,
            ),
          if (session.ports.isNotEmpty) TextButton(onPressed: session.busy ? null : session.requestPort, child: const Text('Choose another port…')),
        ]),
        if (session.log.any((l) => l.error)) ...[
          const SizedBox(height: 8),
          Text(session.log.lastWhere((l) => l.error).message, style: TextStyle(color: theme.colorScheme.error)),
        ],
      ]);
    }
    final chipMismatch = _bundle!.manifest.chip != null && session.chip != _bundle!.manifest.chip;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Icon(Icons.check_circle, size: 18, color: Colors.green),
        const SizedBox(width: 8),
        Text('Connected: ${session.chip?.name}, ${session.macString}'),
      ]),
      if (chipMismatch)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('This update is for ${_bundle!.manifest.chip!.name}, but the connected device is a ${session.chip?.name}.',
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

  Widget _logDisclosure(ThemeData theme) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      TextButton.icon(
        onPressed: () => setState(() => _showLog = !_showLog),
        icon: Icon(_showLog ? Icons.expand_less : Icons.expand_more, size: 18),
        label: Text(_showLog ? 'Hide log' : 'Show log'),
      ),
      if (_showLog)
        Container(
          height: 220,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(border: Border.all(color: theme.dividerColor), borderRadius: BorderRadius.circular(8)),
          child: SelectionArea(
            child: ListView(children: [
              for (final l in session.log)
                Text(l.message, style: TextStyle(fontFamily: 'RobotoMono', fontSize: 12, color: l.error ? theme.colorScheme.error : null)),
            ]),
          ),
        ),
    ]);
  }
}
