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
import 'dart:math';

import 'package:dart_mcp/stdio.dart';
import 'package:logging/logging.dart';
import 'package:rhr_bridge/session_code.dart';
import 'package:rhr_bridge/session_link.dart';
import 'package:rhr_bridge/tunnel.dart';
import 'package:rhr_cli/asset_sync.dart';
import 'package:rhr_cli/devfs_upload.dart';
import 'package:rhr_cli/direct_path.dart';
import 'package:rhr_cli/direct_session_transport.dart';
import 'package:rhr_cli/flutter_compatibility.dart';
import 'package:rhr_cli/local_relay.dart';
import 'package:rhr_cli/native_fingerprint.dart';
import 'package:rhr_cli/player_builder.dart';
import 'package:rhr_cli/player_update.dart';
import 'package:rhr_cli/relay_race.dart';
import 'package:rhr_cli/account_auth.dart';
import 'package:rhr_cli/agent_apk.dart';
import 'package:rhr_cli/agent_launcher.dart';
import 'package:rhr_cli/device_run.dart';
import 'package:rhr_cli/relay_config.dart';
import 'package:rhr_cli/restart_tracker.dart';
import 'package:rhr_cli/reconnect_backoff.dart';
import 'package:rhr_cli/terminal_qr.dart';
import 'package:rhr_cli/terminal_io.dart';
import 'package:rhr_cli/usb_asset_transport.dart';
import 'package:rhr_cli/version.dart';
import 'package:rhr_cli/run_preparation.dart';
import 'package:rhr_cli/running_project.dart';
import 'package:rhr_cli/rhr_mcp.dart';
import 'package:rhr_cli/session_control.dart';
import 'package:rhr_cli/cli_update.dart';
import 'package:webrtc_dart/webrtc_dart.dart' show WebRtcLogging;

const _usage = '''
rhr — Expo Go for Flutter, over the internet.

Usage:
  rhr setup [--relay <url>]   once per machine: let any shell and agent run rhr,
                              register the "rhr" Flutter device, and register
                              rhr mcp with Claude Code
  rhr run [options]           pair, check, prepare, and run this project
  rhr attach [options]        connect to a session and hot reload into it
  rhr persist [options]       install a debug build of the current code, so
                              the app keeps it after it is killed and reopened
  rhr release [options]       build a release APK (no RHR inside) and install it
  rhr mcp [--project <dir>]   MCP server (stdio) that lets a coding agent see,
                              tap, read logs and hot reload on the phone of the
                              rhr session running for the project
                              (rhr setup registers it with Claude Code)
  rhr doctor                  check the local Flutter/RHR setup
  rhr login                   sign in so this machine can use account devices
  rhr logout                  forget the signed-in account
  rhr whoami                  print the signed-in account
  rhr invite                  show a QR for a phone to join this account
  rhr devices [--remove <id>] list the phones on this account
  rhr --version               print the installed CLI version
  rhr update [--check]         install the newest release, or only check for it
  rhr push-assets [options]   push assets into an already-attached session
  rhr player build [options]  build a target-compatible debug player APK

Start here: install RHR Player on the phone, run `rhr` in your Flutter project,
then scan its QR or enter its code. RHR selects the route and guides phone setup.
On the phone, tap the printed connection link, then Open RHR. Connection details are
also saved as JSON in .dart_tool/rhr/connection.json for agents to read.
An agent can use `rhr run --yes` to approve required debug builds/installations.
Android may still ask the tester to confirm permissions or installation.

run options:
  --yes                approve required player/app builds and installations
  --mode <auto|player|app>  select automatically (default), or force a route
  --project <dir>       Flutter project dir (default: current dir)
  --relay <wss://...>   use a private/self-hosted relay (or .rhr.yaml)
  --code <session>      override the saved pairing code (new code on first run)
  --device <id>         a phone on your account (see `rhr devices`)
  --no-direct           use the relay for tunnel payloads (legacy/private mode;
                        direct WebRTC is strict and enabled by default)
  --resync              ignore the local asset manifest and re-push all assets

persist and release options: --project, --relay, --code, --device, --no-direct.
Both ask a running `rhr run` for the project when there is one; otherwise they
connect to the phone themselves. persist works for projects that run as their
own app. A release build replaces the debug app if it has the same package and
signing key.

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
  --update-player       on version skew, rebuild and update the player without asking
  --no-update-player    on version skew, hard-block instead of offering an update
  -h, --help            show this help

Session selection, for both run and attach: --device, else --code, else
`code:` in .rhr.yaml, then run reuses its recent saved code or generates one.
--device and --code together are
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

/// The relay refused a binary frame: the session ran --no-direct against a
/// relay that carries signalling only, so its payloads can never get through.
const _relayBinaryExitCode = 77;

/// The run needs a build or install the developer has not approved.
const _approvalExitCode = 79;

/// Not a process exit: the session ended because native code changed, and
/// the run loop prepares it again (building and installing what it needs).
const _reprepare = -2;

/// The command line this process was started with, so a run that stops for
/// approval can print the exact command that continues it.
var _invocation = const <String>[];

Future<void> main(List<String> args) async {
  if (Platform.environment['RHR_WEBRTC_LOG'] == '1') _logWebRtc();
  if (args.length == 1 &&
      (args.first == '--version' || args.first == 'version')) {
    stdout.writeln('rhr $rhrVersion');
    return;
  }

  if (args.isEmpty) args = ['run'];
  _invocation = args;

  if (args.contains('-h') || args.contains('--help') || args.first == 'help') {
    stdout.write(_usage);
    exit(0);
  }

  if (args.first == 'doctor') {
    exit(await _doctor());
  }

  if (args.first == 'mcp') {
    var project = Directory.current.path;
    for (var i = 1; i < args.length; i++) {
      if (args[i] == '--project' && i + 1 < args.length) {
        project = args[++i];
      } else {
        stderr.writeln('unknown arg: ${args[i]}');
        exit(64);
      }
    }
    final server = RhrMcpServer(
      stdioChannel(input: stdin, output: stdout),
      project: Directory(project).absolute.path,
    );
    await server.done;
    exit(0);
  }

  if (args.first == 'update') {
    exit(await runCliUpdate(args.skip(1).toList()));
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
    // SSH commands and agent tools read no shell config, so without this
    // they find neither rhr nor the dart it runs on. First, so the device
    // registered below runs rhr through it.
    final launcher = await installLauncher();
    stderr.writeln('[rhr] ${launcher.message}');
    await _setup(relay);
    if (!launcher.ok) {
      stderr.writeln(
        '[rhr] Setup is done except one step: agents and SSH commands cannot '
        'run rhr until $launcherPath is written (see above).',
      );
      exit(1);
    }
    if (!await rhrOnBarePath()) {
      stderr.writeln(
        '[rhr] rhr still does not run from a bare shell; check $launcherPath.',
      );
      exit(1);
    }
    // Needs the launcher above: that is the command it registers.
    final mcp = await registerMcp();
    stderr.writeln('[rhr] ${mcp.message}');
    if (!mcp.ok) exit(1);
    stderr.writeln('[rhr] ✅ setup complete. Any shell and agent can run rhr.');
    exit(0);
  }

  // rhr device-run --relay <wss://...> [--code <session>]
  // The custom device's runDebug command — delegate to the standalone helper so
  // there's a single implementation of the tunnel+QR handshake.
  if (args[0] == 'device-run') {
    await runDeviceRun(args.sublist(1));
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
  // Both `run` and `attach` end at `flutter attach -d rhr`, which needs the
  // custom device to exist. Registering here means a fresh machine works
  // without a separate step; making the developer discover it by way of "No
  // supported devices found with name or id matching 'rhr'" — printed under
  // a list of whatever else is installed, which on a Linux box is the
  // desktop — is a bad trade for a call that is free when it is already
  // there.
  if (const {'run', 'attach', 'persist', 'release'}.contains(args[0])) {
    await ensureRhrDevice();
    if (!Platform.isWindows && !File(launcherPath).existsSync()) {
      stderr.writeln(
        '[rhr] Agents and SSH commands cannot find rhr on this machine yet. '
        'Run `rhr setup` once to fix that.',
      );
    }
  }

  // Explicit builds for the phone: the current code as a debug app that keeps
  // it (persist), or a release build with nothing of RHR in it (release).
  if (args[0] == 'persist' || args[0] == 'release') {
    final command = args[0];
    String project = '.';
    String? relay;
    String? code;
    String? device;
    var direct = true;
    for (var i = 1; i < args.length; i++) {
      if (const {
            '--project',
            '--relay',
            '--code',
            '--device',
          }.contains(args[i]) &&
          (i + 1 == args.length || args[i + 1].startsWith('--'))) {
        stderr.writeln(
          'rhr $command: ${args[i]} requires a value. Run rhr --help.',
        );
        exit(64);
      }
      switch (args[i]) {
        case '--project':
          project = args[++i];
        case '--relay':
          relay = args[++i];
        case '--code':
          code = args[++i];
        case '--device':
          device = args[++i];
        case '--no-direct':
          direct = false;
        default:
          stderr.writeln('unknown arg: ${args[i]}');
          exit(64);
      }
    }
    // A running session holds the phone, and a second CLI would be refused.
    final answer = await sendSessionCommand(project, command);
    if (answer != null) {
      stderr.writeln('[rhr] ${answer.message}');
      exit(answer.ok ? 0 : 78);
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
        // Asking for the build is the approval.
        updatePolicy: PlayerUpdatePolicy.always,
        task: command == 'persist' ? RunTask.persist : RunTask.release,
      ),
    );
  }

  // sync assets, and automatically launch the guest app.
  if (args[0] == 'run') {
    String project = '.';
    String? relay;
    String? code;
    String? device;
    var resync = false;
    var direct = true;
    var updatePolicy = PlayerUpdatePolicy.prompt;
    RunRoute? routeOverride;
    for (var i = 1; i < args.length; i++) {
      if (const {
            '--project',
            '--relay',
            '--code',
            '--device',
            '--mode',
          }.contains(args[i]) &&
          (i + 1 == args.length || args[i + 1].startsWith('--'))) {
        stderr.writeln('rhr run: ${args[i]} requires a value. Run rhr --help.');
        exit(64);
      }
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
        case '--mode':
          final mode = args[++i];
          if (!const {'auto', 'player', 'app'}.contains(mode)) {
            stderr.writeln('rhr run: --mode must be auto, player, or app.');
            exit(64);
          }
          routeOverride = switch (mode) {
            'auto' => null,
            'player' => RunRoute.player,
            'app' => RunRoute.app,
            _ => throw ArgumentError('mode must be auto, player, or app'),
          };
        case '--yes':
          updatePolicy = PlayerUpdatePolicy.always;
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
        routeOverride: routeOverride,
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

  code =
      await _resolveDevice(device: device, code: code, project: project) ??
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
  final reconnectBackoff = ReconnectBackoff();
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
        onReady: reconnectBackoff.markReady,
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
      if (result == _noDeviceExitCode ||
          result == _relayBinaryExitCode ||
          result == 78) {
        RelayRace.releaseClaim(code);
        exit(result!);
      }
      if (result != null) {
        stderr.writeln('[rhr] flutter attach exited ($result)');
      }
    } on DirectTransportFailure catch (failure) {
      // Same rule as `run` below: a direct path lost while the device is
      // replacing its session or its relay socket is re-dialed, only a
      // protocol violation ends the attach.
      if (failure.transient) {
        stderr.writeln('[rhr] direct path dropped: $failure');
        if (reconnectBackoff.directPathImpossible(failure)) {
          stderr.writeln(_noDirectPath);
          exit(_directFailureExitCode);
        }
      } else {
        stderr.writeln('[rhr] direct connection failed: $failure');
        exit(_directFailureExitCode);
      }
    } on DeviceBusyException catch (busy) {
      // Reconnecting cannot win a device someone else is holding; it would
      // only spin until they leave. Report and quit so the operator can pick
      // another device or wait deliberately.
      stderr.writeln('[rhr] $busy');
      exit(_deviceBusyExitCode);
    } on Exception catch (e) {
      stderr.writeln('[rhr] session error: $e');
    }
    final delay = reconnectBackoff.nextDelay();
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
  // What an SSH command or an agent's tool shell sees: the system PATH and
  // no shell config.
  if (await rhrOnBarePath()) {
    stdout.writeln('[OK] rhr runs from a bare shell (agents, SSH commands)');
  } else {
    healthy = false;
    stdout.writeln(
      '[FAIL] rhr does not run from a bare shell, so agents and SSH commands '
      'cannot use it',
    );
    stdout.writeln('       run `rhr setup` once on this machine');
  }
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

  // Without the custom device, `flutter attach` has nothing named "rhr" to
  // target and silently picks whatever else is registered — on a Linux box
  // that is the desktop, and the session dies with "No supported devices
  // found" buried under a device list. Cheap to check, invisible to debug.
  try {
    final devices = await Process.run('flutter', ['custom-devices', 'list']);
    if ('${devices.stdout}'.contains('id: rhr')) {
      stdout.writeln('[OK] the "rhr" Flutter device is registered');
    } else {
      healthy = false;
      stdout.writeln('[FAIL] the "rhr" Flutter device is not registered');
      stdout.writeln('       run `rhr setup` once on this machine');
    }
  } on ProcessException {
    stdout.writeln('[INFO] could not list Flutter custom devices');
  }

  // Building a player writes several GB of Gradle intermediates into the
  // system temp dir, which on Linux is routinely a tmpfs a fraction of that.
  final temp = Directory.systemTemp;
  final free = freeSpaceBytes(temp.path);
  if (free == null) {
    stdout.writeln('[INFO] could not measure free space in ${temp.path}');
  } else if (free < 6 * 1024 * 1024 * 1024) {
    stdout.writeln(
      '[INFO] ${temp.path} has ${(free / (1 << 30)).toStringAsFixed(1)} GiB '
      'free; building a player needs about 6 GiB',
    );
    stdout.writeln('       set TMPDIR to a directory with more room');
  } else {
    stdout.writeln(
      '[OK] ${temp.path} has ${(free / (1 << 30)).toStringAsFixed(1)} GiB '
      'free for player builds',
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
  bool prepareRun = false,
  RunTask task = RunTask.session,
  RunRoute? routeOverride,
  RunProgress? runProgress,
  void Function()? onReady,
}) async {
  final compatibility = readProjectCompatibilityProfile(project);
  String? assetStoreId;
  late final RelayRace relayTransport;
  try {
    relayTransport = await RelayRace.connect(
      relays: relays,
      code: code,
      claimFile: File('$project/.dart_tool/rhr/claim.json'),
    );
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
  void Function()? restoreTerminal;
  Process? attachProcess;

  // Tells the phone this developer is leaving, so the tester is taken off
  // "Connected" without waiting out the lease. Before a relay is selected the
  // phone has not seen this developer, so there is no one to tell.
  void sayGoodbye() {
    try {
      transport.sendControl(jsonEncode({'t': 'dev_gone'}));
    } on StateError {
      // No relay selected yet.
    } catch (error) {
      stderr.writeln('[rhr] could not tell the phone we are leaving: $error');
    }
  }

  // Ends the process on purpose. Releasing the claim frees the device for the
  // next developer at once; dev_gone frees the tester's screen. Both are
  // WebSocket frames, and exiting immediately can kill the process before
  // they leave the socket. A short flush beats a 45-second lockout, and the
  // relay's own grace still covers a CLI that dies harder than this.
  var leaving = false;
  SessionControl? sessionControl;
  Future<Never> leave(int exitCode) async {
    leaving = true;
    unawaited(sessionControl?.close());
    relayTransport.release();
    sayGoodbye();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    exit(exitCode);
  }

  Future<void> leaveOnSignal(ProcessSignal signal) async {
    restoreTerminal?.call();
    attachProcess?.kill();
    // 128 + signal number, the shell's convention for a signalled process.
    await leave(switch (signal) {
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
  // Set when the relay's close is final for this session: the reconnect loop
  // must return it instead of re-dialing. It rides the ordinary wsDied
  // teardown so the flutter child and the listener are cleaned up first.
  int? fatalExit;
  final sockets = <int, Socket>{};
  // Every connection Flutter made to the tunneled VM service, including ones
  // still being read or held by a DevFS upload: ending the session closes
  // them all, which is what fails anything waiting on one.
  final accepted = <Socket>{};
  // Completes when this attempt tears down. Anything that waits on the phone
  // (a window to open, an answer to arrive) also waits on this.
  final sessionOver = Completer<void>();
  final flow = FlowControl();
  // Channels carrying a rewritten DevFS upload: the phone's answer is read
  // here, not handed straight to Flutter, so a missing base can be retried.
  final devFsAnswers = <int, ({BytesBuilder bytes, Completer<void> closed})>{};
  // Whether this host rebuilds delta uploads (announced in its info). The
  // Android player does; the pure-Dart desktop bridge does not.
  var devFsDelta = false;
  // The route this session runs, the player's runtime, and the native
  // fingerprint the session started from (see _nativeChanged below).
  RunRoute? sessionRoute;
  // The Android package the project runs in, for `rhr mcp` to bring it back
  // to the front.
  String? sessionPackage;
  Map<String, dynamic>? playerCompatibility;
  // The player's signing certificate, which RHR Agent must share.
  String? playerCertificate;
  String? nativeBaseline;
  DirectTransportFailure? directFailure;
  PlayerUpdateFailure? preparationRetry;
  // Set once `flutter attach` is running, so a restart the tester asks for
  // has something to signal. Null until then, and on the --no-flutter path.
  String? attachPidFile;
  var reloadInProgress = false;
  Timer? reloadFeedbackTimer;
  // A hot reload or restart asked for over session control, waiting for
  // Flutter to say how it went.
  Completer<bool>? reloadAsked;
  final reloadOutput = StringBuffer();
  final bridgeDeadline = _DeadlineHolder(
    DateTime.now().add(const Duration(minutes: 5)),
  );
  PlayerUpdateSender? updateSender;
  var updateAttempted = false;
  var effectiveSyncAssets = syncAssets;
  var staleDart = false;
  final preparation = prepareRun
      ? RunPreparation(
          transport: transport,
          project: project,
          profile: compatibility,
          policy: updatePolicy,
          routeOverride: routeOverride,
          task: task,
          progress: runProgress,
        )
      : null;
  Future<void>? preparing;
  if (preparation != null) {
    preparing = preparation
        .run()
        .then((ready) async {
          // A persist or release command finished: nothing to attach.
          if (ready == null) {
            fatalExit = 0;
            if (!wsDied.isCompleted) wsDied.complete();
            return;
          }
          effectiveSyncAssets = ready.route == RunRoute.player;
          staleDart = ready.staleDart;
          sessionRoute = ready.route;
          sessionPackage = ready.package;
          nativeBaseline = await nativeFingerprint(project);
          assetStoreId = ready.assetStoreId;
          if (!vmReady.isCompleted) vmReady.complete(ready.vm);
        })
        .catchError((Object error) {
          if (error is PlayerUpdateFailure && error.retryable) {
            preparationRetry = error;
          } else if (error is DirectTransportFailure) {
            directFailure ??= error;
          } else if (error is ApprovalRequired) {
            final again = [
              ..._invocation,
              if (!_invocation.contains('--yes')) '--yes',
            ];
            stderr.writeln(
              error.declined
                  ? '[rhr] Canceled. Nothing was built or installed.'
                  : '[rhr] Needs approval: ${error.plan}',
            );
            stderr.writeln(
              '[rhr] To approve and continue: rhr ${again.join(' ')}',
            );
            preparation.phase(
              'approval_needed',
              'Waiting for your developer to approve the install.',
              echo: false,
            );
            fatalExit = _approvalExitCode;
          } else if (error is! RunDisconnected) {
            preparation.phase('preparation_failed', '$error');
            fatalExit = 78;
          }
          if (!wsDied.isCompleted) wsDied.complete();
        });
  }

  void sendPayload(Uint8List payload) {
    if (wsDied.isCompleted) return;
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
        if (m['t'] == 'info') {
          devFsDelta = m['devfsDelta'] == 1;
          if (m['playerCertificate'] case final String certificate) {
            playerCertificate = certificate;
          }
          if (m['compatibility'] case final Map<String, dynamic> runtime) {
            playerCompatibility = runtime;
          }
        }
        if (preparation != null && m['t'] == 'info') {
          bridgeDeadline.value = DateTime.now().add(
            const Duration(minutes: 40),
          );
        }
        final path = describeDirectPath(m);
        if (path != null) {
          stderr.writeln('[rhr] $path');
          return;
        }
        preparation?.handleMessage(m);
        if (preparation != null && m['t'] == 'info') return;
        if (updateSender?.handleMessage(m) ?? false) return;
        // The tester asking, from the phone's dev menu, for the guest app back
        // in its opening state. A hot restart is Flutter's and belongs to this
        // machine, so the phone asks and we perform it — the same SIGUSR2 an
        // asset sync sends. The player only offers the row while a developer
        // is attached; this still answers honestly if it arrives anyway.
        if (m['t'] == 'restart_guest') {
          if (reloadInProgress) return;
          final pidFile = attachPidFile;
          final pid = pidFile == null || !File(pidFile).existsSync()
              ? null
              : int.tryParse(File(pidFile).readAsStringSync().trim());
          if (pid == null) {
            transport.sendControl(
              jsonEncode({
                't': 'progress',
                'phase': 'reload_failed',
                'done': 0,
                'total': 0,
              }),
            );
            stderr.writeln(
              '[rhr] the phone asked to restart the app, but no flutter '
              'attach is running to do it.',
            );
            return;
          }
          stderr.writeln('[rhr] restart requested from the phone');
          reloadInProgress = Process.killPid(pid, ProcessSignal.sigusr2);
          if (!reloadInProgress)
            transport.sendControl(
              jsonEncode({
                't': 'progress',
                'phase': 'reload_failed',
                'done': 0,
                'total': 0,
              }),
            );
          return;
        }
        // Only the device's answer to this connection's hello counts. The
        // relay first replays the last info it cached, which can describe a
        // previous developer's session: a debug app since closed, whose VM
        // address and token no longer lead anywhere.
        if (m['t'] == 'info' &&
            m['answers'] == relayTransport.connectionId &&
            !vmReady.isCompleted &&
            !leaving) {
          final announcedAssetStoreId = m['assetStoreId'];
          final announcedHost = m['host'];
          final hostKind = announcedHost is String ? announcedHost : 'player';
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
                'debug build?',
              );
              unawaited(leave(78));
              return;
            }
            assetStoreId = announcedAssetStoreId is String
                ? announcedAssetStoreId
                : '';
            vmReady.complete(Uri.parse(connectorVm));
            return;
          }
          final raw = m['compatibility'];
          if (announcedAssetStoreId is! String ||
              announcedAssetStoreId.isEmpty ||
              raw is! Map<String, dynamic>) {
            stderr.writeln(
              '[rhr] COMPATIBILITY_BLOCKED: the player announced no runtime '
              'or asset-store identity.',
            );
            unawaited(leave(78));
            return;
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
            // A player update carries a Flutter runtime, never a project's
            // native code. A project that needs its own app gets it from
            // `rhr run`, which builds it with the beacon the player finds it by.
            if (compatibility.nativeDifferencesFrom(raw).isNotEmpty) {
              stderr.writeln(
                '[rhr] This project needs its own debug app, which a player '
                'update cannot provide. Run `rhr run` instead; it builds and '
                'installs it.',
              );
              unawaited(leave(78));
              return;
            }
            if (updatePolicy == PlayerUpdatePolicy.never || updateAttempted) {
              stderr.writeln(
                updateAttempted
                    ? '[rhr] the player is still incompatible after the update.'
                    : '[rhr] Rebuild/reinstall a compatible player before '
                          'streaming.',
              );
              unawaited(leave(78));
              return;
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
                await Future<void>.delayed(const Duration(milliseconds: 500));
                await leave(78);
              }),
            );
            return;
          }
          final vmValue = m['vm'];
          if (vmValue is! String || vmValue.isEmpty) {
            stderr.writeln(
              '[rhr] COMPATIBILITY_BLOCKED: player announced no VM service.',
            );
            unawaited(leave(78));
            return;
          }
          vmReady.complete(Uri.parse(vmValue));
        }
        return;
      }
      final f = decodeFrame(msg as List<int>);
      switch (f.op) {
        case opData:
          final answer = devFsAnswers[f.channel];
          if (answer != null) {
            answer.bytes.add(f.payload);
          } else {
            sockets[f.channel]?.add(f.payload);
          }
          sendPayload(encodeAck(f.channel, f.payload.length));
        case opAck:
          if (PlayerUpdateSender.isUpdateAck(f.channel)) {
            preparation?.handleAck(f.channel, decodeAckCount(f.payload));
            updateSender?.handleAck(f.channel, decodeAckCount(f.payload));
          } else {
            flow.acked(f.channel, decodeAckCount(f.payload));
          }
        case opClose:
          flow.forget(f.channel);
          devFsAnswers.remove(f.channel)?.closed.complete();
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
      // The relay killed the socket for carrying binary. Reconnecting would
      // only send the same payload into the same refusal, forever, so name
      // the requirement once and stop.
      if (reason.contains(relayBinaryRefusal)) {
        stderr.writeln('[rhr] $relayBinaryUnsupported');
        fatalExit = _relayBinaryExitCode;
      }
      preparation?.close();
      stderr.writeln('[rhr] relay connection closed');
      if (!wsDied.isCompleted) wsDied.complete();
    },
    onError: (Object e) {
      preparation?.close();
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
    vm = await _waitForDeviceBridge(
      vmReady,
      wsDied,
      code,
      bridgeDeadline,
      // An update in flight IS the player, busy. Without this the wait
      // loop told the developer to check whether the phone was connected,
      // every 30 seconds, while it was streaming an APK to that phone.
      updating: () => updateSender != null || preparation != null,
    );
  } on _WaitTimedOut {
    preparation?.close();
    await preparing;
    await interrupts.cancel();
    await terminations.cancel();
    await hangups.cancel();
    keepalive.cancel();
    // `rhr attach` gives up here; `rhr run` keeps the device and waits on.
    if (!prepareRun) relayTransport.release();
    await transport.close();
    stderr.writeln(
      prepareRun
          ? '[rhr] Still waiting for the phone. Keeping this session available.'
          : '[rhr] no player joined session "$code" within 5 minutes. '
                'Check the code, scan the QR again, and rerun rhr attach.',
    );
    return prepareRun ? null : _noDeviceExitCode;
  }
  if (vm == null) {
    preparation?.close();
    await preparing;
    keepalive.cancel();
    await interrupts.cancel();
    await terminations.cancel();
    await hangups.cancel();
    if (fatalExit != null || preparationRetry != null) {
      // A final exit (not a reprepare or a retry) ends the session on
      // purpose: hand the device back now.
      if (fatalExit != null && fatalExit != _reprepare) {
        relayTransport.release();
      }
      sayGoodbye();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await transport.close();
    }
    // An exit the session chose (approval needed, a fatal preparation
    // error, a native reprepare) outranks the direct path the phone tore down
    // because of it; rethrowing that would only reconnect into the same stop.
    final failure = directFailure;
    if (failure != null && fatalExit == null) {
      await transport.close();
      throw failure;
    }
    final retry = preparationRetry;
    if (retry != null) {
      await transport.close();
      throw retry;
    }
    await transport.close();
    return fatalExit; // relay died while waiting
  }
  stderr.writeln('[rhr] device VM service: $vm');

  try {
    await transport.payloadReady;
  } on DirectTransportFailure catch (failure) {
    keepalive.cancel();
    await interrupts.cancel();
    await terminations.cancel();
    await hangups.cancel();
    await transport.close();
    throw failure;
  }

  var nextChannel = 1;

  /// Writes [bytes] to [channel], pausing whenever its window is full.
  /// False when the phone closed the channel or the session ended first.
  Future<bool> sendOnChannel(
    int channel,
    Uint8List bytes,
    Completer<void> closed,
  ) async {
    for (var start = 0; start < bytes.length; start += maxTunnelPayload) {
      if (closed.isCompleted || sessionOver.isCompleted) return false;
      final end = min(start + maxTunnelPayload, bytes.length);
      sendPayload(
        encodeFrame(opData, channel, Uint8List.sublistView(bytes, start, end)),
      );
      if (flow.sent(channel, end - start)) {
        final open = Completer<void>();
        flow.onWindowOpen(channel, open.complete);
        await Future.any([open.future, closed.future, sessionOver.future]);
      }
    }
    return true;
  }

  /// Sends Flutter's DevFS upload as a delta against a file the phone kept
  /// (see devfs_upload.dart), then hands Flutter the phone's answer.
  Future<void> uploadDevFs(Socket sock, DevFsPut put) async {
    final uri = put.uriBase64 ?? '';
    // A hot reload's incremental kernel, or anything but a whole program,
    // is not worth a delta or keeping as a base; it goes as Flutter wrote it.
    final plain =
        put.uncompressedSize < devFsDeltaMinimumBytes || !devFsKernel(uri);
    final bases = _devFsBasesFor(project);
    final base = plain ? null : bases.newest;
    final rewritten = plain ? null : rewriteDevFsPut(put, base);
    final request = rewritten?.request ?? plainDevFsPut(put);
    final channel = nextChannel++;
    final answer = (bytes: BytesBuilder(), closed: Completer<void>());
    devFsAnswers[channel] = answer;
    sendPayload(encodeFrame(opOpen, channel));
    var sent = false;
    try {
      sent = await sendOnChannel(channel, request, answer.closed);
      if (sent) await Future.any([answer.closed.future, sessionOver.future]);
    } finally {
      devFsAnswers.remove(channel);
    }
    // Cut short: dropping Flutter's connection makes it retry the upload.
    if (!sent || !answer.closed.isCompleted) {
      sock.destroy();
      return;
    }
    final response = answer.bytes.takeBytes();
    switch (httpStatus(response)) {
      case 409:
        // The phone no longer has that base. Dropping the connection makes
        // Flutter retry the upload, and the retry goes whole.
        bases.forget();
        sock.destroy();
        return;
      case 200 when rewritten != null:
        bases.confirm(uri, rewritten.sha, rewritten.content);
        final sent = rewritten.request.length;
        if (base != null) {
          stderr.writeln(
            '[rhr] sent ${(sent / 1024).ceil()} KB for a '
            '${(put.gzippedBody.length / 1048576).toStringAsFixed(1)} MB '
            'upload (delta against the phone\'s copy)',
          );
        }
    }
    sock.add(response);
    await sock.flush().catchError((_) {});
    sock.destroy();
  }

  // A native change cannot reach a running app: hot reload and restart carry
  // Dart and assets only. Every reload and restart uploads through this
  // listener, whoever triggered it, so an upload is where to notice one.
  // Checked at most every 2 s (a restart is a burst of uploads), one check at
  // a time, and latched: the first check that ends the session decides.
  Future<bool>? nativeCheck;
  var nativeCheckedAt = DateTime(0);
  var nativeEnded = false;
  Future<bool> nativeChanged() {
    final baseline = nativeBaseline;
    if (nativeEnded) return Future.value(true);
    if (baseline == null) return Future.value(false);
    final recent = nativeCheck;
    if (recent != null &&
        DateTime.now().difference(nativeCheckedAt) <
            const Duration(seconds: 2)) {
      return recent;
    }
    nativeCheckedAt = DateTime.now();
    return nativeCheck = () async {
      final now = await nativeFingerprint(project);
      if (now == baseline) return false;
      final reasons = readProjectCompatibilityProfile(
        project,
      ).nativeDifferencesFrom(playerCompatibility ?? const {});
      if (sessionRoute == RunRoute.player) {
        if (reasons.isEmpty) {
          // A pure-Dart dependency: the player still hosts everything.
          nativeBaseline = now;
          return false;
        }
        if (routeOverride == RunRoute.player) {
          stderr.writeln(
            '[rhr] Native code changed (${reasons.join('; ')}), but '
            '--mode player keeps this project in the player: calls into it '
            'will fail until you run without --mode player.',
          );
          nativeBaseline = now;
          return false;
        }
      }
      nativeEnded = true;
      stderr.writeln(
        sessionRoute == RunRoute.player
            ? '[rhr] Native code changed: ${reasons.join('; ')}. The player '
                  'cannot run it, so this project moves to its own debug app. '
                  "Restarting the session; the app's state resets."
            : '[rhr] Native code changed. Rebuilding the debug app; '
                  "the app's state resets.",
      );
      preparation?.phase(
        'native_changed',
        'Your developer changed native code. RHR is rebuilding your app; '
            'its state will reset.',
        echo: false,
      );
      fatalExit = _reprepare;
      if (!wsDied.isCompleted) wsDied.complete();
      return true;
    }();
  }

  // Tunnels one local connection to the phone: to the VM service, or to
  // [target] (see bridge/lib/tunnel.dart). A target connection first sends
  // the session control token and a newline: unlike the VM service, device
  // control and logs have no secret of their own.
  void accept(Socket sock, [int? target]) {
    accepted.add(sock);
    // Socket write failures (peer reset mid-transfer) surface on `done`;
    // unhandled they crash the process.
    sock.done.catchError((_) {}).whenComplete(() => accepted.remove(sock));
    var unauthenticated = target == null ? null : BytesBuilder();
    // Until the first request head shows whether this is a DevFS upload the
    // phone can rebuild from a delta, hold the bytes. Everything else is
    // tunnelled byte for byte, exactly as before.
    var sniffing = target == null && (devFsDelta || prepareRun)
        ? HttpRequestReader()
        : null;
    int? rawChannel;
    late final StreamSubscription<Uint8List> sub;

    void forward(Uint8List data) {
      final channel = rawChannel!;
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
    }

    void openRaw(Uint8List first) {
      sniffing = null;
      final channel = rawChannel = nextChannel++;
      sockets[channel] = sock;
      sendPayload(encodeOpen(channel, target));
      if (first.isNotEmpty) forward(first);
    }

    void closeRaw() {
      final channel = rawChannel;
      if (channel == null) return;
      flow.forget(channel);
      if (sockets.remove(channel) != null) {
        sendPayload(encodeFrame(opClose, channel));
      }
    }

    sub = sock.listen(
      (data) {
        if (unauthenticated case final prefix?) {
          prefix.add(data);
          final bytes = prefix.toBytes();
          final newline = bytes.indexOf(10);
          if (newline < 0) {
            if (bytes.length > 256) sock.destroy();
            return;
          }
          final token = sessionControl?.token;
          if (token == null ||
              utf8.decode(bytes.sublist(0, newline), allowMalformed: true) !=
                  token) {
            sock.destroy();
            return;
          }
          unauthenticated = null;
          openRaw(Uint8List.sublistView(bytes, newline + 1));
          return;
        }
        final reader = sniffing;
        if (reader == null) {
          if (rawChannel == null) {
            openRaw(data);
          } else {
            forward(data);
          }
          return;
        }
        final DevFsPut? put;
        try {
          put = reader.add(data);
        } on FormatException {
          openRaw(Uint8List.fromList(reader.received));
          return;
        }
        final received = reader.received;
        final looksLikePut =
            received.length < 4 ||
            latin1.decode(received.sublist(0, 4)) == 'PUT ';
        final isDevFs =
            reader.method == 'PUT' && reader.headers!['dev_fs_name'] != null;
        if (!looksLikePut || (reader.method != null && !isDevFs)) {
          openRaw(Uint8List.fromList(received));
          return;
        }
        if (put == null) return;
        sniffing = null;
        final upload = put;
        final original = Uint8List.fromList(received);
        unawaited(() async {
          // The upload that revealed a native change is refused: the session
          // is ending, and it would only run new Dart against old native code.
          if (await nativeChanged()) {
            sock.destroy();
          } else if (devFsDelta) {
            await uploadDevFs(sock, upload);
          } else {
            openRaw(original);
          }
        }());
      },
      onDone: closeRaw,
      onError: (Object _) => closeRaw(),
    );
    // A host that cannot rebuild deltas (the pure-Dart desktop bridge) gets
    // the channel opened at accept.
    if (sniffing == null && unauthenticated == null) openRaw(Uint8List(0));
  }

  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen(accept);
  final deviceServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  deviceServer.listen((sock) => accept(sock, targetDevice));
  final logsServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  logsServer.listen((sock) => accept(sock, targetLogs));

  final local = vm.replace(host: '127.0.0.1', port: server.port);
  stderr.writeln('[rhr] tunneled VM service: $local');

  /// Hot reloads or restarts through `flutter attach`, as if the developer
  /// pressed r or R, and answers with what Flutter printed meanwhile, so a
  /// compile error reaches whoever asked.
  Future<SessionAnswer> hotReload({required bool restart}) async {
    final proc = attachProcess;
    final what = restart ? 'hot restart' : 'hot reload';
    if (proc == null) {
      return (
        ok: false,
        message: 'Flutter is not attached yet, so there is nothing to $what.',
        then: null,
      );
    }
    if (reloadInProgress || reloadAsked != null) {
      return (ok: false, message: 'A reload is already running.', then: null);
    }
    final asked = reloadAsked = Completer<bool>();
    reloadOutput.clear();
    try {
      proc.stdin.write(restart ? 'R' : 'r');
    } on StateError {
      reloadAsked = null;
      return (ok: false, message: 'Flutter has exited.', then: null);
    }
    var timedOut = false;
    final ok = await asked.future.timeout(
      const Duration(minutes: 3),
      onTimeout: () {
        reloadAsked = null;
        timedOut = true;
        return false;
      },
    );
    final printed = reloadOutput.toString().trim();
    reloadOutput.clear();
    return (
      ok: ok,
      message: [
        if (printed.isNotEmpty)
          printed
        else if (ok)
          'Done.'
        else
          '$what failed.',
        // Android freezes an app that is not in front, and a frozen app
        // cannot take a reload until it is back.
        if (timedOut)
          'Flutter did not finish the $what within 3 minutes. If the app is '
              'not in front on the phone, bring it back, then try again.',
      ].join('\n'),
      then: null,
    );
  }

  /// Streams RHR Agent to the phone, the way a debug app goes, and waits for
  /// the tester to confirm Android's install sheet.
  Future<SessionAnswer> installAgent() async {
    final certificate = playerCertificate;
    if (certificate == null) {
      return (
        ok: false,
        message: 'The player has not said how it is signed yet. Try again.',
        then: null,
      );
    }
    if (updateSender != null) {
      return (
        ok: false,
        message: 'Something is already being installed on the phone.',
        then: null,
      );
    }
    try {
      final apk = await agentApkFor(certificate);
      stderr.writeln('[rhr] Installing RHR Agent on the phone.');
      final sender = updateSender = PlayerUpdateSender(
        transport,
        kind: UpdateKind.app,
        target: agentPackage,
      );
      await sender.send(apk);
      return (
        ok: true,
        message:
            'RHR Agent is installed. The phone now shows its setup screen: the '
            'tester turns it on in Accessibility settings (on Android 13+, '
            'App info > ⋮ > Allow restricted settings first).',
        then: null,
      );
    } on Object catch (error) {
      return (ok: false, message: '$error', then: null);
    } finally {
      updateSender = null;
    }
  }

  // Commands from another process for the phone this session holds (see
  // session_control.dart): `rhr persist` and `rhr release`, and `rhr mcp`
  // asking for a hot reload or restart. A release installed over this
  // session's own app kills it, so the session waits for [releaseEnding]
  // before it tears down, and then ends.
  Completer<void>? releaseEnding;
  var controlBusy = false;
  Future<SessionAnswer> control(String command) async {
    if (command == 'reload' || command == 'restart') {
      return hotReload(restart: command == 'restart');
    }
    if (command == 'install_agent') return installAgent();
    final prepared = preparation;
    if (prepared == null) {
      return (
        ok: false,
        message: '$command needs a session started by rhr run.',
        then: null,
      );
    }
    if (controlBusy) {
      return (
        ok: false,
        message: 'This session is already persisting or installing a build.',
        then: null,
      );
    }
    controlBusy = true;
    try {
      switch (command) {
        case 'persist':
          if (sessionRoute != RunRoute.app) {
            return (
              ok: false,
              message:
                  'This project runs inside the player, and persist only '
                  'works for projects that run as their own app.',
              then: null,
            );
          }
          stderr.writeln(
            '[rhr] Persisting: rebuilding your app from the current code and '
            'reinstalling it. The session reattaches afterwards.',
          );
          final persisted = prepared.progress.requestPersist();
          fatalExit = _reprepare;
          if (!wsDied.isCompleted) wsDied.complete();
          await persisted;
          return (
            ok: true,
            message: 'The app on the phone now starts with the current code.',
            then: null,
          );
        case 'release':
          stderr.writeln('[rhr] Building and installing a release build.');
          final replacesThisApp = sessionRoute == RunRoute.app;
          final ending = replacesThisApp ? Completer<void>() : null;
          releaseEnding = ending;
          try {
            await prepared.release();
          } catch (_) {
            releaseEnding = null;
            ending?.complete();
            rethrow;
          }
          if (ending == null) {
            return (
              ok: true,
              message: 'The release build is installed.',
              then: null,
            );
          }
          return (
            ok: true,
            message:
                'The release build is installed. It replaced the debug app, '
                'so the rhr session has ended.',
            then: () {
              stderr.writeln(
                '[rhr] The release build replaced the debug app, so this '
                'session has ended. Run rhr again to go back to the debug app.',
              );
              fatalExit = 0;
              ending.complete();
              if (!wsDied.isCompleted) wsDied.complete();
            },
          );
        default:
          return (ok: false, message: 'Unknown command: $command', then: null);
      }
    } on Object catch (error) {
      stderr.writeln('[rhr] $command failed: $error');
      return (ok: false, message: '$error', then: null);
    } finally {
      controlBusy = false;
    }
  }

  sessionControl = await SessionControl.serve(
    project,
    control,
    endpoints: {
      'vm': '$local',
      'device': deviceServer.port,
      'logs': logsServer.port,
      'app': ?sessionPackage,
    },
  );

  Future<void> cleanup() async {
    reloadFeedbackTimer?.cancel();
    preparation?.close();
    keepalive.cancel();
    if (!sessionOver.isCompleted) sessionOver.complete();
    await sessionControl?.close();
    await server.close();
    await deviceServer.close();
    await logsServer.close();
    for (final s in accepted.toList()) {
      s.destroy();
    }
    sockets.clear();
    // The session loop reconnects, so the handler must go with this attempt
    // or every retry stacks another one.
    await interrupts.cancel();
    await terminations.cancel();
    await hangups.cancel();
    // A final exit hands the device back; a reconnect keeps the claim.
    if (fatalExit != null && fatalExit != _reprepare) relayTransport.release();
    // Farewell so the phone leaves "Connected" immediately instead of waiting
    // out its 45s presence lease. Harmless if the socket already died (relay
    // drop) — but a swallowed failure here is why a tester was left reading
    // "Can't reach relay — retrying…" after a clean quit, so it gets logged.
    sayGoodbye();
    await transport.close();
  }

  if (!runFlutter) {
    onReady?.call();
    await wsDied.future; // keep tunneling until the relay drops
    await cleanup();
    final failure = directFailure;
    if (failure != null && fatalExit == null) throw failure;
    return fatalExit;
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

  final proc = await Process.start(projectFlutterExecutable(project), [
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
  ], workingDirectory: project);

  var sessionActive = true;
  void lostConnection() {
    sessionActive = false;
    if (!wsDied.isCompleted) wsDied.complete();
  }

  void reportProgress(String phase, int done, int total) {
    if (!sessionActive) return;
    transport.sendControl(
      jsonEncode({
        't': 'progress',
        'phase': phase,
        'done': done,
        'total': total,
      }),
    );
  }

  void captureReloadOutput(String chunk) {
    if (reloadAsked == null || reloadOutput.length > 16 * 1024) return;
    reloadOutput.write(chunk);
  }

  void onReloadEvent(FlutterReloadEvent event) {
    if (!sessionActive) return;
    reloadFeedbackTimer?.cancel();
    reloadInProgress =
        event == FlutterReloadEvent.reloading ||
        event == FlutterReloadEvent.restarting;
    reportProgress(
      switch (event) {
        FlutterReloadEvent.reloading => 'reloading',
        FlutterReloadEvent.restarting => 'restarting',
        FlutterReloadEvent.completed => 'reload_complete',
        FlutterReloadEvent.failed => 'reload_failed',
      },
      0,
      0,
    );
    if (event == FlutterReloadEvent.completed ||
        event == FlutterReloadEvent.failed) {
      final asked = reloadAsked;
      reloadAsked = null;
      if (asked != null && !asked.isCompleted) {
        asked.complete(event == FlutterReloadEvent.completed);
      }
    }
    if (event == FlutterReloadEvent.completed) {
      reloadFeedbackTimer = Timer(
        const Duration(seconds: 2),
        () => reportProgress('ready', 0, 0),
      );
    }
  }

  final output = Future.wait([
    forwardFlutterOutput(
      proc.stdout,
      stdout,
      lostConnection,
      onReloadEvent: onReloadEvent,
      onOutput: captureReloadOutput,
    ),
    forwardFlutterOutput(
      proc.stderr,
      stderr,
      lostConnection,
      onReloadEvent: onReloadEvent,
      onOutput: captureReloadOutput,
    ),
  ]);
  bool? wasLineMode;
  bool? wasEchoMode;
  restoreTerminal = () {
    try {
      if (wasLineMode != null) stdin.lineMode = wasLineMode;
      if (wasEchoMode != null) stdin.echoMode = wasEchoMode;
    } on StdinException {
      // The terminal may have closed with the session.
    }
  };
  attachProcess = proc;
  try {
    if (stdin.hasTerminal) {
      wasLineMode = stdin.lineMode;
      wasEchoMode = stdin.echoMode;
      stdin.echoMode = false;
      stdin.lineMode = false;
    }
  } on StdinException {
    restoreTerminal();
  }
  // The child may close its input before the subscription is cancelled.
  proc.stdin.done.catchError((Object _) {});
  final input = terminalInput.listen((bytes) {
    try {
      proc.stdin.add(bytes);
    } on StateError {
      // Flutter has already exited.
    }
  });
  final flutterExit = () async {
    final code = await proc.exitCode;
    sessionActive = false;
    await input.cancel();
    restoreTerminal?.call();
    await output;
    return code;
  }();
  if (effectiveSyncAssets || prepareRun || onReady != null) {
    unawaited(() async {
      try {
        if (effectiveSyncAssets) {
          await _syncAssetsAfterAttach(
            local,
            project,
            effectivePidFile,
            assetStoreId: assetStoreId,
            maxConcurrentUploads: 4,
            onProgress: reportProgress,
          );
        } else {
          final deadline = DateTime.now().add(const Duration(minutes: 3));
          while (!File(effectivePidFile).existsSync()) {
            if (!sessionActive) return;
            if (DateTime.now().isAfter(deadline)) {
              throw TimeoutException(
                'Flutter did not attach to the debug app.',
              );
            }
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          if (prepareRun && !await isProjectRunning(local, project)) {
            throw StateError(
              'The connected runtime is not running this project.',
            );
          }
          if (staleDart) {
            // The installed app predates the latest Dart edits; its APK
            // was reused because only native changes need a new one.
            stderr.writeln(
              '[rhr] the installed app has older Dart code; hot restarting',
            );
            final pid = int.parse(
              File(effectivePidFile).readAsStringSync().trim(),
            );
            await trackHotRestart(
              vmService: local,
              trigger: () => Process.killPid(pid, ProcessSignal.sigusr2),
              onProgress: reportProgress,
            );
          }
        }
        if (sessionActive) {
          onReady?.call();
          stderr.writeln(
            effectiveSyncAssets || prepareRun
                ? '[rhr] Ready. Your project is running on the phone.'
                : '[rhr] Ready. Flutter is attached.',
          );
          reportProgress('ready', 0, 0);
        }
      } catch (error) {
        if (!sessionActive) return;
        stderr.writeln('[rhr] Could not start your project: $error');
        transport.sendControl(
          jsonEncode({
            't': 'progress',
            'phase': 'preparation_failed',
            'message': '$error',
            'done': 0,
            'total': 0,
          }),
        );
        fatalExit = 78;
        proc.kill();
      }
    }());
  }

  // Whichever ends first decides: flutter exiting on its own ends the CLI;
  // the relay dying means we kill flutter and reconnect.
  final ended = await Future.any<Object>([
    flutterExit.then((c) => c),
    wsDied.future.then((_) => const _RelayEnded()),
  ]);
  // Installing a release over this session's app is what just ended Flutter;
  // finish that install before anything is torn down.
  await releaseEnding?.future;
  sessionActive = false;
  if (ended is _RelayEnded) {
    proc.kill();
    await flutterExit; // reap
    await cleanup();
    final failure = directFailure;
    if (failure != null && fatalExit == null) throw failure;
    return fatalExit;
  }
  if (fatalExit != null) {
    await cleanup();
    return fatalExit;
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
      if (failure != null && fatalExit == null) throw failure;
      return fatalExit; // null: reconnect
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
  _DeadlineHolder deadline, {

  /// Whether an update is streaming to the device right now. The reminder
  /// below asks the developer to check that the player is connected, which
  /// is unhelpful advice while we are mid-transfer to it.
  bool Function()? updating,
}) async {
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
    if (updating?.call() ?? false) continue;
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
      '[rhr] update the player over the wire to Flutter '
      '${local.frameworkVersion}? [Y/n] ',
    );
    final answer =
        (await terminalInput
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

  final sender = PlayerUpdateSender(transport);
  attach(sender);
  try {
    // The build takes minutes. Say so on the phone, which is otherwise
    // staring at a session that has gone quiet.
    transport.sendControl(
      jsonEncode({'t': 'progress', 'phase': 'building', 'done': 0, 'total': 0}),
    );
    // Building can take minutes and the install needs the tester to reopen
    // the player; keep the bridge wait from expiring under either.
    deadline.value = DateTime.now().add(const Duration(minutes: 20));
    final flutterExecutable = projectFlutterExecutable(project);
    final apk = await buildUpdatePlayerApk(
      project: project,
      template: await resolvePlayerTemplate(),
      frameworkRevision: local.frameworkRevision,
      flutterExecutable: flutterExecutable,
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
    // Report the ending, not just the middle. Every failure path already
    // says something; success said nothing at all, so the phone kept the
    // last percentage the transfer happened to reach and wore it through
    // the install and into whatever screen came next. A phase that goes up
    // has to come down.
    transport.sendControl(
      jsonEncode({
        't': 'progress',
        'phase': switch (outcome) {
          // Android is showing the install sheet: the tester has to tap.
          PlayerUpdateOutcome.pendingUser => 'install_confirm',
          // Handed to PackageInstaller, or already on disk.
          PlayerUpdateOutcome.committed => 'installing',
          PlayerUpdateOutcome.installed => 'installed',
        },
        'done': 0,
        'total': 0,
      }),
    );
    stderr.writeln(switch (outcome) {
      PlayerUpdateOutcome.committed =>
        '[rhr] update installing — reopen the rhr player on the device; '
            'the session resumes automatically.',
      PlayerUpdateOutcome.pendingUser =>
        '[rhr] confirm the install on the device, then reopen the rhr '
            'player; the session resumes automatically.',
      PlayerUpdateOutcome.installed => '[rhr] update installed on the device.',
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
    await Future<void>.delayed(const Duration(milliseconds: 100));
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
      if (!changed && await isProjectRunning(vmService, project)) {
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
      if (!await isProjectRunning(vmService, project)) {
        throw StateError(
          'The phone restarted but did not launch this project.',
        );
      }
    },
  );
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
  RunRoute? routeOverride,
  RunTask task = RunTask.session,
}) async {
  if (!File('$project/pubspec.yaml').existsSync()) {
    stderr.writeln(
      '[rhr] Run rhr inside a Flutter project, or pass --project <directory>.',
    );
    return 64;
  }
  stderr.writeln('[rhr] resolving project dependencies...');
  final dependencies = await Process.run(projectFlutterExecutable(project), [
    'pub',
    'get',
  ], workingDirectory: project);
  if (dependencies.exitCode != 0) {
    stderr.writeln(
      '[rhr] Could not resolve project dependencies:\n${dependencies.stdout}\n${dependencies.stderr}',
    );
    return 78;
  }
  final config = _loadConfig(project);
  // Same order `attach` uses: an explicit flag, then the project's own
  // config, then a fresh code. `run` used to mint before reading the config
  // at all, so a project that pinned a code got a different one every time
  // and nobody could tell why.
  final savedSession = File('$project/.dart_tool/rhr/session.json');
  String? savedCode;
  if (savedSession.existsSync()) {
    try {
      final saved = jsonDecode(savedSession.readAsStringSync());
      if (saved is Map<String, dynamic> &&
          saved['relay'] == (relay ?? config['relay'])) {
        final created = DateTime.tryParse('${saved['created']}');
        final candidate = saved['code'];
        if (created != null &&
            DateTime.now().difference(created) < const Duration(hours: 24) &&
            candidate is String &&
            isValidRhrSessionCode(candidate))
          savedCode = candidate;
      }
    } on FormatException {
      // A partial receipt cannot authorize reuse of a session.
    }
  }
  final sessionCode =
      code ?? config['code'] ?? savedCode ?? mintRhrSessionCode();
  _requireValidSessionCode(sessionCode);
  savedSession.parent.createSync(recursive: true);
  savedSession.writeAsStringSync(
    jsonEncode({
      'code': sessionCode,
      'relay': relay ?? config['relay'],
      'created': DateTime.now().toUtc().toIso8601String(),
    }),
    flush: true,
  );
  if (!Platform.isWindows)
    await Process.run('chmod', ['600', savedSession.path]);
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
      : jsonEncode({'code': sessionCode, 'relays': deviceRelays});
  final qr = renderTerminalQr(qrPayload);
  final deepLink = sessionConnectionLink(sessionCode, deviceRelays);
  final link = sessionConnectionWebLink(deepLink).toString();
  final connectionFile = File('$project/.dart_tool/rhr/connection.json');
  await connectionFile.parent.create(recursive: true);
  await connectionFile.writeAsString(
    jsonEncode({
      'code': sessionCode,
      'url': link,
      'deepLink': deepLink.toString(),
      'relays': deviceRelays,
      'qrPayload': qrPayload,
    }),
  );
  if (!Platform.isWindows) {
    await Process.run('chmod', ['600', connectionFile.path]);
  }
  stderr.write(
    '\nTap to connect: $link\nSession code: $sessionCode\n'
    'Connection JSON: ${connectionFile.absolute.path}\n\n'
    '${qr.text}\n  Scan with the RHR player\n\n',
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
    if (resync) {
      final manifest = File('$project/.dart_tool/rhr/pushed_assets.json');
      if (manifest.existsSync()) manifest.deleteSync();
    }

    final runProgress = RunProgress();
    final reconnectBackoff = ReconnectBackoff();
    var transferRetries = 0;
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
          prepareRun: true,
          task: task,
          runProgress: runProgress,
          routeOverride: routeOverride,
          onReady: reconnectBackoff.markReady,
        );
        if (result == 0) return 0;
        if (result == _noDeviceExitCode ||
            result == _relayBinaryExitCode ||
            result == _approvalExitCode ||
            result == 78) {
          return result!;
        }
        if (result == _reprepare) continue;
        stderr.writeln(
          '[rhr] Flutter attach ended${result == null ? '' : ' ($result)'}.',
        );
      } on DirectTransportFailure catch (failure) {
        // A relay that drops while WebRTC is still negotiating has not told us
        // a direct path is impossible, only that this attempt lost its
        // signaling channel. The recovery loop below re-dials, which is what
        // every other transient failure here already does.
        if (failure.transient) {
          stderr.writeln('[rhr] direct path dropped: $failure');
          if (reconnectBackoff.directPathImpossible(failure)) {
            stderr.writeln(_noDirectPath);
            return _directFailureExitCode;
          }
        } else {
          stderr.writeln('[rhr] direct connection failed: $failure');
          return _directFailureExitCode;
        }
      } on PlayerUpdateFailure catch (failure) {
        if (!failure.retryable || ++transferRetries >= 3) {
          stderr.writeln(
            '[rhr] $failure Transfer could not finish after retries. Run rhr again when the connection is stable.',
          );
          return 78;
        }
        stderr.writeln(
          '[rhr] $failure Reconnecting and reusing the built APK.',
        );
      } on DeviceBusyException catch (busy) {
        // Reconnecting cannot win a device someone else is holding; it would
        // only spin until they leave. Report and quit so the operator can pick
        // another device or wait deliberately.
        stderr.writeln('[rhr] $busy');
        return _deviceBusyExitCode;
      } on Exception catch (error) {
        stderr.writeln('[rhr] session error: $error');
      }
      final delay = reconnectBackoff.nextDelay();
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
  final wanted =
      device ?? (code == null ? await preferredDevice(project) : null);
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
  const base = String.fromEnvironment(
    'RHR_LOGIN_BASE',
    defaultValue: defaultLoginBase,
  );
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
/// The command the `rhr` Flutter device runs `device-run` with: a path that
/// outlives updates. Registering a path into the running script's folder
/// pinned whichever checkout or pub cache snapshot ran setup, and went stale
/// when that moved.
List<String> _stableRhrCommand() {
  if (File(launcherPath).existsSync()) return [launcherPath];
  final installed = installedRhr();
  if (installed != null) return [installed];
  // A source checkout: run it the way it runs now.
  return [
    Platform.resolvedExecutable,
    'run',
    File.fromUri(Platform.script).absolute.path,
  ];
}

/// The registered `rhr` device's runDebug command, or null when there is no
/// such device.
Future<List<String>?> _registeredRunDebug() async {
  final listed = await Process.run('flutter', ['custom-devices', 'list']);
  final file = RegExp(
    r'List of custom devices in "([^"]+)"',
  ).firstMatch('${listed.stdout}')?.group(1);
  if (file == null || !File(file).existsSync()) return null;
  final devices =
      (jsonDecode(File(file).readAsStringSync()) as Map)['custom-devices'];
  for (final device in devices is List ? devices : const []) {
    if (device is Map && device['id'] == 'rhr' && device['runDebug'] is List) {
      return [for (final part in device['runDebug'] as List) '$part'];
    }
  }
  return null;
}

/// Registers the `rhr` Flutter device when it is missing or runs a command
/// that no longer exists, so a session works without a separate `rhr setup`
/// step. Keeps a relay the developer registered. Quiet when the device is
/// right, and never fatal: if registration fails, the attach below reports
/// the real problem with Flutter's own message.
Future<void> ensureRhrDevice() async {
  List<String>? registered;
  try {
    registered = await _registeredRunDebug();
  } on Object {
    return;
  }
  final expected = [..._stableRhrCommand(), 'device-run'];
  if (registered != null &&
      registered.length >= expected.length &&
      Iterable.generate(
        expected.length,
      ).every((i) => registered![i] == expected[i])) {
    return;
  }
  final relayAt = registered?.indexOf('--relay') ?? -1;
  final relay = relayAt >= 0 && relayAt + 1 < registered!.length
      ? registered[relayAt + 1]
      : null;
  stderr.writeln('[rhr] registering the "rhr" Flutter device…');
  try {
    await _setup(relay, quiet: true);
  } on Object catch (error) {
    stderr.writeln('[rhr] could not register the device automatically: $error');
    stderr.writeln('[rhr] run `rhr setup` if the attach below fails.');
  }
}

Future<void> _setup(String? relay, {bool quiet = false}) async {
  relay ??= const String.fromEnvironment(
    'RHR_RELAY',
    defaultValue: defaultPublicRelay,
  );

  if (!quiet) stderr.writeln('[rhr] enabling Flutter custom devices…');
  final en = await Process.run('flutter', [
    'config',
    '--enable-custom-devices',
  ]);
  if (en.exitCode != 0) {
    // Called from a live session, exiting would take the session with it.
    if (quiet) throw StateError('could not enable custom devices');
    stderr.writeln('[rhr] could not enable custom devices:\n${en.stderr}');
    exit(1);
  }

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
    'runDebug': [..._stableRhrCommand(), 'device-run', '--relay', relay],
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
    if (quiet) throw StateError('failed to register device');
    stderr.writeln('[rhr] failed to register device:\n${add.stderr}');
    exit(1);
  }

  if (quiet) {
    stderr.writeln('[rhr] "rhr" device registered.');
    return;
  }

  stderr.writeln('''
[rhr] The "rhr" Flutter device is registered.

  Relay: $relay

  Next:
    1. From a Flutter project, run:  rhr run
    2. A QR appears — the tester scans it in the rhr player.
    3. The app launches automatically. Type r to hot reload.

  Cursor/VS Code manual flow:
    Pick "rhr (remote QA phone)" as the device and use the normal Run button.
''');
}

/// `RHR_WEBRTC_LOG=1`: timestamped ICE, DTLS and connection-state logs from
/// the WebRTC library on stderr, for diagnosing a direct path that drops.
/// The per-packet loggers stay at INFO; their volume would slow the very
/// transfer being diagnosed.
void _logWebRtc() {
  hierarchicalLoggingEnabled = true;
  WebRtcLogging.root.level = Level.FINE;
  for (final perPacket in [
    WebRtcLogging.sctp,
    WebRtcLogging.datachannel,
    WebRtcLogging.transportDemux,
    WebRtcLogging.dtlsRecord,
    WebRtcLogging.dtlsCipher,
    WebRtcLogging.srtp,
  ]) {
    perPacket.level = Level.INFO;
  }
  WebRtcLogging.root.onRecord.listen(
    (r) => stderr.writeln(
      '${r.time.toIso8601String()} ${r.level.name} [${r.loggerName}] '
      '${r.message}',
    ),
  );
}

/// The phone rejects a malformed code without saying so, which leaves both
/// ends waiting on a session that can never form. Refuse it here instead.
void _requireValidSessionCode(String code) {
  if (isValidRhrSessionCode(code)) return;
  stderr.writeln(
    '[rhr] "$code" is not a session code. Codes look like rhr-7kqp-3mzx-t9fa: '
    'three groups of four from a-z and 2-9, without i, l, o, 0 or 1. '
    'Leave out --code to get a new one.',
  );
  exit(64);
}

/// Files the phone has confirmed storing, per project (see [DevFsBases]).
final _devFsBasesByProject = <String, DevFsBases>{};

DevFsBases _devFsBasesFor(String project) => _devFsBasesByProject.putIfAbsent(
  project,
  () => DevFsBases(Directory('$project/.dart_tool/rhr/devfs-bases')),
);

/// Why RHR stops when the phone and this computer never open a direct route.
/// RHR carries app data only directly, never through its relay, so the fix
/// is a different network, not another retry.
const _noDirectPath =
    '[rhr] The phone and this computer cannot connect directly on their '
    'current networks. They found each other through the relay, but no direct '
    'route opened in ${ReconnectBackoff.noPathLimit} attempts. RHR sends app '
    'data only over a direct connection. Try another network for this '
    'computer or the phone (a phone hotspot often works), or turn off a VPN, '
    'then run rhr again.';
