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

import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'account_join.dart';
import 'connector.dart';
import 'session_code_field.dart';
import 'update_check.dart';

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
  // The decided banner from the native side. The lobby used to map the raw
  // status to words itself, which meant it knew nothing about update phases:
  // a build ran for minutes behind a line reading "Connecting…". Both
  // surfaces ask SessionBanner now, so they cannot drift apart again.
  ({String label, int? progress, bool visible})? _banner;
  Timer? _statusTimer;
  // When the current "waiting for developer" stretch began (used to surface a
  // stale-saved-code hint after a grace period with no developer).
  DateTime? _waitingSince;
  bool _showWaitingHint = false;
  // Hidden QA entry: tap the footer 7× to open the fault-injection sheet.
  int _debugTaps = 0;

  /// This build's version, shown in the footer. Null until read.
  String? _installedVersion;
  bool _checkingUpdate = false;

  /// Whether the code field is on screen.
  ///
  /// Joining is how this is used now, so the code is a way in round the back:
  /// still there for a LAN with no account service, or a phone nobody wants
  /// joined to anything, but no longer the first thing a tester reads.
  bool _showCodeEntry = false;

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
    _collectLinkInvite();
    _readInstalledVersion();
  }

  /// Reads this build's version for the footer.
  ///
  /// A release APK carries the release version, stamped by the release
  /// workflow; a locally built one carries player/pubspec.yaml's. Either
  /// way the tester can say which player they are holding, which they could
  /// not do before.
  Future<void> _readInstalledVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() => _installedVersion = info.version);
    } catch (_) {
      // Not worth telling the tester about: the footer simply keeps its
      // version-less wording.
    }
  }

  /// Compares this build with the newest GitHub release, on request.
  ///
  /// Manual, never on a timer: a tester's phone may be on cellular, and the
  /// answer is only interesting when someone is asking.
  Future<void> _checkForUpdate() async {
    if (_checkingUpdate) return;
    setState(() => _checkingUpdate = true);
    final status = await checkForUpdate(
      installedVersion: () async =>
          _installedVersion ?? (await PackageInfo.fromPlatform()).version,
    );
    if (!mounted) return;
    setState(() => _checkingUpdate = false);
    _showUpdateResult(status);
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
        final decided = await _session.invokeMapMethod<String, Object?>(
          'banner',
        );
        if (!mounted) return;
        final s = decided?['status'] as String?;
        final banner = decided == null
            ? null
            : (
                label: decided['label'] as String? ?? '',
                progress: decided['progress'] as int?,
                visible: decided['visible'] as bool? ?? false,
              );
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
        if (s != _nativeStatus ||
            showHint != _showWaitingHint ||
            banner?.label != _banner?.label ||
            banner?.progress != _banner?.progress) {
          setState(() {
            _nativeStatus = s;
            _banner = banner;
            _showWaitingHint = showHint;
          });
        }
      } catch (_) {
        /* channel not ready yet */
      }
    });
  }

  /// Live status label + dot color for the brand row and session card.
  ///
  /// The words come from the native [SessionBanner], so an update in flight
  /// reads as an update here and not as a connection being made. Only the
  /// colour is decided locally — it is presentation, and the banner's style
  /// does not need to know this screen's palette.
  (String, Color) get _statusDisplay {
    if (!_active) return ('Ready to connect', _inkDim);
    return (
      _banner?.label ?? 'Connecting…',
      switch (_nativeStatus) {
        'connected' => _ok,
        'rejected' => _err,
        _ => _warn,
      },
    );
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

  /// Handles what the native side pushes to the lobby.
  Future<dynamic> lobbyChannelHandler(MethodCall call) async {
    if (call.method != 'inviteArrived' || !mounted) return null;
    final invite = parseAccountInvite('${call.arguments}');
    if (invite != null) await _onInvite(invite);
    return null;
  }

  /// Picks up an invitation that arrived as an `rhr://` link.
  ///
  /// Same payload a QR carries, so it lands on the same consent screen: the
  /// difference is only how it reached the phone. A link can travel however a
  /// team already talks, where a QR needs both people in one room.
  Future<void> _collectLinkInvite() async {
    const channel = MethodChannel('rhr/connector');
    // A link that arrives while the player is already open is pushed rather
    // than polled, since there is no launch to read it from. Named so the
    // connector screen can put it back when it leaves — it takes this same
    // channel over while it is open.
    channel.setMethodCallHandler(lobbyChannelHandler);
    final payload = await channel.invokeMethod<String>('pendingInvite');
    if (payload == null || !mounted) return;
    final invite = parseAccountInvite(payload);
    if (invite != null) await _onInvite(invite);
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
              const SizedBox(height: 10),
              // Two facts decide this: what they get, and that it is
              // reversible. Everything else was reassurance the tester has to
              // read before they can answer.
              const Text(
                'They can connect to this phone to test their app. '
                'Leave any time.',
                style: TextStyle(color: _inkDim, fontSize: 13.5, height: 1.4),
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
    // A rendezvous is a session name too, just not a typed one: it is derived
    // from the installation identity and never looks like `rhr-xxxx-…`.
    // Validating it as a code rejected the account path outright.
    if (!isValidRhrSessionCode(code) && !isRendezvousName(code)) {
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
                          'Scan the QR from your developer to let them test on '
                          'this phone. You stay in control — leave any time.',
                          style: TextStyle(
                            color: _inkDim,
                            fontSize: 14,
                            height: 1.45,
                          ),
                        ),
                        const SizedBox(height: 26),
                        _scanToJoin(),
                        const SizedBox(height: 14),
                        // Still one tap away, and deliberately so: this is the
                        // only way in when the account service cannot be
                        // reached, which is exactly when a buried alternative
                        // would hurt most.
                        if (_showCodeEntry)
                          SessionCodeField(
                            controller: _code,
                            actionLabel: 'Connect',
                            onSubmit: _connect,
                            onScanned: _onScanned,
                            onInvite: _onInvite,
                          )
                        else
                          Center(
                            child: TextButton(
                              onPressed: () =>
                                  setState(() => _showCodeEntry = true),
                              style: TextButton.styleFrom(
                                foregroundColor: _inkDim,
                              ),
                              child: const Text(
                                'Enter a session code instead',
                                style: TextStyle(fontSize: 13),
                              ),
                            ),
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
                                child: Text(
                                  // Which build is this? Nobody could answer
                                  // that from the phone before: every release
                                  // reported the same 0.1.0.
                                  _installedVersion == null
                                      ? 'rhr player · debug build'
                                      : 'rhr player $_installedVersion · debug',
                                  style: const TextStyle(
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
                                onTap: _checkForUpdate,
                                child: Text(
                                  _checkingUpdate ? 'Checking…' : 'Updates',
                                  style: const TextStyle(
                                    color: _hintColor,
                                    fontSize: 11,
                                    decoration: TextDecoration.underline,
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

  /// The front door: scan an invitation and this phone joins an account.
  Widget _scanToJoin() => FilledButton.icon(
    onPressed: () async {
      final raw = await Navigator.of(
        context,
      ).push<String>(MaterialPageRoute(builder: (_) => const ScannerScreen()));
      if (raw == null || !mounted) return;
      final invite = parseAccountInvite(raw);
      if (invite != null) {
        await _onInvite(invite);
        return;
      }
      // A session-code QR scanned here still works rather than being
      // rejected for arriving at the wrong button.
      final entry = parseSessionPayload(raw);
      _code.text = formatSessionCodeInput(entry.code);
      await _onScanned(entry);
    },
    icon: const Icon(Icons.qr_code_scanner_rounded, size: 22),
    label: const Text('Scan to connect'),
    style: FilledButton.styleFrom(
      backgroundColor: _violet,
      foregroundColor: Colors.white,
      padding: const EdgeInsets.symmetric(vertical: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      textStyle: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600),
    ),
  );

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
          restoreHandler: lobbyChannelHandler,
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
          ..._updateProgress(),
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

  /// The bar for an update in flight, or nothing.
  ///
  /// A player or app build runs for minutes on the developer's machine, and
  /// the transfer for a minute more. The lobby showed none of it — the phone
  /// had the phase all along and only the native overlay ever drew it, so a
  /// tester looking at this screen saw a session that had simply gone quiet.
  List<Widget> _updateProgress() {
    final banner = _banner;
    if (banner == null || !banner.visible) return const [];
    final progress = banner.progress;
    return [
      const SizedBox(height: 12),
      ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: LinearProgressIndicator(
          // A known size gives a real bar; a build gives a moving one.
          value: progress == null ? null : progress / 1000,
          minHeight: 4,
          backgroundColor: _surfaceHi,
          valueColor: const AlwaysStoppedAnimation(_violet),
        ),
      ),
    ];
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
    // The update phases. Seeing one for real costs a multi-minute build and
    // a transfer, which is too expensive for checking what a line of text
    // says — and every bug these replaced was what a line of text said.
    // "Payload: app" switches the wording between the two payload kinds.
    (Icons.schedule_rounded, 'Phase: outdated', 'phase-outdated'),
    (Icons.build_rounded, 'Phase: building', 'phase-building'),
    (Icons.cloud_upload_rounded, 'Phase: updating 37%', 'phase-updating'),
    (Icons.download_rounded, 'Phase: installing', 'phase-installing'),
    (
      Icons.touch_app_rounded,
      'Phase: confirm install',
      'phase-install-confirm',
    ),
    (Icons.check_circle_rounded, 'Phase: installed', 'phase-installed'),
    (Icons.error_rounded, 'Phase: update failed', 'phase-update-failed'),
    (Icons.phone_android_rounded, 'Payload: app', 'update-foreign'),
    (Icons.system_update_rounded, 'Payload: player', 'update-player'),
    (Icons.cleaning_services_rounded, 'Clear cached apps', 'clear-cache'),
    (Icons.refresh_rounded, 'Reset state', 'clear'),
  ];

  /// Says what the check found, and offers the release page when there is
  /// something to go and get.
  ///
  /// Opening the browser rather than downloading here is deliberate: the APK
  /// is over 100 MB, and Chrome already handles a transfer that size, with
  /// resume, better than a first attempt in this app would.
  void _showUpdateResult(UpdateStatus status) {
    final (title, body, showOpen) = switch (status) {
      UpToDate(:final version) => (
        'Up to date',
        'This phone is running the newest player ($version).',
        false,
      ),
      UpdateAvailable(:final installed, :final latest) => (
        'Update available',
        'This phone has $installed. The newest release is $latest.\n\n'
            'Opening the release page downloads the APK; Android will ask '
            'before installing it.',
        true,
      ),
      UpdateCheckFailed(:final reason) => ('Could not check', reason, false),
    };
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _surface,
        title: Text(title, style: const TextStyle(color: _ink, fontSize: 17)),
        content: Text(
          body,
          style: const TextStyle(color: _inkDim, fontSize: 14, height: 1.35),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            style: TextButton.styleFrom(foregroundColor: _inkDim),
            child: Text(showOpen ? 'Not now' : 'OK'),
          ),
          if (showOpen)
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                launchUrl(
                  Uri.parse(releasesPage),
                  mode: LaunchMode.externalApplication,
                );
              },
              style: TextButton.styleFrom(foregroundColor: _violet),
              child: const Text('Open releases'),
            ),
        ],
      ),
    );
  }

  void _showDebugSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _surface,
      // The phase entries make this taller than a short phone, and a sheet
      // that cannot reach its last row is a sheet missing those faults.
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
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
                leading: const Icon(
                  Icons.fingerprint,
                  color: _violet,
                  size: 20,
                ),
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
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text(id ?? 'unavailable')));
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
