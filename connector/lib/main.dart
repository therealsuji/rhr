// rhr connector (M3, tier "connector"): tunnels a THIRD-party Flutter app's
// VM service to the dev's Mac over the relay — the target app contains no
// rhr code and is never rebuilt.
//
// Discovery: an embedded wireless-debugging ADB client (vendored from
// Shizuku, Apache-2.0 — see android/.../moe/shizuku/manager/adb/). Paired
// once with the phone's own adbd (loopback, any network), the connector
// reads the target's log as shell for the engine's VM door line, and the
// native RhrSessionService (bridge-android) tunnels it through the relay.
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
  final _pairCodeController = TextEditingController();
  final _pairPortController = TextEditingController();
  bool _loadingPrefs = true;
  bool _paired = false;
  bool _connected = false;
  bool _discoveringPort = false;
  bool _pairing = false;
  bool _connecting = false;
  String _status = 'idle';
  List<Map<String, String>> _apps = const [];

  @override
  void initState() {
    super.initState();
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'progress') {
        setState(() => _status = call.arguments as String? ?? _status);
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
    await _refresh();
  }

  Future<void> _refresh() async {
    try {
      final state =
          await _channel.invokeMapMethod<String, bool>('setupState');
      if (!mounted) return;
      setState(() {
        _paired = state?['paired'] == true;
        _connected = state?['connected'] == true;
      });
      if (_connected && _apps.isEmpty && !_connecting) await _loadApps();
    } on PlatformException {
      // The wizard stays; the user can retry.
    }
  }

  /// Polls setupState while the user completes a Shizuku-free setup step.
  void _poll() {
    var ticks = 0;
    Timer.periodic(const Duration(milliseconds: 1200), (timer) {
      ticks++;
      if (ticks > 40 || !mounted) {
        timer.cancel();
        return;
      }
      _refresh().then((_) {
        if (_paired && _connected && timer.isActive) timer.cancel();
      });
    });
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('relay', _relayController.text.trim());
    await prefs.setString('code', _codeController.text.trim());
  }

  Future<void> _discoverPairingPort() async {
    setState(() => _discoveringPort = true);
    try {
      final port = await _channel.invokeMethod<int>('discoverPairingPort');
      setState(() {
        _status = port != null && port > 0
            ? 'pairing port found: $port — tap Pair'
            : 'pairing port not found — type it from the pairing dialog';
      });
      if (port != null && port > 0) {
        _pairPortController.text = port.toString();
      }
    } finally {
      if (mounted) setState(() => _discoveringPort = false);
    }
  }

  Future<void> _pair() async {
    final code = _pairCodeController.text.trim();
    final portText = _pairPortController.text.trim();
    final port = portText.isNotEmpty ? int.tryParse(portText) ?? -1 : (-1);
    if (code.length < 6 || port <= 0) {
      setState(() {
        _status = code.length < 6
            ? 'enter the 6-digit pairing code'
            : 'pairing port unknown — tap "find pairing port"';
      });
      return;
    }
    setState(() => _pairing = true);
    try {
      final ok = await _channel.invokeMethod<bool>(
        'pair',
        {'host': '127.0.0.1', 'port': port, 'code': code},
      );
      setState(() {
        _paired = ok == true;
        _status = ok == true ? 'paired ✓' : 'pairing failed — check the code';
      });
      await _refresh();
    } on PlatformException catch (e) {
      setState(() => _status = 'pairing failed: ${e.message}');
    } finally {
      if (mounted) setState(() => _pairing = false);
    }
  }

  Future<void> _connectAdb() async {
    setState(() => _status = 'connecting to this phone (ADB)');
    try {
      final ok = await _channel.invokeMethod<bool>('connectAdb');
      setState(() {
        _connected = ok == true;
        _status = ok == true ? 'connected ✓' : 'connect failed — retry';
      });
      if (_connected) await _loadApps();
    } on PlatformException catch (e) {
      setState(() => _status = 'connect failed: ${e.message}');
    }
  }

  Future<void> _loadApps() async {
    final apps = await _channel.invokeListMethod<Map<Object?, Object?>>(
        'listApps');
    setState(() {
      _apps = apps
          ?.map((e) => e.map((k, v) => MapEntry(k.toString(), v.toString())))
          .toList() ??
          const [];
      _status = _apps.isEmpty
          ? 'no third-party apps found'
          : 'pick the app to tunnel';
    });
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
    } on PlatformException catch (e) {
      setState(() {
        _connecting = false;
        _status = 'failed: ${e.message}';
      });
    }
  }

  @override
  void dispose() {
    _relayController.dispose();
    _codeController.dispose();
    _pairCodeController.dispose();
    _pairPortController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loadingPrefs) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('rhr connector')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_status,
                  style: Theme.of(context).textTheme.bodyMedium),
            ),
          ),
          const SizedBox(height: 12),
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
          if (!_paired) ..._pairWizard(),
          if (_paired && !_connected) ..._connectCard(),
          if (_connected && !_connecting) ..._appPicker(),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  List<Widget> _pairWizard() {
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('1. Pair with this phone',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              const Text(
                  '1. Tap "Open Wireless Debugging" below\n'
                  '2. Tap "Pair device with pairing code"\n'
                  '3. A dialog shows a 6-digit code — STAY on that screen\n'
                  '4. Use the RECENTS button (not back) to switch back here\n'
                  '5. Type the code below and tap Pair'),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => _channel.invokeMethod('openWirelessDebugging'),
                icon: const Icon(Icons.settings),
                label: const Text('Open Wireless Debugging'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _discoveringPort ? null : _discoverPairingPort,
                icon: const Icon(Icons.search),
                label: Text(_discoveringPort
                    ? 'Finding pairing port…'
                    : 'Find pairing port'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _pairCodeController,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: const InputDecoration(
                  labelText: '6-digit pairing code'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _pairPortController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Pairing port',
                  hintText: 'from the pairing dialog (e.g. 39525)',
                  helperText: 'shown below the code in the pairing dialog'),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _pairing ? null : _pair,
                icon: const Icon(Icons.key),
                label: Text(_pairing ? 'Pairing…' : 'Pair'),
              ),
            ],
          ),
        ),
      ),
    ];
  }

  List<Widget> _connectCard() {
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('2. Connect',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              const Text('Open an ADB connection to this phone.'),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _connectAdb,
                icon: const Icon(Icons.link),
                label: const Text('Connect'),
              ),
            ],
          ),
        ),
      ),
    ];
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
      Text('3. Pick the Flutter app to tunnel',
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
}
