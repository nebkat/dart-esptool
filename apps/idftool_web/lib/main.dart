import 'package:flutter/material.dart';

import 'pages/device_page.dart';
import 'session/device_session.dart';
import 'widgets/log_panel.dart';

void main() {
  runApp(const IdfToolApp());
}

class IdfToolApp extends StatelessWidget {
  const IdfToolApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'idftool',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF3A6EA5), brightness: Brightness.light),
      darkTheme: ThemeData(colorSchemeSeed: const Color(0xFF3A6EA5), brightness: Brightness.dark),
      home: const HomeShell(),
    );
  }
}

/// The tools, as navigation destinations. Pages that need the idftool
/// library light up as it lands.
enum Tool {
  device('Device', Icons.memory),
  partitions('Partitions', Icons.table_chart_outlined),
  nvs('NVS', Icons.storage),
  firmware('Firmware', Icons.system_update_alt);

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
  Tool _tool = Tool.device;

  @override
  void dispose() {
    _session.dispose();
    super.dispose();
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
          Tool.device => DevicePage(session: _session),
          Tool.partitions => const _Pending('Partition table'),
          Tool.nvs => const _Pending('NVS'),
          Tool.firmware => const _Pending('Firmware'),
        };
        return Scaffold(
          appBar: AppBar(
            title: const Text('idftool'),
            actions: [
              if (_session.connected)
                Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: Chip(
                    avatar: const Icon(Icons.check_circle, size: 18, color: Colors.green),
                    label: Text(_session.chip?.name ?? ''),
                  ),
                ),
            ],
          ),
          body: Row(children: [
            NavigationRail(
              selectedIndex: _tool.index,
              labelType: NavigationRailLabelType.all,
              onDestinationSelected: (i) => setState(() => _tool = Tool.values[i]),
              destinations: [
                for (final t in Tool.values) NavigationRailDestination(icon: Icon(t.icon), label: Text(t.label)),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: Column(children: [
                Expanded(flex: 3, child: page),
                const Divider(height: 1),
                Expanded(flex: 1, child: LogPanel(session: _session)),
              ]),
            ),
          ]),
        );
      },
    );
  }
}

class _Pending extends StatelessWidget {
  const _Pending(this.what);
  final String what;

  @override
  Widget build(BuildContext context) => Center(child: Text('$what tools arrive with the idftool port.'));
}
