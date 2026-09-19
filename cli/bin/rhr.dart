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
import 'package:rhr_cli/account_auth.dart';
import 'package:rhr_cli/relay_config.dart';
import 'package:rhr_cli/restart_tracker.dart';
import 'package:rhr_cli/terminal_qr.dart';
import 'package:rhr_cli/usb_asset_transport.dart';
import 'package:rhr_cli/version.dart';

const _usage = '''
rhr — Expo Go for Flutter, over the internet.

Usage:
  rhr run [options]           run Flutter with automatic initial launch
  rhr attach [options]        connect to a session and hot reload into it
  rhr doctor                  check the local Flutter/RHR setup
  rhr login                   sign in so this machine can use account devices
  rhr logout                  forget the signed-in account
  rhr whoami                  print the signed-in account
  rhr invite                  show a QR for a phone to join this account
  rhr devices [--remove <id>] list the phones on this account
  rhr --version               print the installed CLI version
  rhr push-assets [options]   push assets into an already-attached session
  rhr player build [options]  build a target-compatible debug player APK

run options:
  --project <dir>       Flutter project dir (default: current dir)
  --relay <wss://...>   use a private/self-hosted relay (or .rhr.yaml)
  --code <session>      reuse a specific pairing code (default: generate one)
  --device <id>         a phone on your account (see `rhr devices`)
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
  --device <id>         a phone on your account (see `rhr devices`)
  --project <dir>       Flutter project dir (default: current dir)
  --sync-assets         also push build/flutter_assets — required for the
                        generic player (its APK has no per-project assets)
  --resync              forget the pushed-asset manifest and re-push all
  --no-flutter          just print the tunneled VM URI; don't run flutter attach
  --no-direct           use the relay for tunnel payloads (legacy/private mode;
                        direct WebRTC is strict and enabled by default)
  --pid-file <path>     write the flutter process pid here
  -h, --help            show this help

Session selection, for both run and attach: --device, else --code, else
`code:` in .rhr.yaml, else a fresh code. --device and --code together are
refused rather than one quietly winning.

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
// The device is reachable but another developer is holding it. Distinct from
// "no device joined" so a caller can tell "wait, or pick another phone" apart
// from "check the code".
const _deviceBusyExitCode = 76;

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

  if (args.first == 'login') {
    exit(await _login());
  }

  if (args.first == 'logout') {
    await clearAccountSession();
    stdout.writeln('[rhr] signed out');
    exit(0);
  }

  if (args.first == 'invite') {
    exit(await _invite());
  }

  if (args.first == 'devices') {
    exit(await _devices(args.skip(1).toList()));
  }

  if (args.first == 'whoami') {
    final session = await currentAccountSession();
    if (session == null) {
      stderr.writeln('[rhr] not signed in — run `rhr login`');
      exit(1);
    }
    stdout.writeln(session.email.isEmpty ? session.userId : session.email);
    exit(0);
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

  // `rhr wrap` rebuilt the target under a `.rhr` applicationId, leaving a
  // second copy of the app on the phone. It was a third answer to a question
  // the two remaining flows already answer, so it is gone. Say that, rather
  // than letting the argument fall through to `run` as "unknown arg: wrap".
  if (args[0] == 'wrap') {
    stderr.writeln(
      '[rhr] `rhr wrap` has been removed. Either host the project in the '
      'player (`rhr run`), or tunnel a debug build already on the phone by '
      'picking it in the connector and running `rhr attach`.',
    );
    exit(64);
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

  // Terminal-first product flow: build for Android, attach to the relayed VM,
  // sync assets, and automatically launch the guest app.
  if (args[0] == 'run') {    String project = '.';
    String? relay;
    String? code;
    String? device;
    var resync = false;
    var direct = true;
    var updatePolicy = PlayerUpdatePolicy.prompt;
    for (var i = 1; i < args.length; i++) {
      switch (args[i]) {
        case '--project':
          project = args[++i];
        case '--relay':
          relay = args[++i];
        case '--code':
          code = args[++i];
        case '--device':
          device = args[++i];
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
    code =
        await _resolveDevice(device: device, code: code, project: project) ??
        code;
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
  String? device;
  String project = '.';
  String? pidFile;
  var runFlutter = true;
  var syncAssets = false;
  var resync = false;
  var direct = true;
  var updatePolicy = PlayerUpdatePolicy.prompt;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case 'attach':
        break;
      case '--relay':
        relay = args[++i];
      case '--code':
        code = args[++i];
      case '--device':
        device = args[++i];
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
  if (direct && cfg['direct']?.toLowerCase() == 'false') direct = false;

  code = await _resolveDevice(device: device, code: code, project: project) ??
      code;

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
      if (result == 0) {
        // Leaving on purpose gives the device back now rather than holding it
        // for the rest of a grace period meant for a CLI that crashed. Only on
        // a deliberate exit: a dropped relay must keep the claim so the
        // recovery loop resumes it.
        RelayRace.releaseClaim(code);
        exit(0);
      }
      if (result == _noDeviceExitCode) {
        RelayRace.releaseClaim(code);
        exit(result!);
      }
      if (result != null) {
        failures++;
        stderr.writeln('[rhr] flutter attach exited ($result)');
      } else {
        failures = 0;
      }
    } on DirectTransportFailure catch (failure) {
      stderr.writeln('[rhr] direct connection failed: $failure');
      exit(_directFailureExitCode);
    } on DeviceBusyException catch (busy) {
      // Reconnecting cannot win a device someone else is holding; it would
      // only spin until they leave. Report and quit so the operator can pick
      // another device or wait deliberately.
      stderr.writeln('[rhr] $busy');
      exit(_deviceBusyExitCode);
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
  } on DeviceBusyException catch (e) {
    // Someone else is on this device. Retrying would only fight them for it,
    // so say who has it and stop — the caller must not treat this as a
    // transient relay failure.
    stderr.writeln('[rhr] $e');
    rethrow;
  } catch (e) {
    stderr.writeln('[rhr] could not connect to any relay for code "$code": $e');
    return null;
  }
  final SessionTransport transport = preferDirect
      ? DirectSessionTransport(relayTransport)
      : relayTransport;
  // Ctrl-C is how most sessions actually end, and an interrupted process that
  // says nothing holds the device for the rest of its grace period — so the
  // developer who quits and immediately re-runs is locked out of their own
  // phone. Hand the claim back on the way out.
  //
  // SIGTERM (`kill`) and SIGHUP (the terminal window closed) end a session just
  // as deliberately and were not watched at all, so they left the tester
  // waiting out the 45s lease with a connection error on screen. SIGKILL cannot
  // be caught by anyone; that is what the device's lease is for.
  Future<void> leaveOnSignal(ProcessSignal signal) async {
    relayTransport.release();
    // Tell the phone as well as the relay: releasing the claim frees the
    // device for the next developer, but only dev_gone takes the tester off
    // "Connected" without waiting out the lease.
    try {
      transport.sendControl(jsonEncode({'t': 'dev_gone'}));
    } catch (error) {
      stderr.writeln('[rhr] could not tell the phone we are leaving: $error');
    }
    // Both are WebSocket frames; exiting immediately can kill the process
    // before they leave the socket, which is the case this handler exists to
    // prevent. A short flush beats a 45-second lockout, and the relay's own
    // grace still covers a CLI that dies harder than this.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    // 128 + signal number, the shell's convention for a signalled process.
    exit(switch (signal) {
      ProcessSignal.sigterm => 143,
      ProcessSignal.sighup => 129,
      _ => 130,
    });
  }

  final interrupts = ProcessSignal.sigint.watch().listen(leaveOnSignal);
  final terminations = ProcessSignal.sigterm.watch().listen(leaveOnSignal);
  final hangups = ProcessSignal.sighup.watch().listen(leaveOnSignal);
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
  // Set once `flutter attach` is running, so a restart the tester asks for
  // has something to signal. Null until then, and on the --no-flutter path.
  String? attachPidFile;
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
        // The tester asking, from the phone's dev menu, for the guest app back
        // in its opening state. A hot restart is Flutter's and belongs to this
        // machine, so the phone asks and we perform it — the same SIGUSR2 an
        // asset sync sends. The player only offers the row while a developer
        // is attached; this still answers honestly if it arrives anyway.
        if (m['t'] == 'restart_guest') {
          final pidFile = attachPidFile;
          final pid = pidFile == null || !File(pidFile).existsSync()
              ? null
              : int.tryParse(File(pidFile).readAsStringSync().trim());
          if (pid == null) {
            stderr.writeln(
              '[rhr] the phone asked to restart the app, but no flutter '
              'attach is running to do it.',
            );
            return;
          }
          stderr.writeln('[rhr] restart requested from the phone');
          Process.killPid(pid, ProcessSignal.sigusr2);
          return;
        }
        if (m['t'] == 'info' && !vmReady.isCompleted) {
          final announcedAssetStoreId = m['assetStoreId'];
          final announcedHost = m['host'] ??
              (m['compatibility'] is Map<String, dynamic>
                  ? (m['compatibility'] as Map<String, dynamic>)['host']
                  : null);
          final hostKind =
              announcedHost is String ? announcedHost : 'player';
          if (hostKind == 'connector') {
            // Connector mode tunnels a THIRD-party app's VM service — the
            // target contains no rhr code, so there is no identity to gate on
            // and no player to update. The dev pushes its own kernel, making
            // the SDK question moot. Announced by the player when it is
            // tunneling an installed app rather than hosting a guest project.
            final connectorVm = m['vm'];
            if (connectorVm is! String || connectorVm.isEmpty) {
              stderr.writeln(
                  '[rhr] the target app announced no VM service — is it a '
                  'debug build?');
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
          final report = compatibility.differencesFrom(raw);
          for (final warning in report.warnings) {
            stderr.writeln('[rhr] note: $warning');
          }
          if (report.blockers.isNotEmpty) {
            if (updateSender != null) {
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
            // Tell the phone too: the tester is holding it and otherwise sees
            // a session that simply stops.
            transport.sendControl(
              jsonEncode({
                't': 'progress',
                'phase': 'outdated',
                'done': 0,
                'total': 0,
              }),
            );
            unawaited(
              _updatePlayerOverTheWire(
                transport: transport,
                project: project,
                local: compatibility.flutter,
                policy: updatePolicy,
                deadline: bridgeDeadline,
                attach: (sender) => updateSender = sender,
              ).then((updated) async {
                updateSender = null;
                if (updated) return;
                // The failure reason was just handed to the transport, whose
                // send is async. Exiting here truncates it, and the tester is
                // left on a card that never explains itself — give the socket
                // a beat to flush before the process goes.
                await Future<void>.delayed(const Duration(milliseconds: 750));
                exit(78);
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
    } catch (error) {
      // Before a relay is selected there is nothing to ping yet, which is
      // ordinary. Anything else means the device's presence lease is now
      // counting down against us, so say so rather than going quiet.
      if (error is! StateError) {
        stderr.writeln('[rhr] keepalive ping failed: $error');
      }
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
        // Split at the SCTP limit. A dart:io read is whatever the kernel had
        // buffered — often far more than 64 KiB on a fast machine pushing a
        // kernel — and one oversized message makes libwebrtc close the data
        // channel while reporting the send as successful. That is the
        // "spontaneous disconnect" half of a session dying mid-sync.
        for (var start = 0; start < data.length; start += maxTunnelPayload) {
          final end = start + maxTunnelPayload < data.length
              ? start + maxTunnelPayload
              : data.length;
          sendPayload(
            encodeFrame(opData, channel, Uint8List.sublistView(data, start, end)),
          );
        }
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
    // The session loop reconnects, so the handler must go with this attempt
    // or every retry stacks another one.
    await interrupts.cancel();
    await terminations.cancel();
    await hangups.cancel();
    // Farewell so the phone leaves "Connected" immediately instead of waiting
    // out its 45s presence lease. Harmless if the socket already died (relay
    // drop) — but a swallowed failure here is why a tester was left reading
    // "Can't reach relay — retrying…" after a clean quit, so it gets logged.
    try {
      transport.sendControl(jsonEncode({'t': 'dev_gone'}));
    } catch (error) {
      stderr.writeln('[rhr] could not tell the phone we are leaving: $error');
    }
    await transport.close();
  }

  if (!runFlutter) {
    await wsDied.future; // keep tunneling until the relay drops
    await cleanup();
    final failure = directFailure;
    if (failure != null) throw failure;
    return null;
  }

  // Asset sync signals the attach process, and so does a restart the tester
  // asks for from the phone — which can happen in any session, including a
  // connector one that never syncs assets. Gating the pid file on syncAssets
  // meant `rhr attach` refused those with "no flutter attach is running to do
  // it" while one was running perfectly well.
  final effectivePidFile =
      pidFile ??
      '${Directory.systemTemp.path}/rhr_attach_${DateTime.now().millisecondsSinceEpoch}.pid';
  final stalePid = File(effectivePidFile);
  if (stalePid.existsSync()) stalePid.deleteSync();
  attachPidFile = effectivePidFile;

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
      '--pid-file', effectivePidFile,
    ],
    workingDirectory: project,
    mode: ProcessStartMode.inheritStdio,
  );

  if (syncAssets) {
    unawaited(
      _syncAssetsAfterAttach(
        local,
        project,
        effectivePidFile,
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
  // Flutter ended on its own and the relay is still up, so this is a person
  // quitting rather than a connection failing: hand the device back now
  // instead of making the next developer wait out a grace period meant for a
  // CLI that crashed.
  relayTransport.release();
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
/// Clears the phone's update phase. Every exit from the update path goes
/// through this: a tester holding the device otherwise sits on "building…"
/// long after the developer's terminal gave up.
void _clearUpdatePhase(SessionTransport transport, {String? failure}) {
  transport.sendControl(
    jsonEncode({
      't': 'progress',
      'phase': failure == null ? '' : 'update_failed',
      'done': 0,
      'total': 0,
      if (failure != null) 'message': failure,
    }),
  );
}

Future<bool> _updatePlayerOverTheWire({
  required SessionTransport transport,
  required String project,
  required FlutterCompatibility local,
  required PlayerUpdatePolicy policy,
  required _DeadlineHolder deadline,
  required void Function(PlayerUpdateSender) attach,
}) async {
  // Which payload fixes this? A generic player cannot carry project-owned
  // Android sources, so a project with its own platform channels is never
  // fixed by rebuilding the player — it needs its own debug APK, which the
  // player installs and then tunnels. See notes/UPDATE_SCENARIOS.md.
  final unsupported = readUnsupportedAndroidInputs(project);
  final needsOwnApk = unsupported.isNotEmpty;

  if (needsOwnApk) {
    stderr.writeln(
      '[rhr] this project has its own Android code, which a generic player '
      'cannot run:',
    );
    for (final input in unsupported.take(5)) {
      stderr.writeln('  - $input');
    }
    if (unsupported.length > 5) {
      stderr.writeln('  … ${unsupported.length} files total');
    }
    stderr.writeln(
      '[rhr] building your own app instead; the player will install it and '
      'connect to it.',
    );
  }

  if (policy == PlayerUpdatePolicy.prompt) {
    if (!stdin.hasTerminal) {
      stderr.writeln(
        '[rhr] no terminal to confirm a player update '
        '(pass --update-player to update without asking).',
      );
      _clearUpdatePhase(transport);
      return false;
    }
    stderr.write(
      needsOwnApk
          ? '[rhr] build and install your app on the device? [Y/n] '
          : '[rhr] update the player over the wire to Flutter '
                '${local.frameworkVersion}? [Y/n] ',
    );
    final answer = (await stdin
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first
            .catchError((_) => 'n'))
        .trim()
        .toLowerCase();
    if (answer.isNotEmpty && answer != 'y' && answer != 'yes') {
      _clearUpdatePhase(transport);
      return false;
    }
  }

  final sender = needsOwnApk
      ? PlayerUpdateSender(
          transport,
          kind: UpdateKind.app,
          target: readProjectApplicationId(project),
        )
      : PlayerUpdateSender(transport);
  attach(sender);
  try {
    // The build takes minutes. Say so on the phone, which is otherwise
    // staring at a session that has gone quiet.
    transport.sendControl(
      jsonEncode({
        't': 'progress',
        'phase': 'building',
        'done': 0,
        'total': 0,
      }),
    );
    // Building can take minutes and the install needs the tester to reopen
    // the player; keep the bridge wait from expiring under either.
    deadline.value = DateTime.now().add(const Duration(minutes: 20));
    final flutterExecutable = projectFlutterExecutable(project);
    final apk = needsOwnApk
        ? await buildUpdateProjectApk(
            project: project,
            flutterExecutable: flutterExecutable,
          )
        : await buildUpdatePlayerApk(
            project: project,
            template: await resolvePlayerTemplate(),
            frameworkRevision: local.frameworkRevision,
            flutterExecutable: flutterExecutable,
          );
    stderr.writeln(
      '[rhr] streaming ${needsOwnApk ? 'your app' : 'player update'} '
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
        '[rhr] app installed on the device — start a session against it '
            'from the player.',
    });
    return true;
  } on PlayerUpdateFailure catch (failure) {
    stderr.writeln('[rhr] $failure');
    _clearUpdatePhase(transport, failure: failure.message);
    return false;
  } catch (error) {
    stderr.writeln('[rhr] player update failed: $error');
    _clearUpdatePhase(transport, failure: '$error');
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
    afterSync: ({required bool changed}) async {
      // Only new assets need a restart. The running isolate loaded the
      // bundle at startup, so a hot reload would swap code against stale
      // assets — but when nothing was pushed there is nothing stale, and
      // restarting anyway throws away the app's state for no reason.
      if (!changed) {
        stderr.writeln('[rhr] assets unchanged; no restart needed');
        return;
      }
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
  final config = _loadConfig(project);
  // Same order `attach` uses: an explicit flag, then the project's own
  // config, then a fresh code. `run` used to mint before reading the config
  // at all, so a project that pinned a code got a different one every time
  // and nobody could tell why.
  final sessionCode = code ?? config['code'] ?? mintRhrSessionCode();
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
        // A relay that drops while WebRTC is still negotiating has not told us
        // a direct path is impossible, only that this attempt lost its
        // signaling channel. The recovery loop below re-dials, which is what
        // every other transient failure here already does.
        if (failure.transient) {
          failures++;
          stderr.writeln('[rhr] lost the relay mid-negotiation: $failure');
        } else {
          stderr.writeln('[rhr] direct connection failed: $failure');
          return _directFailureExitCode;
        }
      } on DeviceBusyException catch (busy) {
        // Reconnecting cannot win a device someone else is holding; it would
        // only spin until they leave. Report and quit so the operator can pick
        // another device or wait deliberately.
        stderr.writeln('[rhr] $busy');
        return _deviceBusyExitCode;
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

/// Turns a device selector into a session name, or ends the process saying
/// why not.
///
/// Shared by `run` and `attach` so the two cannot drift apart again — they
/// disagreed about `.rhr.yaml` for long enough that a project pinning a code
/// silently got a fresh one.
Future<String?> _resolveDevice({
  required String? device,
  required String? code,
  required String project,
}) async {
  if (device != null && code != null) {
    stderr.writeln(
      '[rhr] --device and --code both name a session; pass one or the other',
    );
    exit(64);
  }
  // A remembered device is a convenience, not an instruction: anything the
  // developer actually typed wins, and so does a project that pins a code.
  final wanted = device ?? (code == null ? await preferredDevice(project) : null);
  if (wanted == null) return null;

  final session = await currentAccountSession();
  if (session == null) {
    if (device == null) return null; // a stale preference, not a request
    stderr.writeln('[rhr] not signed in — run `rhr login`');
    exit(1);
  }
  final rendezvous = await rendezvousForDevice(
    service: _accountService(),
    installationId: wanted,
    session: session,
  );
  if (rendezvous == null) {
    if (device == null) {
      // The remembered phone has left the account. Say so and carry on
      // rather than failing a command the developer did not aim at it.
      stderr.writeln('[rhr] "$wanted" is no longer on this account');
      await forgetPreferredDevice(project);
      return null;
    }
    stderr.writeln(
      '[rhr] "$wanted" is not a device on this account — run `rhr devices`',
    );
    exit(1);
  }
  await rememberDevice(project, wanted);
  return rendezvous;
}

/// The account service, derived from the relay: they are the same deployment,
/// and a developer who pointed at a private relay means that one.
String _accountService() => const String.fromEnvironment(
  'RHR_RELAY',
  defaultValue: defaultPublicRelay,
).replaceFirst('wss://', 'https://').replaceFirst('ws://', 'http://');

/// `rhr devices`: list the phones on this account, or remove one.
Future<int> _devices(List<String> args) async {
  final session = await currentAccountSession();
  if (session == null) {
    stderr.writeln('[rhr] not signed in — run `rhr login`');
    return 1;
  }
  final removeIndex = args.indexOf('--remove');
  final removing = removeIndex != -1 && removeIndex + 1 < args.length
      ? args[removeIndex + 1]
      : null;

  final http = HttpClient();
  try {
    final base = _accountService();
    if (removing != null) {
      final request = await http.deleteUrl(
        Uri.parse(
          '$base/account/devices'
          '?installationId=${Uri.encodeQueryComponent(removing)}',
        ),
      );
      request.headers.add('Authorization', 'Bearer ${session.accessToken}');
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) {
        stderr.writeln('[rhr] could not remove that device: $body');
        return 1;
      }
      final removed = (jsonDecode(body) as Map<String, Object?>)['removed'];
      stdout.writeln(
        removed == true
            ? '[rhr] removed $removing'
            : '[rhr] $removing was not on this account',
      );
      return removed == true ? 0 : 1;
    }

    final request = await http.getUrl(Uri.parse('$base/account/devices'));
    request.headers.add('Authorization', 'Bearer ${session.accessToken}');
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) {
      stderr.writeln('[rhr] could not list devices: $body');
      return 1;
    }
    final devices =
        (jsonDecode(body) as Map<String, Object?>)['devices'] as List<Object?>;
    if (devices.isEmpty) {
      stdout.writeln(
        'No devices yet. Run `rhr invite` and scan the QR with the player.',
      );
      return 0;
    }
    stdout.writeln('');
    for (final entry in devices.cast<Map<String, Object?>>()) {
      // The id is what --device and --remove take; the label is only what the
      // phone called itself, and two phones may well share one.
      stdout.writeln('  ${entry['installationId']}  ${entry['label']}');
    }
    stdout.writeln('');
    return 0;
  } finally {
    http.close();
  }
}

/// `rhr invite`: show a QR a phone can scan to join this account.
///
/// The phone never signs in — it redeems this and holds a membership from
/// then on, which is what lets a tester lend their phone without being asked
/// to create an account of their own.
Future<int> _invite() async {
  final session = await currentAccountSession();
  if (session == null) {
    stderr.writeln('[rhr] not signed in — run `rhr login`');
    return 1;
  }
  final relay = _accountService();
  final http = HttpClient();
  try {
    final uri = Uri.parse(
      '$relay/account/invite?email=${Uri.encodeQueryComponent(session.email)}',
    );
    final request = await http.postUrl(uri);
    request.headers.add('Authorization', 'Bearer ${session.accessToken}');
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) {
      stderr.writeln('[rhr] could not create an invite: $body');
      return 1;
    }
    final json = jsonDecode(body) as Map<String, Object?>;
    // The payload names the service as well as the token: the phone redeems
    // over HTTPS with the account service, never through the relay socket.
    final payload = jsonEncode({
      'v': 1,
      'join': json['token'],
      'service': relay,
      'account': session.email,
    });
    final qr = renderTerminalQr(payload);
    stdout.writeln('\n${qr.text}');
    stdout.writeln('  Scan with the rhr player to join ${session.email}');
    stdout.writeln('  Single-use, expires in 5 minutes.\n');
    return 0;
  } finally {
    http.close();
  }
}

/// `rhr login`: sign in so this machine can reach the devices on an account.
///
/// The device grant prints a code rather than opening a browser here, so the
/// developer can approve it wherever they already have a session — including
/// from a phone when this is running over SSH.
/// Wraps a WorkOS device-flow URL in the relay's /login redirect, so the
/// address a developer is asked to open is ours rather than the environment
/// name WorkOS generated. Falls back to the raw URL when no login base is
/// configured, since a self-hosted relay may not run the route.
String _loginLink(String workosUrl) {
  const base = String.fromEnvironment('RHR_LOGIN_BASE', defaultValue: defaultLoginBase);
  if (base.isEmpty) return workosUrl;
  return '$base?to=${Uri.encodeComponent(workosUrl)}';
}

Future<int> _login() async {
  final existing = await loadAccountSession();
  if (existing != null) {
    stdout.writeln(
      '[rhr] already signed in as '
      '${existing.email.isEmpty ? existing.userId : existing.email}',
    );
    return 0;
  }
  try {
    final prompt = await requestDeviceCode();
    stdout.writeln('');
    stdout.writeln('  Open        ${_loginLink(prompt.verificationUri)}');
    stdout.writeln('  Enter code  ${prompt.userCode}');
    stdout.writeln('');
    stdout.writeln(
      '  (or go straight to ${_loginLink(prompt.verificationUriComplete)})',
    );
    stdout.writeln('');
    stdout.writeln('[rhr] waiting for you to approve…');
    final session = await pollForToken(prompt);
    await saveAccountSession(session);
    stdout.writeln(
      '[rhr] signed in as '
      '${session.email.isEmpty ? session.userId : session.email}',
    );
    return 0;
  } on AuthFailure catch (e) {
    stderr.writeln('[rhr] $e');
    return 1;
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
