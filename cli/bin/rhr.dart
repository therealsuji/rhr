// rhr attach --relay ws://host:8123 --code mysession [--project <dir>]
//            [--no-flutter] [--pid-file <path>] [--sync-assets]
//
// Connects to the relay as the dev end, waits for the device bridge's info
// message (the remote VM service URI), exposes a local TCP listener that
// tunnels to it, and spawns `flutter attach --debug-url` pointing at the
// local listener. With --no-flutter it just prints the URL (for DevTools or
// a manually run flutter attach).
//
// --sync-assets: for player-hosted sessions. `flutter attach` only syncs the
// kernel — it assumes the installed app already contains the project's asset
// bundle, which is false inside the universal player. This flag builds
// build/flutter_assets and pushes every file into the session's DevFS using
// the same wire protocol flutter run uses (HTTP PUT with dev_fs_name /
// dev_fs_uri_b64 headers, gzipped body), then triggers a hot restart so the
// engine picks the assets up.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import 'package:rhr_bridge/session_code.dart';
import 'package:rhr_bridge/tunnel.dart';
import 'package:rhr_cli/asset_sync.dart';
import 'package:rhr_cli/direct_session_transport.dart';
import 'package:rhr_cli/flutter_compatibility.dart';
import 'package:rhr_cli/local_relay.dart';
import 'package:rhr_cli/player_builder.dart';
import 'package:rhr_cli/player_update.dart';
import 'package:rhr_cli/relay_race.dart';
import 'package:rhr_cli/relay_config.dart';
import 'package:rhr_cli/restart_tracker.dart';
import 'package:rhr_cli/terminal_qr.dart';
import 'package:rhr_cli/usb_asset_transport.dart';
import 'package:rhr_cli/version.dart';
import 'package:rhr_cli/wrap.dart';

const _usage = '''
rhr — Expo Go for Flutter, over the internet.

Usage:
  rhr run [options]           run Flutter with automatic initial launch
  rhr attach [options]        connect to a session and hot reload into it
  rhr doctor                  check the local Flutter/RHR setup
  rhr --version               print the installed CLI version
  rhr push-assets [options]   push assets into an already-attached session
  rhr player build [options]  build a target-compatible debug player APK
  rhr wrap [options]          embed the tunnel into the app's own debug build
  (--deliver streams the APK to the rhr player over the relay: cable-free
   install — the player shows the system confirm sheet, one tap)

run options:
  --project <dir>       Flutter project dir (default: current dir)
  --relay <wss://...>   use a private/self-hosted relay (or .rhr.yaml)
  --code <session>      reuse a specific pairing code (default: generate one)
  --no-direct           use the relay for tunnel payloads (legacy/private mode;
                        direct WebRTC is strict and enabled by default)
  --resync              ignore the local asset manifest and re-push all assets
  --update-player       on version skew, rebuild and update the player without asking
  --no-update-player    on version skew, hard-block instead of offering an update

The player must already be installed. Flutter's normal terminal commands work:
  r to hot reload · R to hot restart · q to quit

player build options:
  --project <dir>       target Flutter project (default: current dir)
  --output <apk>        destination APK (default: build/rhr-player-debug.apk)
  --template <dir>      rhr player template (defaults to this repository/player)

attach options:
  --relay <wss://...>   use a private/self-hosted relay (or .rhr.yaml)
  --code <session>      session code, 16+ chars (or `code:` in .rhr.yaml)
  --project <dir>       Flutter project dir (default: current dir)
  --sync-assets         also push build/flutter_assets — required for the
                        generic player (its APK has no per-project assets)
  --resync              forget the pushed-asset manifest and re-push all
  --no-flutter          just print the tunneled VM URI; don't run flutter attach
  --no-direct           use the relay for tunnel payloads (legacy/private mode;
                        direct WebRTC is strict and enabled by default)
  --pid-file <path>     write the flutter process pid here
  -h, --help            show this help

Config: values in ./.rhr.yaml (keys `relay:`, `code:`, and optional
`direct: true|false`) are used as
defaults, so you can run just `rhr attach --sync-assets`. Command-line
flags override the file.
''';

// EX_TEMPFAIL: the relay was reachable, but no player joined this session.
// Retrying forever turns a typo into a silent background loop; callers can
// correct the code and start a fresh attach instead.
const _noDeviceExitCode = 75;
const _directFailureExitCode = 69;

Future<void> main(List<String> args) async {
  if (args.length == 1 &&
      (args.first == '--version' || args.first == 'version')) {
    stdout.writeln('rhr $rhrVersion');
    return;
  }

  if (args.isEmpty ||
      args.contains('-h') ||
      args.contains('--help') ||
      args.first == 'help') {
    stdout.write(_usage);
    exit(args.isEmpty ? 64 : 0);
  }

  if (args.first == 'doctor') {
    exit(await _doctor());
  }

  // rhr setup [--relay <wss://...>]
  // One-time: enable Flutter custom devices and register the `rhr` device so the
  // QA phone shows up in `flutter devices` / VS Code's device picker. After this
  // you just pick "rhr" and hit Run — save reloads the remote phone.
  if (args[0] == 'setup') {
    String? relay;
    for (var i = 1; i < args.length; i++) {
      if (args[i] == '--relay') relay = args[++i];
    }
    await _setup(relay);
    exit(0);
  }

  // rhr device-run --relay <wss://...> [--code <session>]
  // The custom device's runDebug command — delegate to the standalone helper so
  // there's a single implementation of the tunnel+QR handshake.
  if (args[0] == 'device-run') {
    await _deviceRun(args.sublist(1));
    exit(0);
  }

  if (args[0] == 'player') {
    if (args.length < 2 || args[1] != 'build') {
      stderr.writeln('usage: rhr player build [options]');
      exit(64);
    }
    String project = '.';
    String? output;
    String? template;
    for (var i = 2; i < args.length; i++) {
      switch (args[i]) {
        case '--project':
          project = args[++i];
        case '--output':
          output = args[++i];
        case '--template':
          template = args[++i];
        default:
          stderr.writeln('unknown arg: ${args[i]}');
          exit(64);
      }
    }
    final projectDirectory = Directory(project).absolute;
    output ??= '${projectDirectory.path}/build/rhr-player-debug.apk';
    template ??= await resolvePlayerTemplate();
    try {
      final apk = await buildProjectPlayer(
        project: projectDirectory.path,
        template: template,
        output: output,
      );
      stderr.writeln('[rhr] player APK: ${apk.path}');
      stderr.writeln('[rhr] install with: adb install -r ${apk.path}');
      exit(0);
    } catch (error) {
      stderr.writeln('[rhr] player build failed: $error');
      exit(1);
    }
  }

  // rhr wrap — tier-2: embed the tunnel into the app's own debug build with
  // zero edits to the app codebase (Gradle init script + AAR injection).
  if (args[0] == 'wrap') {
    String project = '.';
    String? relay;
    String? code;
    var verbatimId = false;
    var noInstall = false;
    var deliver = false;
    bool? direct;
    for (var i = 1; i < args.length; i++) {
      switch (args[i]) {
        case '--project':
          project = args[++i];
        case '--relay':
          relay = args[++i];
        case '--code':
          code = args[++i];
        case '--id':
          final value = args[++i];
          if (value == 'verbatim') {
            verbatimId = true;
          } else if (value != 'suffix') {
            stderr.writeln('unknown --id "$value" (suffix|verbatim)');
            exit(64);
          }
        case '--no-install':
          noInstall = true;
        case '--deliver':
          deliver = true;
        case '--direct':
          direct = true;
        case '--no-direct':
          direct = false;
        default:
          stderr.writeln('unknown arg: ${args[i]}');
          exit(64);
      }
    }
    try {
      final result = await wrapApp(
        WrapOptions(
          project: project,
          relay: relay,
          code: code,
          verbatimId: verbatimId,
          install: !noInstall && !deliver,
          deliver: deliver,
          preferDirect: direct,
        ),
      );
      stderr.writeln('[rhr] wrapped ✓ — open the app; it dials ${result.relay}');
      stderr.writeln('[rhr] then attach: rhr run --code ${result.code}');
      stderr.writeln('[rhr] session code is stable per project; '
          '--code/--relay override it');
      exit(0);
    } on WrapFailure catch (failure) {
      stderr.writeln('[rhr] wrap failed: $failure');
      exit(1);
    }
  }

  // Terminal-first product flow: build for Android, attach to the relayed VM,
  // sync assets, and automatically launch the guest app.
  if (args[0] == 'run') {    String project = '.';
    String? relay;
    String? code;
    var resync = false;
    bool? direct;
    var updatePolicy = PlayerUpdatePolicy.prompt;
    for (var i = 1; i < args.length; i++) {
      switch (args[i]) {
        case '--project':
          project = args[++i];
        case '--relay':
          relay = args[++i];
        case '--code':
          code = args[++i];
        case '--direct':
          direct = true;
        case '--no-direct':
          direct = false;
        case '--resync':
          resync = true;
        case '--update-player':
          updatePolicy = PlayerUpdatePolicy.always;
        case '--no-update-player':
          updatePolicy = PlayerUpdatePolicy.never;
        default:
          stderr.writeln('unknown arg: ${args[i]}');
          exit(64);
      }
    }
    exit(
      await _runAttachProductFlow(
        project: project,
        relay: relay,
        code: code,
        preferDirect: direct,
        resync: resync,
        updatePolicy: updatePolicy,
      ),
    );
  }

  // rhr push-assets --vm-url <tunneled-vm-uri> [--project <dir>] --pid-file <path>
  // Standalone asset push into an already-attached session.
  if (args.isNotEmpty && args[0] == 'push-assets') {
    String? vmUrl;
    String project = '.';
    String? pid;
    for (var i = 1; i < args.length; i++) {
      switch (args[i]) {
        case '--vm-url':
          vmUrl = args[++i];
        case '--project':
          project = args[++i];
        case '--pid-file':
          pid = args[++i];
        default:
          stderr.writeln('unknown arg: ${args[i]}');
          exit(64);
      }
    }
    if (vmUrl == null || pid == null) {
      stderr.writeln(
        'usage: rhr push-assets --vm-url <uri> --pid-file <path> [--project <dir>]',
      );
      exit(64);
    }
    await _syncAssetsAfterAttach(Uri.parse(vmUrl), project, pid);
    exit(0);
  }

  String? relay;
  String? code;
  String project = '.';
  String? pidFile;
  var runFlutter = true;
  var syncAssets = false;
  var resync = false;
  bool? direct;
  var updatePolicy = PlayerUpdatePolicy.prompt;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case 'attach':
        break;
      case '--relay':
        relay = args[++i];
      case '--code':
        code = args[++i];
      case '--project':
        project = args[++i];
      case '--no-flutter':
        runFlutter = false;
      case '--pid-file':
        pidFile = args[++i];
      case '--sync-assets':
        syncAssets = true;
      case '--resync':
        // Escape hatch when the device store and local manifest disagree
        // (e.g. app data cleared): forget what we think is on the device.
        resync = true;
      case '--direct':
        direct = true;
      case '--no-direct':
        direct = false;
      case '--update-player':
        updatePolicy = PlayerUpdatePolicy.always;
      case '--no-update-player':
        updatePolicy = PlayerUpdatePolicy.never;
      default:
        stderr.writeln('unknown arg: ${args[i]}');
        exit(64);
    }
  }
  // Fill unset relay/code from .rhr.yaml in the project dir (flags win), and
  // fall back to the public relay like `rhr run` does: the player dials it by
  // default, so a bare `rhr attach --code` should meet it there.
  final cfg = _loadConfig(project);
  relay ??= cfg['relay'] ?? defaultPublicRelay;
  code ??= cfg['code'];
  direct ??= cfg['direct']?.toLowerCase() != 'false';

  if (code == null) {
    stderr.writeln(
      'rhr attach: missing --code (set it as a flag or in .rhr.yaml).\n',
    );
    stderr.write(_usage);
    exit(64);
  }

  // Build the asset bundle BEFORE touching the relay: the build can take a
  // minute, and an idle dev WebSocket has been observed getting dropped
  // during it, killing the session before attach even starts.
  if (syncAssets) {
    stderr.writeln('[rhr] building asset bundle...');
    final build = await Process.run(projectFlutterExecutable(project), [
      'build',
      'bundle',
      '--debug',
      '--target-platform',
      'android-arm64',
    ], workingDirectory: project);
    if (build.exitCode != 0) {
      stderr.writeln('[rhr] flutter build bundle failed:\n${build.stderr}');
      exit(1);
    }
  }

  if (resync) {
    final m = File('$project/.dart_tool/rhr/pushed_assets.json');
    if (m.existsSync()) m.deleteSync();
  }

  // Session loop: a dropped relay connection tears down every tunnel channel
  // on both ends (the phone's service reconnects on its own), so we recover
  // by re-dialing, respawning flutter attach, and re-running the asset sync —
  // the manifest makes that seconds. flutter exiting on its own (q) ends us.
  var failures = 0;
  while (true) {
    try {
      final result = await _runSession(
        relays: [relay],
        code: code,
        project: project,
        pidFile: pidFile,
        runFlutter: runFlutter,
        syncAssets: syncAssets,
        preferDirect: direct,
        updatePolicy: updatePolicy,
      );
      // Clean flutter exit (user pressed q) => done. A nonzero exit is a
      // failed attach (e.g. the flaky first-connect DDS race) => reconnect.
      if (result == 0) exit(0);
      if (result == _noDeviceExitCode) exit(result!);
      if (result != null) {
        failures++;
        stderr.writeln('[rhr] flutter attach exited ($result)');
      } else {
        failures = 0;
      }
    } on DirectTransportFailure catch (failure) {
      stderr.writeln('[rhr] direct connection failed: $failure');
      exit(_directFailureExitCode);
    } on Exception catch (e) {
      failures++;
      stderr.writeln('[rhr] session error: $e');
    }
    final delay = Duration(seconds: (2 * (failures + 1)).clamp(2, 15));
    stderr.writeln(
      '[rhr] session dropped — reconnecting in ${delay.inSeconds}s '
      '(ctrl-c to quit)',
    );
    await Future<void>.delayed(delay);
  }
}

Future<int> _doctor() async {
  stdout.writeln('RHR doctor');
  stdout.writeln('[OK] rhr $rhrVersion');

  var healthy = true;
  try {
    final flutter = await Process.run('flutter', ['--version', '--machine']);
    if (flutter.exitCode != 0) {
      healthy = false;
      stdout.writeln('[FAIL] flutter exited with code ${flutter.exitCode}');
      final message = '${flutter.stderr}'.trim();
      if (message.isNotEmpty) stdout.writeln('       $message');
    } else {
      final metadata = jsonDecode('${flutter.stdout}');
      if (metadata is! Map<String, dynamic>) {
        throw const FormatException('unexpected flutter version output');
      }
      final version = metadata['frameworkVersion'] ?? 'unknown';
      final channel = metadata['channel'] ?? 'unknown channel';
      final dart = metadata['dartSdkVersion'] ?? 'unknown';
      stdout.writeln('[OK] Flutter $version ($channel), Dart $dart');
    }
  } on ProcessException catch (error) {
    healthy = false;
    stdout.writeln('[FAIL] flutter is not available on PATH');
    stdout.writeln('       ${error.message}');
  } on FormatException catch (error) {
    healthy = false;
    stdout.writeln('[FAIL] could not read the local Flutter version: $error');
  }

  try {
    final adb = await Process.run('adb', ['devices', '-l']);
    if (adb.exitCode == 0) {
      final devices = parseUsbAdbDevices('${adb.stdout}');
      if (devices.isEmpty) {
        stdout.writeln('[INFO] no physical USB device is connected');
      } else {
        stdout.writeln(
          '[OK] ${devices.length} physical USB device(s) connected; '
          'matching RHR Players can use the asset fast path',
        );
      }
    } else {
      stdout.writeln(
        '[INFO] adb could not list devices; wireless sync remains available',
      );
    }
  } on ProcessException {
    stdout.writeln(
      '[INFO] adb is not on PATH; wireless sync remains available',
    );
  }

  final pubspec = File('pubspec.yaml');
  if (pubspec.existsSync() &&
      RegExp(
        r'^\s+sdk:\s+flutter\s*$',
        multiLine: true,
      ).hasMatch(pubspec.readAsStringSync())) {
    stdout.writeln('[OK] current directory is a Flutter project');
  } else {
    stdout.writeln('[INFO] run `rhr run` from a Flutter project directory');
  }

  stdout.writeln(
    healthy ? '\nRHR is ready.' : '\nFix the failures above, then run again.',
  );
  return healthy ? 0 : 1;
}

/// Minimal `.rhr.yaml` reader: pulls the flat `relay:` / `code:` / `direct:`
/// keys so session defaults can live next to the project.
/// Deliberately not a real YAML parser (keeps the CLI dependency-free per the
/// repo convention) — it only understands `key: value` lines and `#` comments.
Map<String, String> _loadConfig(String project) {
  final f = File('$project/.rhr.yaml');
  if (!f.existsSync()) return const {};
  final out = <String, String>{};
  for (var line in f.readAsLinesSync()) {
    line = line.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final i = line.indexOf(':');
    if (i <= 0) continue;
    final key = line.substring(0, i).trim();
    var value = line.substring(i + 1).trim();
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1);
    }
    if (key == 'relay' || key == 'code' || key == 'direct') out[key] = value;
  }
  return out;
}

/// How `rhr` reacts when the compatibility gate blocks: offer an
/// over-the-wire player update, apply it without asking, or keep the
/// original hard block.
enum PlayerUpdatePolicy { prompt, always, never }

/// One relay session: tunnel + optional flutter attach + optional asset sync.
/// Returns flutter's exit code when it ends on its own, or null when the
/// relay connection dropped and the caller should reconnect.
Future<int?> _runSession({
  required List<String> relays,
  required String code,
  required String project,
  required String? pidFile,
  required bool runFlutter,
  required bool syncAssets,
  bool preferDirect = false,
  PlayerUpdatePolicy updatePolicy = PlayerUpdatePolicy.never,
}) async {
  final compatibility = readProjectCompatibilityProfile(project);
  String? assetStoreId;
  late final RelayRace relayTransport;
  try {
    relayTransport = await RelayRace.connect(relays: relays, code: code);
  } catch (e) {
    stderr.writeln('[rhr] could not connect to any relay for code "$code": $e');
    return null;
  }
  final SessionTransport transport = preferDirect
      ? DirectSessionTransport(relayTransport)
      : relayTransport;
  stderr.writeln('[rhr] connected to relay candidate(s): ${relays.join(', ')}');
  unawaited(
    relayTransport.selectedRelay.then<void>(
      (relay) => stderr.writeln(
        '[rhr] selected ${relay.startsWith('ws://127.0.0.1') ? 'LAN' : 'internet'} '
        'transport $relay (session $code)',
      ),
      onError: (_, _) {},
    ),
  );

  final vmReady = Completer<Uri>();
  final wsDied = Completer<void>();
  final sockets = <int, Socket>{};
  final flow = FlowControl();
  DirectTransportFailure? directFailure;
  final bridgeDeadline = _DeadlineHolder(
    DateTime.now().add(const Duration(minutes: 5)),
  );
  PlayerUpdateSender? updateSender;
  var updateAttempted = false;

  void sendPayload(Uint8List payload) {
    unawaited(
      transport.sendPayload(payload).catchError((
        Object error,
        StackTrace stack,
      ) {
        if (error is DirectTransportFailure) {
          directFailure ??= error;
          if (!wsDied.isCompleted) wsDied.complete();
        } else {
          stderr.writeln('[rhr] tunnel payload send failed: $error');
          if (!wsDied.isCompleted) wsDied.complete();
        }
      }),
    );
  }

  transport.stream.listen(
    (msg) {
      if (msg is String) {
        final m = jsonDecode(msg) as Map<String, dynamic>;
        if (updateSender?.handleMessage(m) ?? false) return;
        if (m['t'] == 'info' && !vmReady.isCompleted) {
          final announcedAssetStoreId = m['assetStoreId'];
          final announcedHost = m['host'] ??
              (m['compatibility'] is Map<String, dynamic>
                  ? (m['compatibility'] as Map<String, dynamic>)['host']
                  : null);
          final hostKind =
              announcedHost is String ? announcedHost : 'player';
          if (hostKind == 'connector') {
            // M3: the connector tunnels a THIRD-party app's VM service —
            // the target contains no rhr code, so there is no identity to
            // gate on and no player to update. The dev pushes its own
            // kernel, making the SDK question moot.
            final connectorVm = m['vm'];
            if (connectorVm is! String || connectorVm.isEmpty) {
              stderr.writeln(
                  '[rhr] connector announced no VM service — is the target '
                  'app a debug build?');
              exit(78);
            }
            assetStoreId =
                announcedAssetStoreId is String ? announcedAssetStoreId : '';
            vmReady.complete(Uri.parse(connectorVm));
            return;
          }
          final raw = m['compatibility'];
          if (announcedAssetStoreId is! String ||
              announcedAssetStoreId.isEmpty ||
              raw is! Map<String, dynamic>) {
            stderr.writeln(
              '[rhr] COMPATIBILITY_BLOCKED: reinstall a current rhr player; '
              'its runtime or asset-store identity is missing.',
            );
            exit(78);
          }
          assetStoreId = announcedAssetStoreId;
          final isWrappedApp = hostKind == 'app';
          final report = compatibility.differencesFrom(raw);
          for (final warning in report.warnings) {
            stderr.writeln('[rhr] note: $warning');
          }
          if (report.blockers.isNotEmpty) {
            // A wrapped app bakes its identity from the SDK that wrapped it.
            // Blockers mean the developer's SDK moved on since — the fix is a
            // rebuild, never a player update (there is no player to update).
            if (isWrappedApp || updateSender != null) {
              if (isWrappedApp) {
                stderr.writeln('[rhr] COMPATIBILITY_BLOCKED: the wrapped app '
                    'was built with a different rhr identity — rebuild it:');
                for (final difference in report.blockers) {
                  stderr.writeln('  - $difference');
                }
                stderr.writeln('[rhr] fix: rhr wrap (rebuilds the app with '
                    'this SDK, zero project edits)');
                exit(78);
              }
              return; // transfer already in flight
            }
            stderr.writeln('[rhr] COMPATIBILITY_BLOCKED:');
            for (final difference in report.blockers) {
              stderr.writeln('  - $difference');
            }
            if (updatePolicy == PlayerUpdatePolicy.never || updateAttempted) {
              stderr.writeln(
                updateAttempted
                    ? '[rhr] the player is still incompatible after the update.'
                    : '[rhr] Rebuild/reinstall a compatible player before '
                          'streaming.',
              );
              exit(78);
            }
            updateAttempted = true;
            unawaited(
              _updatePlayerOverTheWire(
                transport: transport,
                project: project,
                local: compatibility.flutter,
                policy: updatePolicy,
                deadline: bridgeDeadline,
                attach: (sender) => updateSender = sender,
              ).then((updated) {
                updateSender = null;
                if (!updated) exit(78);
              }),
            );
            return;
          }
          final vmValue = m['vm'];
          if (vmValue is! String || vmValue.isEmpty) {
            stderr.writeln(
              '[rhr] COMPATIBILITY_BLOCKED: player announced no VM service.',
            );
            exit(78);
          }
          vmReady.complete(Uri.parse(vmValue));
        }
        return;
      }
      final f = decodeFrame(msg as List<int>);
      switch (f.op) {
        case opData:
          sockets[f.channel]?.add(f.payload);
          sendPayload(encodeAck(f.channel, f.payload.length));
        case opAck:
          if (PlayerUpdateSender.isUpdateAck(f.channel)) {
            updateSender?.handleAck(f.channel, decodeAckCount(f.payload));
          } else {
            flow.acked(f.channel, decodeAckCount(f.payload));
          }
        case opClose:
          flow.forget(f.channel);
          sockets.remove(f.channel)?.destroy();
      }
    },
    onDone: () {
      // If the relay kicked us because another dev connected on this same code
      // (the "one dev per session" rule), reconnecting would just kick THEM and
      // start an endless slot-stealing fight. Detect that and stop instead.
      final reason = transport.closeReason ?? '';
      if (reason.contains('replaced')) {
        stderr.writeln(
          '[rhr] another rhr session took over code "$code" — '
          'exiting (only one dev can attach to a session at a time).',
        );
        exit(3);
      }
      stderr.writeln('[rhr] relay connection closed');
      if (!wsDied.isCompleted) wsDied.complete();
    },
    onError: (Object e) {
      if (e is DirectTransportFailure) {
        directFailure ??= e;
      } else {
        stderr.writeln('[rhr] relay error: $e');
      }
      if (!wsDied.isCompleted) wsDied.complete();
    },
  );

  // App-level keepalive that traverses the whole path (client ws pings only
  // reach the CF edge; idle Durable Object connections were observed being
  // killed at ~10 minutes). The device end treats it as a developer-presence
  // heartbeat: its watchdog expires if these stop for >45s.
  final keepalive = Timer.periodic(developerLeasePingInterval, (_) {
    try {
      transport.sendControl(jsonEncode({'t': 'ping'}));
    } catch (_) {
      // No relay has produced device info yet.
    }
  });

  stderr.writeln('[rhr] waiting for device bridge...');
  Uri? vm;
  try {
    vm = await _waitForDeviceBridge(vmReady, wsDied, code, bridgeDeadline);
  } on _WaitTimedOut {
    keepalive.cancel();
    await transport.close();
    stderr.writeln(
      '[rhr] no player joined session "$code" within 5 minutes. '
      'Check the code, scan the QR again, and rerun rhr attach.',
    );
    return _noDeviceExitCode;
  }
  if (vm == null) {
    keepalive.cancel();
    final failure = directFailure;
    if (failure != null) {
      await transport.close();
      throw failure;
    }
    return null; // relay died while waiting
  }
  stderr.writeln('[rhr] device VM service: $vm');

  try {
    await transport.payloadReady;
  } on DirectTransportFailure catch (failure) {
    keepalive.cancel();
    await transport.close();
    throw failure;
  }

  var nextChannel = 1;
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((sock) {
    final channel = nextChannel++;
    sockets[channel] = sock;
    // Socket write failures (peer reset mid-transfer) surface on `done`;
    // unhandled they crash the process.
    sock.done.catchError((_) {});
    sendPayload(encodeFrame(opOpen, channel));
    late final StreamSubscription<Uint8List> sub;
    sub = sock.listen(
      (data) {
        sendPayload(encodeFrame(opData, channel, data));
        // Pause the local reader once the window fills — this is what keeps
        // a fast dev machine from ballooning buffers inside the relay.
        if (flow.sent(channel, data.length)) {
          sub.pause();
          flow.onWindowOpen(channel, sub.resume);
        }
      },
      onDone: () {
        flow.forget(channel);
        if (sockets.remove(channel) != null) {
          sendPayload(encodeFrame(opClose, channel));
        }
      },
      onError: (Object error) {
        flow.forget(channel);
        if (sockets.remove(channel) != null) {
          sendPayload(encodeFrame(opClose, channel));
        }
      },
    );
  });

  final local = vm.replace(host: '127.0.0.1', port: server.port);
  stderr.writeln('[rhr] tunneled VM service: $local');

  Future<void> cleanup() async {
    keepalive.cancel();
    await server.close();
    for (final s in sockets.values.toList()) {
      s.destroy();
    }
    sockets.clear();
    // Farewell so the phone leaves "Connected" immediately instead of waiting
    // out its watchdog. Harmless if the socket already died (relay drop).
    try {
      transport.sendControl(jsonEncode({'t': 'dev_gone'}));
    } catch (_) {}
    await transport.close();
  }

  if (!runFlutter) {
    await wsDied.future; // keep tunneling until the relay drops
    await cleanup();
    final failure = directFailure;
    if (failure != null) throw failure;
    return null;
  }

  // For asset sync we need to signal the attach process; make sure we have a
  // pid file even if the caller didn't ask for one.
  final effectivePidFile =
      pidFile ??
      (syncAssets
          ? '${Directory.systemTemp.path}/rhr_attach_${DateTime.now().millisecondsSinceEpoch}.pid'
          : null);
  if (effectivePidFile != null) {
    final f = File(effectivePidFile);
    if (f.existsSync()) f.deleteSync(); // stale pid from a previous session
  }

  final proc = await Process.start(
    projectFlutterExecutable(project),
    [
      'attach',
      '-d',
      'rhr',
      '--debug-url',
      local.toString(),
      // The rhr custom device intentionally has no port-forward command: the
      // VM service is already exposed on this host-local tunnel port. Without
      // an explicit host port Flutter asks the device for a forward and
      // silently ends up with port 0, leaving attach waiting forever.
      '--host-vmservice-port',
      '${local.port}',
      // DDS tries to claim the same host port for a custom device whose VM
      // service is already exposed by our tunnel. The tunneled VM service is
      // sufficient for attach/hot reload, so keep DDS out of this path.
      '--no-dds',
      if (effectivePidFile != null) ...['--pid-file', effectivePidFile],
    ],
    workingDirectory: project,
    mode: ProcessStartMode.inheritStdio,
  );

  if (syncAssets) {
    unawaited(
      _syncAssetsAfterAttach(
        local,
        project,
        effectivePidFile!,
        assetStoreId: assetStoreId,
        maxConcurrentUploads: 4,
        onProgress: (phase, done, total) {
          // Send real progress over the tunnel so the phone draws a live bar.
          // The relay forwards dev→device text as-is; the native player renders it.
          transport.sendControl(
            jsonEncode({
              't': 'progress',
              'phase': phase,
              'done': done,
              'total': total,
            }),
          );
        },
      ).catchError((Object e) {
        stderr.writeln('[rhr] asset sync failed: $e');
        // Clear the phone's progress card while the relay is still writable.
        // The native side also clears it when the connection itself fails.
        transport.sendControl(
          jsonEncode({'t': 'progress', 'phase': '', 'done': 0, 'total': 0}),
        );
      }),
    );
  }

  // Whichever ends first decides: flutter exiting on its own ends the CLI;
  // the relay dying means we kill flutter and reconnect.
  final flutterExit = proc.exitCode;
  final ended = await Future.any<Object>([
    flutterExit.then((c) => c),
    wsDied.future.then((_) => const _RelayEnded()),
  ]);
  if (ended is _RelayEnded) {
    proc.kill();
    await flutterExit; // reap
    await cleanup();
    final failure = directFailure;
    if (failure != null) throw failure;
    return null;
  }
  // flutter exited. But if the relay dropped at nearly the same moment (e.g.
  // the relay died mid-hot-restart), flutter's exit is collateral, not a user
  // quit — reconnect rather than treating it as intentional. Give the ws a
  // beat to surface its own death before trusting a clean exit code.
  if (ended == 0) {
    final relayAlsoDied = await Future.any<bool>([
      wsDied.future.then((_) => true),
      Future<bool>.delayed(const Duration(seconds: 2), () => false),
    ]);
    if (relayAlsoDied) {
      await cleanup();
      final failure = directFailure;
      if (failure != null) throw failure;
      return null; // reconnect
    }
  }
  await cleanup();
  final failure = directFailure;
  if (failure != null) throw failure;
  if (ended is! int) {
    throw StateError('Flutter process completed without an exit code');
  }
  return ended;
}

final class _RelayEnded {
  const _RelayEnded();
}

final class _WaitTimedOut {
  const _WaitTimedOut();
}

/// Mutable deadline shared between the bridge wait and the player-update
/// flow: a build plus an on-device install takes far longer than the normal
/// five-minute join budget, so the updater pushes the deadline out.
final class _DeadlineHolder {
  _DeadlineHolder(this.value);
  DateTime value;
}

/// Waits for the device's info announcement. Unlike an indefinite hang, a slow
/// tester is gently reminded instead of looping "session dropped", and a dead
/// relay connection (wsDied) still ends the wait so the caller can reconnect.
/// Returns the tunneled VM URI, or null when the relay died while waiting.
Future<Uri?> _waitForDeviceBridge(
  Completer<Uri> vmReady,
  Completer<void> wsDied,
  String code,
  _DeadlineHolder deadline,
) async {
  while (true) {
    final remaining = deadline.value.difference(DateTime.now());
    var wait = const Duration(seconds: 30);
    if (remaining.compareTo(wait) < 0) wait = remaining;
    final result = await Future.any<Object>([
      vmReady.future,
      wsDied.future.then((_) => const _RelayEnded()),
      Future<void>.delayed(
        remaining.isNegative ? Duration.zero : wait,
      ).then((_) => const _WaitTimedOut()),
    ]);
    if (result is Uri) return result;
    if (result is _RelayEnded) return null;
    if (DateTime.now().isAfter(deadline.value)) throw const _WaitTimedOut();
    stderr.writeln(
      '[rhr] still waiting for the player on code "$code" — '
      'make sure it is connected (scan the QR or enter this code).',
    );
  }
}

/// The gate blocked and policy allows an update: confirm with the user,
/// build a player carrying the project's plugins and permissions with the
/// project's SDK, stream it over [transport], and hand it to the on-device
/// installer. Returns false when the user declined or the update failed
/// (the caller keeps the hard block).
Future<bool> _updatePlayerOverTheWire({
  required SessionTransport transport,
  required String project,
  required FlutterCompatibility local,
  required PlayerUpdatePolicy policy,
  required _DeadlineHolder deadline,
  required void Function(PlayerUpdateSender) attach,
}) async {
  if (policy == PlayerUpdatePolicy.prompt) {
    if (!stdin.hasTerminal) {
      stderr.writeln(
        '[rhr] no terminal to confirm a player update '
        '(pass --update-player to update without asking).',
      );
      return false;
    }
    stderr.write(
      '[rhr] update the player over the wire to Flutter '
      '${local.frameworkVersion}? [Y/n] ',
    );
    final answer = (await stdin
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first
            .catchError((_) => 'n'))
        .trim()
        .toLowerCase();
    if (answer.isNotEmpty && answer != 'y' && answer != 'yes') return false;
  }

  final template = await resolvePlayerTemplate();
  final sender = PlayerUpdateSender(transport);
  attach(sender);
  try {
    // Building can take minutes and the install needs the tester to reopen
    // the player; keep the bridge wait from expiring under either.
    deadline.value = DateTime.now().add(const Duration(minutes: 20));
    final apk = await buildUpdatePlayerApk(
      project: project,
      template: template,
      frameworkRevision: local.frameworkRevision,
      flutterExecutable: projectFlutterExecutable(project),
    );
    stderr.writeln(
      '[rhr] streaming player update '
      '(${(apk.lengthSync() / (1024 * 1024)).toStringAsFixed(1)} MB)…',
    );
    var lastReported = 0;
    final outcome = await sender.send(
      apk,
      onProgress: (sent, total) {
        // Throttle the on-device overlay updates to every 256 KB.
        if (sent - lastReported < 256 * 1024 && sent != total) return;
        lastReported = sent;
        transport.sendControl(
          jsonEncode({
            't': 'progress',
            'phase': 'updating',
            'done': sent,
            'total': total,
          }),
        );
      },
    );
    deadline.value = DateTime.now().add(const Duration(minutes: 10));
    stderr.writeln(switch (outcome) {
      PlayerUpdateOutcome.committed =>
        '[rhr] update installing — reopen the rhr player on the device; '
            'the session resumes automatically.',
      PlayerUpdateOutcome.pendingUser =>
        '[rhr] confirm the install on the device, then reopen the rhr '
            'player; the session resumes automatically.',
      PlayerUpdateOutcome.installed =>
        '[rhr] wrapped app installed — open it on the device; it dials the '
            'relay with its baked code.',
    });
    return true;
  } on PlayerUpdateFailure catch (failure) {
    stderr.writeln('[rhr] $failure');
    return false;
  } catch (error) {
    stderr.writeln('[rhr] player update failed: $error');
    return false;
  } finally {
    sender.close();
  }
}

/// Pushes build/flutter_assets into the session's DevFS and hot restarts.
///
/// Wire protocol per flutter_tools devfs.dart `_DevFSHttpWriter`: HTTP PUT to
/// the VM service address with `dev_fs_name` and `dev_fs_uri_b64` headers and
/// a gzipped body. Asset device URIs live under `build/flutter_assets/`,
/// which is where the engine looks after a hot restart.
Future<void> _syncAssetsAfterAttach(
  Uri vmService,
  String project,
  String pidFile, {
  String? assetStoreId,
  int maxConcurrentUploads = 4,
  void Function(String phase, int done, int total)? onProgress,
}) async {
  final pidF = File(pidFile);
  final deadline = DateTime.now().add(const Duration(minutes: 15));
  final attachWaitStart = DateTime.now();
  while (!pidF.existsSync()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('flutter attach never became interactive');
    }
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  stderr.writeln(
    '[rhr] attach became interactive after '
    '${DateTime.now().difference(attachWaitStart).inMilliseconds}ms',
  );
  final syncStart = DateTime.now();
  await syncAssets(
    vmService: vmService,
    project: project,
    assetStoreId: assetStoreId,
    maxConcurrentUploads: maxConcurrentUploads,
    onProgress: onProgress,
    afterSync: () async {
      final pid = int.parse(File(pidFile).readAsStringSync().trim());
      final syncMs = DateTime.now().difference(syncStart).inMilliseconds;
      stderr.writeln(
        '[rhr] asset sync took ${syncMs}ms; sending SIGUSR2 hot restart '
        '(waiting for the new main isolate)',
      );
      await trackHotRestart(
        vmService: vmService,
        trigger: () => Process.killPid(pid, ProcessSignal.sigusr2),
        onProgress: onProgress ?? (_, _, _) {},
      );
      stderr.writeln('[rhr] hot restart completed; main isolate replaced');
    },
  );
}

/// The custom device's runDebug command. Delegates to device_run.dart (the
/// single implementation of the tunnel + QR handshake), passing args through.
Future<void> _deviceRun(List<String> args) async {
  final here = File.fromUri(Platform.script).parent.path;
  final proc = await Process.start(Platform.resolvedExecutable, [
    'run',
    '$here/device_run.dart',
    ...args,
  ], mode: ProcessStartMode.inheritStdio);
  exit(await proc.exitCode);
}

/// Builds for Android and then uses Flutter's supported attach path. Unlike a
/// custom device run, this gives Dart native-assets hooks the correct Android
/// target and allows Flutter to replace the generic player's root isolate.
Future<int> _runAttachProductFlow({
  required String project,
  String? relay,
  String? code,
  bool? preferDirect,
  bool resync = false,
  PlayerUpdatePolicy updatePolicy = PlayerUpdatePolicy.prompt,
}) async {
  final sessionCode = code ?? mintRhrSessionCode();
  final config = _loadConfig(project);
  final configuredRelay = relay ?? config['relay'];
  preferDirect ??= config['direct']?.toLowerCase() != 'false';
  final localRelay = await LocalRelay.start(sessionCode);
  final deviceRelays = relayCandidates(
    local: localRelay?.advertisedUrl,
    configured: configuredRelay,
  );
  final devRelays = relayCandidates(
    local: localRelay?.loopbackUrl,
    configured: configuredRelay,
  );
  final qrPayload = configuredRelay == null && localRelay == null
      ? sessionCode
      : jsonEncode({
          'code': sessionCode,
          'relay': deviceRelays.first,
          'relays': deviceRelays,
        });
  final qr = renderTerminalQr(qrPayload);
  stderr.write(
    '\n${qr.text}\n  Scan with the rhr player  ·  or type:  $sessionCode\n\n',
  );
  if (localRelay != null) {
    stderr.writeln(
      '[rhr] LAN fast path: ${localRelay.advertisedUrl} '
      '(relay fallback: ${deviceRelays.last})',
    );
  } else if (configuredRelay != null) {
    stderr.writeln('[rhr] configured relay: $configuredRelay');
  } else {
    stderr.writeln('[rhr] no private LAN address found; using public relay');
  }

  try {
    stderr.writeln('[rhr] building Android asset bundle…');
    final build = await Process.run(projectFlutterExecutable(project), [
      'build',
      'bundle',
      '--debug',
      '--target-platform',
      'android-arm64',
    ], workingDirectory: project);
    if (build.exitCode != 0) {
      stderr.writeln('[rhr] Android bundle build failed:\n${build.stderr}');
      return 1;
    }
    if (resync) {
      final manifest = File('$project/.dart_tool/rhr/pushed_assets.json');
      if (manifest.existsSync()) manifest.deleteSync();
    }

    var failures = 0;
    while (true) {
      try {
        final result = await _runSession(
          relays: devRelays,
          code: sessionCode,
          project: project,
          pidFile: null,
          runFlutter: true,
          syncAssets: true,
          preferDirect: preferDirect,
          updatePolicy: updatePolicy,
        );
        if (result == 0) return 0;
        if (result == _noDeviceExitCode) return result!;
        failures++;
        stderr.writeln(
          '[rhr] Flutter attach ended${result == null ? '' : ' ($result)'}.',
        );
      } on DirectTransportFailure catch (failure) {
        stderr.writeln('[rhr] direct connection failed: $failure');
        return _directFailureExitCode;
      } on Exception catch (error) {
        failures++;
        stderr.writeln('[rhr] session error: $error');
      }
      final delay = Duration(seconds: (2 * (failures + 1)).clamp(2, 15));
      stderr.writeln(
        '[rhr] reconnecting in ${delay.inSeconds}s (ctrl-c to quit)',
      );
      await Future<void>.delayed(delay);
    }
  } finally {
    await localRelay?.close();
  }
}

/// `rhr setup`: enable Flutter custom devices and register the `rhr` device so
/// the QA phone appears in the device picker. Idempotent — re-running refreshes
/// the entry.
Future<void> _setup(String? relay) async {
  relay ??= const String.fromEnvironment(
    'RHR_RELAY',
    defaultValue: defaultPublicRelay,
  );

  stderr.writeln('[rhr] enabling Flutter custom devices…');
  final en = await Process.run('flutter', [
    'config',
    '--enable-custom-devices',
  ]);
  if (en.exitCode != 0) {
    stderr.writeln('[rhr] could not enable custom devices:\n${en.stderr}');
    exit(1);
  }

  // Register the helper directly. Pointing back through this main executable
  // adds an unnecessary wrapper and can contend with an active `rhr run`.
  final deviceRunScript = File.fromUri(
    Platform.script.resolve('device_run.dart'),
  ).absolute.path;
  final dartExe = Platform.resolvedExecutable;

  // Flutter rejects android-* platforms here; null works (defaults to a linux
  // target internally but still drives our tunnel fine — verified).
  final device = {
    'id': 'rhr',
    'label': 'rhr (remote QA phone)',
    'sdkNameAndVersion': 'rhr relay tunnel',
    'platform': null,
    'enabled': true,
    'ping': ['true'],
    'pingSuccessRegex': null,
    'postBuild': ['true'],
    'install': ['true'],
    'uninstall': ['true'],
    'runDebug': [dartExe, 'run', deviceRunScript, '--relay', relay],
    'forwardPort': null,
    'forwardPortSuccessRegex': null,
    'screenshot': null,
  };

  // Remove any existing entry, then add fresh (ignore the delete's failure when
  // none exists).
  await Process.run('flutter', [
    'custom-devices',
    'delete',
    '--device-id',
    'rhr',
  ]);
  final add = await Process.run('flutter', [
    'custom-devices',
    'add',
    '--no-check',
    '--json',
    jsonEncode(device),
  ]);
  if (add.exitCode != 0) {
    stderr.writeln('[rhr] failed to register device:\n${add.stderr}');
    exit(1);
  }

  stderr.writeln('''
[rhr] ✅ setup complete.

  Relay: $relay

  Next:
    1. From a Flutter project, run:  rhr run
    2. A QR appears — the tester scans it in the rhr player.
    3. The app launches automatically. Type r to hot reload.

  Cursor/VS Code manual flow:
    Pick "rhr (remote QA phone)" as the device and use the normal Run button.
''');
}
