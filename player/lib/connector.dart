// Connector mode: tunnel an app that is ALREADY INSTALLED on this phone,
// instead of hosting a guest project inside the player.
//
// The two modes differ in who owns the Dart VM. Hosted mode runs the guest's
// kernel inside this app, so the player's own VM service is the target.
// Connector mode leaves the target app alone: it pairs with this phone's own
// Wireless Debugging, reads the target's VM service URI out of its log, and
// points the native session service at that instead.
//
// Pairing is per-app, not per-phone: the RSA key adbd trusts lives in this
// app's private storage. A user who paired the standalone connector still
// pairs the player once — the trust cannot be shared.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:rhr_bridge/session_code.dart';

const _connector = MethodChannel('rhr/connector');
// The tunnel itself is still the native session service, shared with hosted
// mode; only target selection is connector-specific.
const _session = MethodChannel('rhr/session');

const _violet = Color(0xFF7C4DFF);
const _ink = Color(0xFFF3F1FA);
const _inkDim = Color(0xFFA79FC4);
const _surface = Color(0xFF1A1330);
const _surfaceHi = Color(0xFF2E2350);
const _ok = Color(0xFF4ADE80);
const _warn = Color(0xFFFBBF24);
const _err = Color(0xFFF87171);

/// One installed app the picker can offer.
class InstalledApp {
  const InstalledApp({
    required this.package,
    required this.label,
    required this.debuggable,
  });

  final String package;
  final String label;

  /// Only a debuggable build exposes a VM service, so only these can be
  /// tunneled. Non-debuggable apps are still listed, but explained and
  /// disabled — silently hiding them reads as "my app is missing".
  final bool debuggable;

  factory InstalledApp.fromMap(Map<Object?, Object?> map) => InstalledApp(
    package: (map['package'] as String?) ?? '',
    label: (map['label'] as String?) ?? 'App',
    debuggable: (map['debuggable'] as String?) == 'true',
  );
}

/// Where the connector flow currently stands. Modelled explicitly so the UI
/// can never claim a connection it does not have.
enum ConnectorStage {
  /// Player has never completed its own pairing.
  unpaired,

  /// Paired before, but adbd is not reachable right now (wireless debugging
  /// switched off, or the phone rebooted and the port moved).
  disconnected,

  /// Talking to adbd; the target list is usable.
  ready,

  /// Discovering a target's VM service, or starting the session.
  working,

  /// The native session service is tunneling a target.
  tunneling,
}

class ConnectorScreen extends StatefulWidget {
  const ConnectorScreen({
    super.key,
    required this.relay,
    required this.fallbackRelays,
  });

  final String relay;
  final List<String> fallbackRelays;

  @override
  State<ConnectorScreen> createState() => _ConnectorScreenState();
}

class _ConnectorScreenState extends State<ConnectorScreen>
    with WidgetsBindingObserver {
  final _code = TextEditingController();

  ConnectorStage _stage = ConnectorStage.disconnected;
  List<InstalledApp> _apps = const [];

  /// Whether the shake-to-open bubble can draw over the tester's own app.
  /// Not required to tunnel — the session works either way — so this is an
  /// offer, never a gate.
  bool _overlayGranted = true;
  String? _message;
  String? _failure;
  String? _tunneledLabel;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _connector.setMethodCallHandler(_onNative);
    _refreshSetup();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connector.setMethodCallHandler(null);
    _code.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Installing the app you want to tunnel, or switching wireless debugging
    // on, both happen OUTSIDE this screen. Re-reading on resume is what keeps
    // the list and the connection state from quietly going stale — otherwise
    // a freshly installed debug build simply never appears.
    if (state == AppLifecycleState.resumed &&
        _stage != ConnectorStage.tunneling) {
      _refreshSetup();
    }
  }

  Future<dynamic> _onNative(MethodCall call) async {
    if (!mounted) return null;
    switch (call.method) {
      case 'progress':
        // Discovery narrates itself; surfacing it is the difference between
        // "working…" and a screen that looks hung for 30 seconds.
        setState(() => _message = call.arguments as String?);
      case 'pairingDone':
        final ok = call.arguments == true;
        if (!ok) {
          setState(() {
            _stage = ConnectorStage.unpaired;
            _failure = 'Pairing did not complete. Check the six-digit code '
                'and try again.';
          });
          return null;
        }
        await _refreshSetup();
    }
    return null;
  }

  /// Asks the native side what it can actually do right now, rather than
  /// assuming the last known state still holds.
  Future<void> _refreshSetup() async {
    setState(() => _busy = true);
    try {
      final state = await _connector.invokeMapMethod<String, dynamic>(
        'setupState',
      );
      if (!mounted) return;
      final paired = state?['paired'] == true;
      final connected = state?['connected'] == true;
      final overlay =
          await _connector.invokeMethod<bool>('overlayGranted') ?? true;
      if (!mounted) return;
      _overlayGranted = overlay;
      setState(() {
        _busy = false;
        // A stale failure outliving the condition that caused it is its own
        // small lie: the user fixes wireless debugging, comes back, and still
        // reads "could not reach this phone".
        if (connected) _failure = null;
        if (!paired) {
          _stage = ConnectorStage.unpaired;
        } else if (connected) {
          _stage = ConnectorStage.ready;
        } else {
          _stage = ConnectorStage.disconnected;
        }
      });
      if (connected) await _loadApps();
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _failure = 'Could not read the pairing state: ${e.message}';
      });
    }
  }

  Future<void> _startPairing() async {
    setState(() {
      _failure = null;
      _message = 'Open Wireless debugging, tap "Pair device with pairing '
          'code", then type the six digits into the notification.';
    });
    try {
      await _connector.invokeMethod('startPairing');
      await _connector.invokeMethod('openWirelessDebugging');
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() => _failure = 'Could not start pairing: ${e.message}');
    }
  }

  Future<void> _connectAdb() async {
    setState(() {
      _busy = true;
      _failure = null;
      _message = 'Connecting to this phone…';
    });
    try {
      final ok = await _connector.invokeMethod<bool>('connectAdb');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = null;
        if (ok == true) {
          _stage = ConnectorStage.ready;
        } else {
          _failure = 'Could not reach this phone. Is Wireless debugging still '
              'switched on in Developer options?';
        }
      });
      if (ok == true) await _loadApps();
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _failure = 'Connection failed: ${e.message}';
      });
    }
  }

  Future<void> _loadApps() async {
    try {
      final apps = await _connector.invokeListMethod<Map<Object?, Object?>>(
        'listApps',
      );
      if (!mounted) return;
      setState(() {
        _apps = (apps ?? const [])
            .map(InstalledApp.fromMap)
            .toList(growable: false);
      });
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() => _failure = 'Could not list apps: ${e.message}');
    }
  }

  Future<void> _connectTarget(InstalledApp app) async {
    final code = _code.text.trim();
    if (!isValidRhrSessionCode(code)) {
      setState(
        () => _failure = "That doesn't look like an rhr code — codes look "
            'like rhr-xxxx-xxxx-xxxx.',
      );
      return;
    }
    setState(() {
      _stage = ConnectorStage.working;
      _failure = null;
      _message = 'Looking for ${app.label}…';
    });
    try {
      await _connector.invokeMethod('connectTarget', {
        'package': app.package,
        'relay': widget.relay,
        // Same fallback ordering hosted mode uses, so a scanned QR that
        // carries several relays behaves identically in either mode.
        'relayUrls': [widget.relay, ...widget.fallbackRelays],
        'code': code,
      });
      if (!mounted) return;
      setState(() {
        _stage = ConnectorStage.tunneling;
        _tunneledLabel = app.label;
        _message = null;
      });
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = ConnectorStage.ready;
        _message = null;
        _failure = e.code == 'no_vm'
            ? '${app.label} did not expose a debug connection. Only debug '
                  'builds can be hot reloaded — a Play Store build cannot.'
            : 'Could not connect: ${e.message}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0918),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: _ink,
        elevation: 0,
        title: const Text('Connect an installed app'),
        actions: [
          if (_stage == ConnectorStage.ready ||
              _stage == ConnectorStage.disconnected)
            IconButton(
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh),
              onPressed: _busy ? null : _refreshSetup,
            ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            _stageBanner(),
            const SizedBox(height: 16),
            if (_stage == ConnectorStage.unpaired) _pairingCard(),
            if (_stage == ConnectorStage.disconnected) _reconnectCard(),
            if (_stage == ConnectorStage.ready ||
                _stage == ConnectorStage.working) ...[
              _codeField(),
              if (!_overlayGranted) ...[
                const SizedBox(height: 16),
                _overlayOffer(),
              ],
              const SizedBox(height: 16),
              _targetList(),
            ],
            if (_stage == ConnectorStage.tunneling) _tunnelingCard(),
            if (_message != null) ...[
              const SizedBox(height: 16),
              Text(
                _message!,
                style: const TextStyle(color: _inkDim, fontSize: 13, height: 1.4),
              ),
            ],
            if (_failure != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: _err.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  _failure!,
                  style: const TextStyle(
                    color: _err,
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// One honest line about what is actually true right now.
  Widget _stageBanner() {
    final (label, color) = switch (_stage) {
      ConnectorStage.unpaired => ('This phone is not paired yet', _warn),
      ConnectorStage.disconnected => ('Paired, but not connected', _warn),
      ConnectorStage.ready => ('Connected to this phone', _ok),
      ConnectorStage.working => ('Working…', _warn),
      ConnectorStage.tunneling => (
        'Tunneling ${_tunneledLabel ?? 'app'}',
        _ok,
      ),
    };
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: TextStyle(color: color, fontSize: 13),
          ),
        ),
        if (_busy)
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: _inkDim),
          ),
      ],
    );
  }

  Widget _pairingCard() => _card(
    title: 'Pair this phone once',
    body: 'Connector mode talks to this phone\'s own Wireless debugging. '
        'Pairing is a one-time step and survives reboots.\n\n'
        'This is separate from any pairing you did in the standalone '
        'connector app: Android keeps the pairing key private to each app, '
        'so the player needs its own.',
    action: 'Start pairing',
    onAction: _startPairing,
  );

  Widget _reconnectCard() => _card(
    title: 'Reconnect to this phone',
    body: 'Pairing is already done. If Wireless debugging is switched on, '
        'reconnecting takes a moment and needs no code.',
    action: 'Reconnect',
    onAction: _busy ? null : _connectAdb,
  );

  Widget _tunnelingCard() => _card(
    title: 'Tunneling ${_tunneledLabel ?? 'the app'}',
    body: 'The session service owns the tunnel now and keeps running if you '
        'leave this screen.\n\nOn your machine:\n'
        'rhr attach --code ${_code.text.trim()}\n'
        'then hot reload as usual.',
    action: 'Stop and pick another app',
    onAction: () async {
      // The tunnel belongs to the native session service, which the session
      // channel owns — the connector channel only sets a target up.
      await _session.invokeMethod('stop');
      if (!mounted) return;
      setState(() {
        _stage = ConnectorStage.ready;
        _tunneledLabel = null;
      });
      await _refreshSetup();
    },
  );

  /// Offered, not enforced: tunneling works without it, you just lose the
  /// shake-to-open bubble once you are inside your own app.
  Widget _overlayOffer() => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: _surface,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: _surfaceHi),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Shake to check the session',
          style: TextStyle(
            color: _ink,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'While you are testing your own app, shake the phone to bring up a '
          'bubble showing the connection — and to disconnect without coming '
          'back here. Needs permission to draw over other apps.',
          style: TextStyle(color: _inkDim, fontSize: 12.5, height: 1.4),
        ),
        const SizedBox(height: 10),
        TextButton(
          style: TextButton.styleFrom(
            foregroundColor: _violet,
            padding: EdgeInsets.zero,
            minimumSize: const Size(0, 0),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          onPressed: () => _connector.invokeMethod('requestOverlay'),
          child: const Text('Turn it on'),
        ),
      ],
    ),
  );

  Widget _codeField() => TextField(
    controller: _code,
    style: const TextStyle(color: _ink),
    decoration: InputDecoration(
      labelText: 'Session code',
      hintText: 'rhr-xxxx-xxxx-xxxx',
      labelStyle: const TextStyle(color: _inkDim),
      hintStyle: const TextStyle(color: _hintFaded),
      filled: true,
      fillColor: _surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
    ),
  );

  Widget _targetList() {
    if (_apps.isEmpty) {
      return const Text(
        'No Flutter apps found on this phone. Only Flutter apps can be hot '
        'reloaded, so nothing else is listed.',
        style: TextStyle(color: _inkDim, fontSize: 13, height: 1.4),
      );
    }
    final debuggable = _apps.where((a) => a.debuggable).toList();
    final rest = _apps.where((a) => !a.debuggable).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (debuggable.isEmpty)
          const Text(
            'No Flutter debug builds installed. Only a debug build exposes '
            'the connection hot reload needs.',
            style: TextStyle(color: _inkDim, fontSize: 13, height: 1.4),
          )
        else ...[
          const Text(
            'Debug builds',
            style: TextStyle(color: _ink, fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          ...debuggable.map(_targetTile),
        ],
        if (rest.isNotEmpty) ...[
          const SizedBox(height: 20),
          const Text(
            'Cannot be hot reloaded',
            style: TextStyle(color: _inkDim, fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          ...rest.map(_targetTile),
        ],
      ],
    );
  }

  Widget _targetTile(InstalledApp app) {
    final enabled = app.debuggable && _stage == ConnectorStage.ready;
    return Opacity(
      opacity: app.debuggable ? 1 : 0.45,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: _surface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: ListTile(
          title: Text(app.label, style: const TextStyle(color: _ink)),
          subtitle: Text(
            app.debuggable ? app.package : '${app.package} · release build',
            style: const TextStyle(color: _inkDim, fontSize: 12),
          ),
          trailing: enabled
              ? const Icon(Icons.chevron_right, color: _inkDim)
              : null,
          onTap: enabled ? () => _connectTarget(app) : null,
        ),
      ),
    );
  }

  Widget _card({
    required String title,
    required String body,
    required String action,
    required Future<void> Function()? onAction,
  }) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: _surface,
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: _ink,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          body,
          style: const TextStyle(color: _inkDim, fontSize: 13, height: 1.45),
        ),
        const SizedBox(height: 14),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: _violet,
            disabledBackgroundColor: _surfaceHi,
          ),
          onPressed: onAction == null ? null : () => onAction(),
          child: Text(action),
        ),
      ],
    ),
  );
}

const _hintFaded = Color(0xFF5A4E80);
