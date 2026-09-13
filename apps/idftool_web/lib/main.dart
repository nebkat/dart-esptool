import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:idftool/idftool.dart' show PartitionTable;

import 'pages/data_page.dart';
import 'pages/flash_page.dart';
import 'pages/inspect_page.dart';
import 'pages/monitor_page.dart';
import 'pages/oneclick_page.dart';
import 'pages/partitions_page.dart';
import 'session/device_session.dart';
import 'util/files.dart';
import 'theme.dart';
import 'widgets/connection_bar.dart';
import 'widgets/log_panel.dart';

void main() {
  runApp(const IdfToolApp());
}

class IdfToolApp extends StatelessWidget {
  const IdfToolApp({super.key});

  /// `#/oneclick?bundle=<url>` opens the one-click flasher; anything else is
  /// the full tool. The fragment keeps it working on static hosts (GitHub
  /// Pages) with no server-side routing.
  static Widget _entry() {
    final fragment = Uri.base.fragment;
    final route = fragment.isEmpty ? null : Uri.tryParse(fragment.startsWith('/') ? fragment : '/$fragment');
    if (route != null && route.path == '/oneclick') {
      final bundle = route.queryParameters['bundle'];
      return OneClickShell(bundleUrl: bundle == null ? null : Uri.tryParse(bundle));
    }
    return const HomeShell();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'idftool',
      debugShowCheckedModeBanner: false,
      theme: appTheme(Brightness.light),
      darkTheme: appTheme(Brightness.dark),
      home: _entry(),
    );
  }
}

/// The tools, as navigation destinations. Pages that need the idftool
/// library light up as it lands.
enum Tool {
  partitions('Partitions', Icons.table_chart_outlined),
  flash('Flash', Icons.flash_on),
  data('Data', Icons.storage),
  monitor('Monitor', Icons.terminal),
  inspect('Inspect', Icons.search);

  const Tool(this.label, this.icon);
  final String label;
  final IconData icon;
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  final _session = DeviceSession();
  Tool _tool = Tool.partitions;
  String? _dataPartition;
  PickedFile? _dataFile;

  @override
  void dispose() {
    _session.dispose();
    super.dispose();
  }

  void _planTable(PartitionTable table, String source) {
    for (final note in _session.plan.stageTable(table, source: source)) {
      _session.addLog(note, error: true);
    }
    setState(() => _tool = Tool.flash);
  }

  void _planBundle(Uint8List zip, String name) {
    try {
      for (final note in _session.plan.loadBundle(zip, source: name)) {
        _session.addLog(note, error: true);
      }
    } on FormatException catch (e) {
      _session.addLog(e.message, error: true);
      return;
    }
    setState(() => _tool = Tool.flash);
  }

  @override
  Widget build(BuildContext context) {
    if (!DeviceSession.supported) {
      return const Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: Text('This tool needs the Web Serial API — open it in Chrome or Edge over https:// or localhost.'),
          ),
        ),
      );
    }
    return ListenableBuilder(
      listenable: _session,
      builder: (context, _) {
        final page = switch (_tool) {
          Tool.partitions => PartitionsPage(
              session: _session,
              onBrowse: (name) => setState(() {
                _dataPartition = name;
                _dataFile = null;
                _tool = Tool.data;
              }),
              onOpenFlash: () => setState(() => _tool = Tool.flash),
              onPlanTable: _planTable,
            ),
          Tool.flash => FlashPage(session: _session),
          Tool.data => DataPage(key: ValueKey((_dataPartition, _dataFile)), session: _session, initialPartition: _dataPartition, initialFile: _dataFile),
          Tool.monitor => MonitorPage(session: _session),
          Tool.inspect => InspectPage(
              session: _session,
              onPlanTable: _planTable,
              onPlanBundle: _planBundle,
              onOpenData: (file) => setState(() {
                _dataFile = file;
                _dataPartition = null;
                _tool = Tool.data;
              }),
            ),
        };
        return Scaffold(
          body: Column(children: [
            ConnectionBar(session: _session),
            const Divider(height: 1),
            Expanded(
              flex: 3,
              child: Row(children: [
                NavigationRail(
                  groupAlignment: 0,
                  selectedIndex: _tool.index,
                  labelType: NavigationRailLabelType.all,
                  onDestinationSelected: (i) => setState(() => _tool = Tool.values[i]),
                  destinations: [
                    for (final t in Tool.values) NavigationRailDestination(icon: Icon(t.icon), label: Text(t.label)),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    if (_session.monitoring && _tool != Tool.monitor && _tool != Tool.inspect)
                      MaterialBanner(
                        leading: const Icon(Icons.terminal),
                        content: const Text('The device is being monitored: it is running its app, so reading and flashing are unavailable until it is back in the bootloader.'),
                        actions: [
                          TextButton(onPressed: () => setState(() => _tool = Tool.monitor), child: const Text('Open monitor')),
                          FilledButton.tonal(
                            onPressed: _session.busy ? null : () => _session.stopMonitor(enterBootloader: true),
                            child: const Text('Enter bootloader'),
                          ),
                        ],
                      ),
                    Expanded(child: page),
                  ]),
                ),
              ]),
            ),
            const Divider(height: 1),
            Expanded(flex: 1, child: LogPanel(session: _session)),
          ]),
        );
      },
    );
  }
}

/// Owns a session for the one-click page, which has no rail, bar or log.
class OneClickShell extends StatefulWidget {
  const OneClickShell({super.key, this.bundleUrl});
  final Uri? bundleUrl;

  @override
  State<OneClickShell> createState() => _OneClickShellState();
}

class _OneClickShellState extends State<OneClickShell> {
  final _session = DeviceSession();

  @override
  void dispose() {
    _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: _session, builder: (context, _) => OneClickPage(session: _session, bundleUrl: widget.bundleUrl));
}
