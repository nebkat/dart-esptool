import 'package:flutter/material.dart';

import 'pages/device_page.dart';
import 'pages/firmware_page.dart';
import 'pages/nvs_page.dart';
import 'pages/partitions_page.dart';
import 'session/device_session.dart';
import 'widgets/connection_bar.dart';
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
          Tool.partitions => PartitionsPage(session: _session),
          Tool.nvs => NvsPage(session: _session),
          Tool.firmware => FirmwarePage(session: _session),
        };
        return Scaffold(
          appBar: AppBar(title: const Text('idftool')),
          body: Column(children: [
            ConnectionBar(session: _session),
            const Divider(height: 1),
            Expanded(
              flex: 3,
              child: Row(children: [
                NavigationRail(
                  selectedIndex: _tool.index,
                  labelType: NavigationRailLabelType.all,
                  onDestinationSelected: (i) => setState(() => _tool = Tool.values[i]),
                  destinations: [
                    for (final t in Tool.values) NavigationRailDestination(icon: Icon(t.icon), label: Text(t.label)),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: page),
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
