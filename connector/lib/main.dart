// rhr connector (M3, tier "connector"): tunnels a THIRD-party Flutter app's
// VM service to the dev's Mac over the relay — the target app contains no
// rhr code and is never rebuilt.
//
// Discovery: an embedded wireless-debugging ADB client (vendored from
// Shizuku, Apache-2.0 — see android/.../moe/shizuku/manager/adb/). Paired
// ONCE with the phone's own adbd (loopback, any network), the connector
// reads the target's log as shell for the engine's VM door line, and the
// native RhrSessionService (bridge-android) tunnels it through the relay.
//
// Pairing is a ONE-TIME setup step: the ADB key trust it creates is
// permanent (reboots, network changes, wireless-debugging toggles). Every
// launch after it reconnects silently — the wizard never asks again.
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

class _ConnectorHomeState extends State<ConnectorHome>
    with WidgetsBindingObserver {
  final _relayController = TextEditingController();
  final _codeController = TextEditingController();
  bool _loadingPrefs = true;
  bool _paired = false;
  bool _connected = false;
  bool _pairing = false; // one-time pairing wizard in flight
  bool _adbConnecting = false; // silent ADB (re)connect in flight
  bool _connecting = false; // tunnel start in flight
  String _status = 'idle';
  List<Map<String, String>> _apps = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'progress') {
        setState(() => _status = call.arguments as String? ?? _status);
      } else if (call.method == 'pairingDone') {
        await _onPairingDone(call.arguments == true);
      }
    });
    _loadPrefs();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Returning from the settings screen (or anywhere) re-reads the
    // native state — the pairing may have completed while backgrounded.
    if (state == AppLifecycleState.resumed) _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _relayController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _relayController.text = prefs.getString('relay') ?? _defaultRelay;
      _codeController.text = prefs.getString('code') ?? '';
      _loadingPrefs = false;
    });
    await _refresh();
  }

  /// Reads the native state and drives the flow:
  ///   paired + connected → app picker;
  ///   paired, not connected → silent reconnect (the normal path on
  ///     every launch after the one-time pairing);
  ///   unpaired → the one-time pairing card.
  Future<void> _refresh() async {
    try {
      final state =
          await _channel.invokeMapMethod<String, bool>('setupState');
      if (!mounted) return;
      setState(() {
        _paired = state?['paired'] == true;
        _connected = state?['connected'] == true;
      });
      if (_paired && !_connected && !_adbConnecting && !_connecting) {
        await _connectAdb();
      } else if (_connected && _apps.isEmpty && !_connecting) {
        await _loadApps();
      }
    } on PlatformException {
      // The wizard stays; the user can retry.
    }
  }

  Future<void> _onPairingDone(bool ok) async {
    if (!mounted) return;
    setState(() {
      _pairing = false;
      _paired = _paired || ok;
      _status = ok
          ? 'paired ✓ — one-time setup complete'
          : "pairing didn't complete — pull down the notification and try again";
    });
    if (ok) await _connectAdb();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('relay', _relayController.text.trim());
    await prefs.setString('code', _codeController.text.trim());
  }

  /// Connects to this phone's own adbd. NO pairing involved — this
  /// reuses the key trust from the one-time pairing, silently.
  Future<void> _connectAdb() async {
    if (_adbConnecting) return;
    setState(() {
      _adbConnecting = true;
      _status = 'connecting to this phone…';
    });
    try {
      final ok = await _channel.invokeMethod<bool>('connectAdb');
      if (!mounted) return;
      setState(() {
        _adbConnecting = false;
        _connected = ok == true;
        _status = ok == true
            ? 'connected ✓'
            : 'connection failed — is Wireless debugging switched on?';
      });
      if (_connected) await _loadApps();
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _adbConnecting = false;
        _status = 'connect failed: ${e.message}';
      });
    }
  }

  Future<void> _loadApps() async {
    try {
      final apps = await _channel.invokeListMethod<Map<Object?, Object?>>(
          'listApps');
      if (!mounted) return;
      setState(() {
        _apps = apps
            ?.map((e) => e.map((k, v) => MapEntry(k.toString(), v.toString())))
            .toList() ??
            const [];
        _status = _apps.isEmpty
            ? 'no third-party apps found'
            : 'pick the app to tunnel';
      });
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() => _status = 'listing apps failed: ${e.message}');
    }
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
          if (!_paired) ..._pairCard(),
          if (_paired && !_connected) ..._connectCard(),
          if (_connected && !_connecting) ..._appPicker(),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  /// ONE-TIME. Shown only until the first successful pairing; the key
  /// trust makes this card disappear forever.
  List<Widget> _pairCard() {
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('1. Pair with this phone (one-time)',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              const Text(
                  'Tap Pair — the connector opens Wireless debugging and '
                  'posts a notification. Open "Pair device with pairing '
                  'code", pull down the notification, and type the '
                  '6-digit code there.\n\n'
                  'This authorization is permanent: after this you are '
                  'never asked again — not for new networks, not after '
                  'reboots.'),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _pairing ? null : _startPairing,
                icon: const Icon(Icons.key),
                label: Text(_pairing ? 'Pairing…' : 'Pair this phone'),
              ),
            ],
          ),
        ),
      ),
    ];
  }

  Future<void> _startPairing() async {
    setState(() => _pairing = true);
    try {
      await _channel.invokeMethod('startPairing');
      // Returns immediately — the result arrives later as a native
      // 'pairingDone' call, once the code entry over the settings
      // screen has completed (or failed).
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _pairing = false;
        _status = 'pairing failed to start: ${e.message}';
      });
    }
  }

  /// Paired but not connected: the automatic reconnect failed — almost
  /// always because Wireless debugging is switched off. Never asks for
  /// pairing again; a reconnect is all that's needed.
  List<Widget> _connectCard() {
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Connect to this phone',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              const Text(
                  'Pairing is already done — this is automatic and needs '
                  'no setup. It only fails when Wireless debugging is '
                  'switched off.'),
              const SizedBox(height: 12),
              if (_adbConnecting)
                const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: LinearProgressIndicator(),
                ),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _adbConnecting ? null : _connectAdb,
                    icon: const Icon(Icons.link),
                    label: const Text('Retry connection'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () =>
                        _channel.invokeMethod('openWirelessDebugging'),
                    icon: const Icon(Icons.settings),
                    label: const Text('Open Wireless debugging'),
                  ),
                ],
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
}
