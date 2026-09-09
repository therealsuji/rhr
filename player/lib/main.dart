// rhr player: one generic install that can run any Flutter project.
//
// Boots to a lobby, takes a session code, and starts the NATIVE session
// service (RhrSessionService) over a MethodChannel. The service owns the
// tunnel: it must live outside the Dart world because a guest app's hot
// restart swaps the entire kernel — including any Dart-side bridge — and a
// foreground service also survives Android freezing the backgrounded app.
//
// The dev then runs `rhr attach --sync-assets` from THEIR project; flutter's
// DevFS sync pushes the kernel, the asset push lands in the service's
// persistent store via the DevFS symlink, and a hot restart (R) boots the
// guest in place of this lobby.

import 'dart:async';
import 'dart:developer' show Service;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:rhr_bridge/session_code.dart';
import 'package:rhr_bridge/relay_defaults.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account_join.dart';
import 'connector.dart';
import 'session_code_field.dart';

const _relayUrl = String.fromEnvironment(
  'RHR_RELAY',
  defaultValue: defaultPublicRelay,
);
// In direct mode, the relay carries control messages only. Set RHR_DIRECT=false
// only when using an explicitly private or local relay for payload transport.
const _preferDirect = bool.fromEnvironment('RHR_DIRECT', defaultValue: true);

const _session = MethodChannel('rhr/session');
const _violetColor = Color(0xFF7C4DFF);
const _hintColor = Color(0xFF5A4E80);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PlayerApp());
}

class PlayerApp extends StatelessWidget {
  const PlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RHR Player',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: _violetColor,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const LobbyScreen(),
    );
  }
}

class LobbyScreen extends StatefulWidget {
  const LobbyScreen({super.key});

  @override
  State<LobbyScreen> createState() => _LobbyScreenState();
}

class _LobbyScreenState extends State<LobbyScreen> with WidgetsBindingObserver {
  final _code = TextEditingController();
  String? _status;
  bool _active = false; // a session is running → show Disconnect
  // Live native service status, polled over the MethodChannel so the lobby
  // shows the same truth as the native overlay.
  String? _nativeStatus;
  Timer? _statusTimer;
  // When the current "waiting for developer" stretch began (used to surface a
  // stale-saved-code hint after a grace period with no developer).
  DateTime? _waitingSince;
  bool _showWaitingHint = false;
  // Hidden QA entry: tap the footer 7× to open the fault-injection sheet.
  int _debugTaps = 0;

  // Design tokens matching the native DevOverlay.
  static const _violet = _violetColor;
  static const _ink = Color(0xFFF3F1FA);
  static const _inkDim = Color(0xFFA79FC4);
  static const _surface = Color(0xFF1A1330);
  static const _surfaceHi = Color(0xFF2E2350);
  static const _ok = Color(0xFF4ADE80);
  static const _warn = Color(0xFFFBBF24);
  static const _err = Color(0xFFF87171);
  // Relay for the current session. Defaults to the baked-in relay; a scanned QR
  // can point the player at a different relay (encoded alongside the code).
  String _relay = _relayUrl;
  List<String> _fallbackRelays = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pollStatus();
    SharedPreferences.getInstance().then((prefs) {
      final saved = prefs.getString('rhr_session_code');
      final savedRelays = prefs.getStringList('rhr_relay_urls');
      final autoResume = prefs.getBool('rhr_auto_resume') ?? true;
      if (saved != null && _code.text.isEmpty) {
        setState(() {
          _code.text = saved;
          if (savedRelays != null && savedRelays.isNotEmpty) {
            _relay = savedRelays.first;
            _fallbackRelays = savedRelays.skip(1).toList(growable: false);
          }
        });
        // Auto-resume: Android reaps backgrounded players (memory pressure,
        // crash, reboot); on relaunch, re-arm the session unprompted so a
        // mid-QA process death is invisible to the tester — the dev's CLI
        // reconnect loop is already retrying and just needs the device back.
        if (autoResume && saved.length >= 16) {
          _connect(auto: true);
        }
        return;
      }
      // No saved code, but this phone may have joined an account — then it
      // waits on its own rendezvous instead, so a developer who picks it from
      // their device list finds it already there. A phone that has joined
      // nothing stays on the lobby, which is what keeps the code path whole.
      _waitOnAccountRendezvous();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _statusTimer?.cancel();
    _code.dispose();
    super.dispose();
  }

  /// Keeps the lobby's status line in sync with the native service.
  void _pollStatus() {
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!mounted) return;
      try {
        final s = await _session.invokeMethod<String>('status');
        if (!mounted) return;
        final waiting = _active && s == 'waiting_dev';
        if (waiting) {
          _waitingSince ??= DateTime.now();
        } else {
          _waitingSince = null;
        }
        final showHint =
            waiting &&
            _waitingSince != null &&
            DateTime.now().difference(_waitingSince!) >=
                const Duration(seconds: 90);
        if (s != _nativeStatus || showHint != _showWaitingHint) {
          setState(() {
            _nativeStatus = s;
            _showWaitingHint = showHint;
          });
        }
      } catch (_) {
        /* channel not ready yet */
      }
    });
  }

  /// Live status label + dot color for the brand row and session card.
  (String, Color) get _statusDisplay {
    if (!_active) return ('Ready to connect', _inkDim);
    switch (_nativeStatus) {
      case 'connected':
        return ('Developer attached', _ok);
      case 'waiting_dev':
        return ('Waiting for developer', _warn);
      case 'rejected':
        return ('Session not found', _err);
      case 'retrying':
      case 'closed':
        return ("Can't reach relay", _warn);
      default:
        return ('Connecting…', _warn);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Pass the current VM URI along: iOS has no logcat watcher, so the
      // native service re-announces from this. Android ignores the arg and
      // discovers the URI from logcat itself.
      final vm = Service.getInfo();
      vm.then(
        (info) => _session.invokeMethod('kick', {
          'vmUri': (info.serverUri ?? Uri.parse('http://127.0.0.1:0/'))
              .toString(),
        }),
      );
    }
  }

  /// Waits on this phone's own rendezvous, when it belongs to an account.
  ///
  /// Nobody types anything for this: the name comes from the installation
  /// identity, and a developer who was invited computes the same one. Doing
  /// nothing when no account has been joined is deliberate — a phone that has
  /// joined nothing must still reach the code path.
  Future<void> _waitOnAccountRendezvous() async {
    if (!mounted) return;
    final accounts = await joinedAccounts();
    if (accounts.isEmpty || !mounted) return;
    final rendezvous = await ownRendezvous();
    if (rendezvous == null || !mounted) return;
    setState(() => _code.text = rendezvous);
    await _connect(auto: true);
    if (!mounted) return;
    setState(() {
      _status = accounts.length == 1
          ? 'Waiting for ${accounts.first.email}.'
          : 'Waiting for any of ${accounts.length} accounts.';
    });
  }

  /// Asks before joining, then joins.
  ///
  /// This phone usually belongs to the tester rather than the developer, so a
  /// scan must not quietly attach it to someone's account: the sheet names
  /// whose account it is and what joining allows, and does nothing until they
  /// accept.
  Future<void> _onInvite(AccountInvite invite) async {
    final accepted = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: _surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                invite.account.isEmpty
                    ? 'Join this account?'
                    : 'Join ${invite.account}?',
                style: const TextStyle(
                  color: _ink,
                  fontSize: 19,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'They will be able to see this phone in their device list and '
                'connect to it to test their app.\n\n'
                'They cannot see anything else on this phone, and you can '
                'leave at any time.',
                style: TextStyle(color: _inkDim, fontSize: 13.5, height: 1.45),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.of(sheetContext).pop(false),
                      style: TextButton.styleFrom(foregroundColor: _inkDim),
                      child: const Text('Not now'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.of(sheetContext).pop(true),
                      style: FilledButton.styleFrom(backgroundColor: _violet),
                      child: const Text('Join'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (accepted != true || !mounted) return;

    final outcome = await redeemInvite(invite);
    if (!mounted) return;
    setState(() {
      _status = switch (outcome) {
        JoinAccepted(:final account, alreadyJoined: true) =>
          'Already joined ${account.email}.',
        JoinAccepted(:final account) =>
          'Joined ${account.email}. They can now connect to this phone.',
        JoinRejected(:final reason) => reason,
      };
    });
  }

  /// A scan carries its own relay when the dev's QR named one; a typed code
  /// leaves whatever relay we already had in place.
  Future<void> _onScanned(SessionCodeEntry entry) async {
    setState(() {
      if (entry.relay != null) {
        _relay = entry.relay!;
        _fallbackRelays = entry.fallbackRelays;
      }
    });
    await _connect();
  }

  /// Stop the session and forget it: kills the native service, clears the saved
  /// code + auto-resume so the next launch starts clean at the lobby.
  Future<void> _disconnect() async {
    await _session.invokeMethod('stop');
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('rhr_session_code');
    await prefs.remove('rhr_relay_urls');
    if (!mounted) return;
    setState(() {
      _active = false;
      _code.clear();
      _relay = _relayUrl;
      _fallbackRelays = const [];
      _status = 'Disconnected. Scan a QR or enter a code to connect.';
    });
  }

  Future<void> _connect({bool auto = false}) async {
    final code = _code.text.trim();
    if (!isValidRhrSessionCode(code)) {
      if (!auto) {
        setState(
          () => _status =
              "That doesn't look like an rhr code — codes look like "
              'rhr-xxxx-xxxx-xxxx.',
        );
      }
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('rhr_session_code', code);
    await prefs.setStringList('rhr_relay_urls', [_relay, ..._fallbackRelays]);
    if (!kDebugMode) {
      setState(
        () => _status =
            'Release build — no VM service, hot reload cannot work. '
            'Install the debug player.',
      );
      return;
    }
    // Seed the service with whatever URI is available now; the native
    // service's logcat watcher discovers and re-announces the live URI on
    // its own, so an early/null value here self-corrects. On auto-resume the
    // engine may still be starting, so we don't block on it.
    final vm = (await Service.getInfo()).serverUri;
    await _session.invokeMethod('start', {
      'relayUrl': _relay,
      'relayUrls': [_relay, ..._fallbackRelays],
      'code': code,
      'vmUri': (vm ?? Uri.parse('http://127.0.0.1:0/')).toString(),
      'preferDirect': _preferDirect,
    });
    setState(() {
      _active = true;
      _status = auto
          ? 'Session restored — waiting for developer.\n'
                'Start rhr run on your machine and it will reconnect.'
          : 'Session service running — "$code". Waiting for developer.\n'
                'On your machine:\n'
                'rhr attach --sync-assets --relay $_relay --code $code\n'
                'then press R (hot restart) to boot your app here.\n'
                'The tunnel survives hot restarts and backgrounding.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final (statusLabel, statusColor) = _statusDisplay;
    return Scaffold(
      backgroundColor: const Color(0xFF0D0918),
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0.0, -0.7),
            radius: 1.2,
            colors: [Color(0xFF2B1B52), Color(0xFF0D0918)],
          ),
        ),
        child: SafeArea(
          // Scroll-safe layout: centered when it fits, scrolls when the
          // keyboard shrinks the viewport (fixes "BOTTOM OVERFLOWED").
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: constraints.maxHeight - 32,
                  ),
                  child: IntrinsicHeight(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            _chip('rhr', _violet),
                            const Spacer(),
                            _dot(statusColor),
                            const SizedBox(width: 7),
                            Flexible(
                              child: Text(
                                statusLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: _inkDim,
                                  fontSize: 12.5,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 40),
                        const Text(
                          'Stream your app\nstraight to this phone.',
                          style: TextStyle(
                            color: _ink,
                            fontSize: 27,
                            height: 1.18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'rhr plays any Flutter project over the internet. '
                          'Scan the QR from your terminal (rhr run) or enter a '
                          'code, then hot reload like the phone is plugged in.',
                          style: TextStyle(
                            color: _inkDim,
                            fontSize: 14,
                            height: 1.45,
                          ),
                        ),
                        const SizedBox(height: 26),
                        SessionCodeField(
                          controller: _code,
                          actionLabel: 'Connect',
                          onSubmit: _connect,
                          onScanned: _onScanned,
                          onInvite: _onInvite,
                        ),
                        const SizedBox(height: 18),
                        if (_active) _sessionCard() else _statusHint(),
                        const SizedBox(height: 18),
                        _connectorEntry(),
                        const SizedBox(height: 20),
                        Center(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              GestureDetector(
                                onTap: _onFooterTap,
                                child: const Text(
                                  'rhr player · debug build',
                                  style: TextStyle(
                                    color: _hintColor,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                              const Text(
                                ' · ',
                                style: TextStyle(
                                  color: _hintColor,
                                  fontSize: 11,
                                ),
                              ),
                              GestureDetector(
                                onTap: () => showLicensePage(context: context),
                                child: const Text(
                                  'Licenses',
                                  style: TextStyle(
                                    color: _hintColor,
                                    fontSize: 11,
                                    decoration: TextDecoration.underline,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  /// The second way to use the player: leave an already-installed app where
  /// it is and tunnel that instead of hosting a guest project here. Presented
  /// as a peer of the code entry above, not buried in a menu, because a user
  /// arriving with their own debug build has no reason to guess it exists.
  Widget _connectorEntry() => GestureDetector(
    onTap: () => Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ConnectorScreen(
          relay: _relay,
          fallbackRelays: _fallbackRelays,
        ),
      ),
    ),
    child: Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _surfaceHi),
      ),
      child: Row(
        children: [
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Connect an installed app',
                  style: TextStyle(
                    color: _ink,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Hot reload a debug build already on this phone, instead '
                  'of hosting a project here.',
                  style: TextStyle(color: _inkDim, fontSize: 12.5, height: 1.4),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          const Icon(Icons.chevron_right, color: _inkDim),
        ],
      ),
    ),
  );

  Widget _chip(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      text,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  Widget _dot(Color color) => Container(
    width: 8,
    height: 8,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );

  /// Live session card: code, status, and next step, plus Disconnect.
  Widget _sessionCard() {
    final (label, color) = _statusDisplay;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _surfaceHi),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _dot(color),
              const SizedBox(width: 8),
              const Text(
                'SESSION',
                style: TextStyle(
                  color: _inkDim,
                  fontSize: 11,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Flexible(
                child: Text(
                  _code.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _ink,
                    fontSize: 13,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            _activeStatusCopy(),
            style: const TextStyle(color: _ink, fontSize: 13.5, height: 1.35),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              if (_canReconnect)
                TextButton.icon(
                  onPressed: _reconnect,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Reconnect'),
                  style: TextButton.styleFrom(
                    foregroundColor: _violet,
                    padding: EdgeInsets.zero,
                  ),
                ),
              const Spacer(),
              TextButton.icon(
                onPressed: _disconnect,
                icon: const Icon(Icons.link_off, size: 16),
                label: const Text('Disconnect / reset'),
                style: TextButton.styleFrom(
                  foregroundColor: _err,
                  padding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Recoverable failures (can't reach relay / session not found) get an
  /// explicit Reconnect that interrupts the native backoff instead of waiting
  /// it out. Wired to the service's "kick" command.
  bool get _canReconnect =>
      _nativeStatus == 'retrying' ||
      _nativeStatus == 'closed' ||
      _nativeStatus == 'rejected';

  Future<void> _reconnect() async {
    try {
      await _session.invokeMethod('kick');
    } catch (_) {
      /* service may be gone */
    }
  }

  void _onFooterTap() {
    _debugTaps++;
    if (_debugTaps >= 7) {
      _debugTaps = 0;
      _showDebugSheet();
    }
  }

  /// QA fault-injection sheet: forces failure states so the
  /// state machine can be exercised on-device without breaking real hardware.
  static const _faults = [
    (Icons.wifi_off, 'Relay loss (close socket)', 'relay-loss'),
    (Icons.warning_amber_rounded, 'Force retrying', 'status-retrying'),
    (Icons.block_rounded, 'Force rejected', 'status-rejected'),
    (Icons.motion_photos_on_rounded, 'Stall reload phase', 'phase-reloading'),
    (Icons.cleaning_services_rounded, 'Clear cached apps', 'clear-cache'),
    (Icons.refresh_rounded, 'Reset state', 'clear'),
  ];

  void _showDebugSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Test faults',
                style: TextStyle(
                  color: _ink,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            // The installation identity is minted lazily and lives only in
            // native storage, so this is the one place a tester can read it
            // back — useful when an account says it does not recognise this
            // phone.
            ListTile(
              dense: true,
              leading: const Icon(Icons.fingerprint, color: _violet, size: 20),
              title: const Text(
                'Show installation id',
                style: TextStyle(color: _ink, fontSize: 14),
              ),
              onTap: () async {
                final id = await const MethodChannel(
                  'rhr/connector',
                ).invokeMethod<String>('installationId');
                if (!context.mounted) return;
                Navigator.of(context).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(id ?? 'unavailable')),
                );
              },
            ),
            for (final (icon, label, name) in _faults)
              ListTile(
                dense: true,
                leading: Icon(icon, color: _violet, size: 20),
                title: Text(
                  label,
                  style: const TextStyle(color: _ink, fontSize: 14),
                ),
                onTap: () {
                  _session.invokeMethod('debug/fault', {'name': name});
                  Navigator.of(context).pop();
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  String _activeStatusCopy() {
    switch (_nativeStatus) {
      case 'connected':
        return 'Developer attached — press r (reload) or R (restart) in their terminal.';
      case 'rejected':
        return 'No session on this code yet. Check the code, or ask the developer to run rhr run first.';
      case 'retrying':
      case 'closed':
        return "Can't reach the relay. Retrying every few seconds — "
            "check the phone's internet connection.";
      case 'waiting_dev':
      case 'idle':
      default:
        final base =
            'Waiting for developer — they can attach with:\n'
            'rhr attach --relay $_relay --code ${_code.text}';
        if (_showWaitingHint) {
          return '$base\n\nNo developer has connected on this code yet. '
              'If they started a fresh session, Disconnect and scan the new QR.';
        }
        return base;
    }
  }

  /// Non-active hint (e.g. a format error or "Disconnected").
  Widget _statusHint() {
    final msg = _status;
    if (msg == null) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _surfaceHi),
      ),
      child: Text(
        msg,
        style: const TextStyle(
          color: _inkDim,
          fontSize: 12.5,
          height: 1.4,
          fontFamily: 'monospace',
        ),
      ),
    );
  }
}
