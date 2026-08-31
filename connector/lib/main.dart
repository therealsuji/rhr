// rhr connector (M3, tier "connector"): tunnels a THIRD-party Flutter app's
// VM service to the dev's Mac over the relay — the target app contains no
// rhr code and is never rebuilt.
//
// Discovery: Shizuku shell powers (granted once via the wireless-debugging
// pairing) let the connector read the target's log, where the engine prints
// its VM service door. mDNS proved unreliable across networks, so shell is
// the primary — and only — discovery path (see notes/PHASE2_BUILD_PLAN.md).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _channel = MethodChannel('rhr/connector');
const _defaultRelay = 'wss://rhr-relay.codeforge007.workers.dev';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ConnectorApp());
}

class ConnectorApp extends StatelessWidget {
  const ConnectorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'rhr connector',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const ConnectorHome(),
    );
  }
}

class ConnectorHome extends StatefulWidget {
  const ConnectorHome({super.key});

  @override
  State<ConnectorHome> createState() => _ConnectorHomeState();
}

class _ConnectorHomeState extends State<ConnectorHome> {
  final _relayController = TextEditingController();
  final _codeController = TextEditingController();
  bool _loadingPrefs = true;
  Map<String, bool>? _shizuku; // managerInstalled / serverRunning / permission
  List<Map<String, String>> _apps = const [];
  bool _connecting = false;
  String _status = 'idle';
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'progress') {
        setState(() => _status = call.arguments as String? ?? _status);
      } else if (call.method == 'setupChanged') {
        await _refreshShizuku();
      }
    });
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _relayController.text = prefs.getString('relay') ?? _defaultRelay;
      _codeController.text = prefs.getString('code') ?? '';
      _loadingPrefs = false;
    });
    await _refreshShizuku();
  }

  Future<void> _refreshShizuku() async {
    if (_connecting) return;
    try {
      final state =
          await _channel.invokeMapMethod<String, bool>('setupState');
      if (!mounted) return;
      setState(() => _shizuku = state);
      final ready = state != null &&
          state['managerInstalled'] == true &&
          state['serverRunning'] == true &&
          state['permission'] == true;
      if (ready && _apps.isEmpty && !_connecting) await _loadApps();
    } on PlatformException {
      // Keep the wizard showing; the user can retry.
    }
  }

  Future<void> _loadApps() async {
    final apps = await _channel.invokeListMethod<Map<Object?, Object?>>(
        'listApps');
    setState(() {
      _apps = (apps
              ?.map((e) => e.map((k, v) => MapEntry(k.toString(), v.toString())))
              .toList() ??
              const [])
          .where((app) => app['debuggable'] == 'true')
          .toList();
      _status = _apps.isEmpty
          ? 'no third-party apps found'
          : 'pick the app to tunnel';
    });
  }

  /// Drives the wizard: polls setupState while the user completes the
  /// Shizuku step they're on.
  void _pollShizuku() {
    _poll?.cancel();
    var ticks = 0;
    _poll = Timer.periodic(const Duration(milliseconds: 1500), (timer) async {
      ticks++;
      await _refreshShizuku();
      final ready = _shizuku?['managerInstalled'] == true &&
          _shizuku?['serverRunning'] == true &&
          _shizuku?['permission'] == true;
      if (ready || ticks > 40) timer.cancel();
    });
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('relay', _relayController.text.trim());
    await prefs.setString('code', _codeController.text.trim());
  }

  Future<void> _connect(String pkg, String label) async {
    if (_connecting) return;
    final relay = _relayController.text.trim();
    final code = _codeController.text.trim();
    if (relay.isEmpty || code.isEmpty) {
      setState(() => _status = 'relay and session code are required');
      return;
    }
    await _persist();
    setState(() {
      _connecting = true;
      _status = 'locating the debug door of $label…';
    });
    try {
      // The native service owns the tunnel from here: it survives the
      // connector being backgrounded or the screen turning off.
      await _channel.invokeMethod('connectTarget', {
        'package': pkg,
        'relay': relay,
        'code': code,
      });
      setState(() {
        _connecting = false;
        _status = 'tunneling $label — the developer can hot reload with '
            'code $code';
      });
    } catch (e) {
      setState(() {
        _connecting = false;
        _status = 'failed: $e';
      });
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _relayController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loadingPrefs) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final shizuku = _shizuku ?? const {};
    return Scaffold(
      appBar: AppBar(title: const Text('rhr connector')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _relayController,
            decoration: const InputDecoration(
              labelText: 'Relay URL', hintText: _defaultRelay),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _codeController,
            decoration: const InputDecoration(
              labelText: 'Session code',
              hintText: 'rhr-xxxx-xxxx-xxxx',
              helperText: 'the developer attaches with this code'),
          ),
          const SizedBox(height: 20),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_status,
                  style: Theme.of(context).textTheme.bodyMedium),
            ),
          ),
          const SizedBox(height: 12),
          ..._shizukuWizard(shizuku),
          if (_shizuku?['permission'] == true) ..._appPicker(),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  List<Widget> _shizukuWizard(Map<String, bool> state) {
    final cards = <Widget>[];
    if (state['managerInstalled'] != true) {
      cards.add(_wizardCard(
        icon: Icons.download,
        title: '1. Install Shizuku',
        body: 'One-time. Bundled in this app — the system shows an install '
            'sheet you confirm.',
        action: 'Install Shizuku',
        onAction: () {
          _channel.invokeMethod('installShizuku');
          _pollShizuku();
        },
      ));
    } else if (state['serverRunning'] != true) {
      cards.add(_wizardCard(
        icon: Icons.play_circle,
        title: '2. Start Shizuku',
        body: 'Open Shizuku and tap Start. If it asks to pair, follow its '
            'wizard (Wireless debugging → pairing code) — one time only.',
        action: 'Open Shizuku',
        onAction: () {
          _channel.invokeMethod('openShizuku');
          _pollShizuku();
        },
      ));
    } else if (state['permission'] != true) {
      cards.add(_wizardCard(
        icon: Icons.verified_user,
        title: '3. Allow the connector',
        body: 'One permission dialog so the connector can read debug logs.',
        action: 'Grant permission',
        onAction: () {
          _channel.invokeMethod('requestPermission');
          _pollShizuku();
        },
      ));
    }
    return cards;
  }

  List<Widget> _appPicker() {
    if (_connecting) {
      return [
        Card(
          child: ListTile(
            leading: const CircularProgressIndicator(),
            title: Text(_status),
          ),
        ),
      ];
    }
    return [
      Text('Pick the Flutter app to tunnel',
          style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      for (final app in _apps)
        Card(
          child: ListTile(
            title: Text(app['label'] ?? app['package'] ?? '?'),
            subtitle: Text(app['package'] ?? ''),
            trailing: (app['debuggable'] == 'true')
                ? const Icon(Icons.bug_report, color: Colors.green)
                : const Icon(Icons.block, color: Colors.grey),
            onTap: () => _connect(app['package'] ?? '', app['label'] ?? ''),
          ),
        ),
    ];
  }

  Widget _wizardCard({
    required IconData icon,
    required String title,
    required String body,
    required String action,
    required VoidCallback onAction,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon),
              const SizedBox(width: 8),
              Expanded(child: Text(title,
                  style: Theme.of(context).textTheme.titleMedium)),
            ]),
            const SizedBox(height: 8),
            Text(body),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: onAction,
              icon: const Icon(Icons.arrow_forward),
              label: Text(action),
            ),
          ],
        ),
      ),
    );
  }
}
