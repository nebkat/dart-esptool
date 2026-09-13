import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:idftool/idftool.dart' show PartitionTable;

import 'pages/device_page.dart';
import 'pages/filesystem_page.dart';
import 'pages/firmware_page.dart';
import 'pages/inspect_page.dart';
import 'pages/nvs_page.dart';
import 'pages/oneclick_page.dart';
import 'pages/partitions_page.dart';
import 'session/device_session.dart';
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
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: _entry(),
    );
  }
}

/// One corner radius for everything. Material 3 rounds buttons and chips
/// far more than text fields; this puts them all on the text field's 4 px
/// so the toolbars read as one family.
ThemeData _theme(Brightness brightness) {
  const radius = 4.0;
  const shape = RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(radius)));
  final base = ThemeData(colorSchemeSeed: const Color(0xFF3A6EA5), brightness: brightness);
  return base.copyWith(
    filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(shape: shape)),
    elevatedButtonTheme: ElevatedButtonThemeData(style: ElevatedButton.styleFrom(shape: shape)),
    outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(shape: shape)),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(shape: shape)),
    segmentedButtonTheme: SegmentedButtonThemeData(style: SegmentedButton.styleFrom(shape: shape)),
    iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(shape: shape)),
    chipTheme: base.chipTheme.copyWith(shape: shape),
    cardTheme: base.cardTheme.copyWith(shape: shape),
    dialogTheme: base.dialogTheme.copyWith(shape: shape),
    menuTheme: MenuThemeData(style: MenuStyle(shape: WidgetStatePropertyAll(shape))),
    popupMenuTheme: base.popupMenuTheme.copyWith(shape: shape),
    inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(radius)))),
  );
}

/// The tools, as navigation destinations. Pages that need the idftool
/// library light up as it lands.
enum Tool {
  device('Device', Icons.memory),
  partitions('Partitions', Icons.table_chart_outlined),
  nvs('NVS', Icons.storage),
  filesystem('Files', Icons.folder_outlined),
  firmware('Firmware', Icons.system_update_alt),
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
  Tool _tool = Tool.device;
  String? _nvsPartition;
  String? _fsPartition;

  @override
  void dispose() {
    _session.dispose();
    super.dispose();
  }

  void _planTable(PartitionTable table, String source) {
    for (final note in _session.plan.stageTable(table, source: source)) {
      _session.addLog(note, error: true);
    }
    setState(() => _tool = Tool.partitions);
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
    setState(() => _tool = Tool.partitions);
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
          Tool.partitions => PartitionsPage(
              session: _session,
              onOpenNvs: (name) => setState(() {
                _nvsPartition = name;
                _tool = Tool.nvs;
              }),
              onOpenFilesystem: (name) => setState(() {
                _fsPartition = name;
                _tool = Tool.filesystem;
              }),
            ),
          Tool.nvs => NvsPage(key: ValueKey(_nvsPartition), session: _session, initialPartition: _nvsPartition),
          Tool.filesystem => FilesystemPage(key: ValueKey(_fsPartition), session: _session, initialPartition: _fsPartition),
          Tool.firmware => FirmwarePage(session: _session),
          Tool.inspect => InspectPage(session: _session, onPlanTable: _planTable, onPlanBundle: _planBundle),
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
