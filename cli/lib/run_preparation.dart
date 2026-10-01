import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'apk_identity.dart';
import 'beacon_build.dart';
import 'flutter_compatibility.dart';
import 'player_update.dart';
import 'project_apk.dart';
import 'relay_race.dart';
import 'terminal_io.dart';

enum RunRoute { player, app }

/// What a connection to the phone is for: a dev session, or one of the
/// explicit commands that install a build and end.
enum RunTask {
  session,

  /// `rhr persist`: install a debug build of the current code, so the app
  /// still runs it after it is killed and reopened.
  persist,

  /// `rhr release`: install a release build, with nothing of RHR in it.
  release,
}

RunRoute selectRunRoute(
  ProjectCompatibilityProfile project,
  Map<String, dynamic> player,
) => project.nativeDifferencesFrom(player).isEmpty
    ? RunRoute.player
    : RunRoute.app;

final class PreparedRun {
  const PreparedRun(
    this.vm,
    this.assetStoreId,
    this.route,
    this.package, {
    this.staleDart = false,
  });
  final Uri vm;
  final String assetStoreId;
  final RunRoute route;

  /// The Android package the project runs in: its own debug app, or the
  /// player that hosts it.
  final String package;

  /// The installed app was built from older Dart source than the project
  /// holds now. A hot restart after attaching brings it up to date.
  final bool staleDart;
}

/// Reconnects reuse approvals; APK receipts independently validate build inputs.
final class RunProgress {
  final approvedPlans = <String>{};
  bool playerUpdateSubmitted = false;

  Completer<void>? _persist;

  /// `rhr persist` sent to a running session: its next preparation installs
  /// a debug build of the current code, then attaches as usual. Completes
  /// once that build is installed.
  Future<void> requestPersist() => (_persist ??= Completer<void>()).future;

  bool get persistRequested => _persist != null;

  void _settlePersist([Object? error]) {
    final persist = _persist;
    _persist = null;
    if (persist == null) return;
    error == null ? persist.complete() : persist.completeError(error);
  }
}

/// Owns preparation on the same connection that later carries the VM tunnel.
final class RunPreparation {
  RunPreparation({
    required this.transport,
    required this.project,
    required this.profile,
    required this.policy,
    this.routeOverride,
    this.task = RunTask.session,
    RunProgress? progress,
  }) : progress = progress ?? RunProgress();

  final SessionTransport transport;
  final String project;
  final ProjectCompatibilityProfile profile;
  final PlayerUpdatePolicy policy;
  final RunRoute? routeOverride;
  final RunTask task;
  final RunProgress progress;
  String _deviceId = '';
  final _firstInfo = Completer<Map<String, dynamic>>();
  final _closed = Completer<void>();
  final _requests = <int, Completer<Map<String, dynamic>>>{};
  var _nextId = 0;
  PlayerUpdateSender? _sender;

  void handleMessage(Map<String, dynamic> message) {
    if (_sender?.handleMessage(message) ?? false) return;
    if (message['t'] == 'info' && !_firstInfo.isCompleted)
      _firstInfo.complete(message);
    if (message['t'] == 'run_response')
      _requests.remove(message['id'])?.complete(message);
  }

  void handleAck(int channel, int bytes) => _sender?.handleAck(channel, bytes);

  void close() {
    if (!_closed.isCompleted) _closed.complete();
    _sender?.close();
  }

  Future<T> _connected<T>(Future<T> operation) => Future.any([
    operation,
    _closed.future.then<T>((_) => throw const RunDisconnected()),
  ]);

  /// Reports a step to the developer's terminal and the phone's banner.
  /// [echo] false sends a tester-facing message to the phone only.
  void phase(String name, String message, {bool echo = true}) {
    if (_closed.isCompleted) return;
    if (echo) stderr.writeln('[rhr] $message');
    transport.sendControl(
      jsonEncode({
        't': 'progress',
        'phase': name,
        'message': message,
        'done': 0,
        'total': 0,
      }),
    );
  }

  Future<Map<String, dynamic>> request(String action, {String? package}) async {
    if (_closed.isCompleted) throw const RunDisconnected();
    final id = ++_nextId;
    final response = Completer<Map<String, dynamic>>();
    _requests[id] = response;
    try {
      transport.sendControl(
        jsonEncode({
          't': 'run_request',
          'id': id,
          'action': action,
          if (package != null) 'package': package,
        }),
      );
      final result = await _connected(
        response.future,
      ).timeout(const Duration(seconds: 90));
      if (result['ok'] != true)
        throw StateError('${result['message'] ?? 'Phone preparation failed.'}');
      return result;
    } finally {
      _requests.remove(id);
    }
  }

  Future<void> _setup(String action) async {
    final deadline = DateTime.now().add(const Duration(minutes: 10));
    String? previous;
    while (true) {
      final result = await request(action);
      if (result['ready'] == true) return;
      final message =
          '${result['message']} Open RHR and tap Complete phone setup.';
      if (message != previous) phase('setup', message);
      previous = message;
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException(
          'Phone setup is still incomplete. Complete it in RHR, then run rhr again.',
        );
      }
      await _connected(Future<void>.delayed(const Duration(seconds: 3)));
    }
  }

  Future<void> _approve(String plan) async {
    final approval = '$_deviceId:$plan';
    if (progress.approvedPlans.contains(approval)) return;
    phase('approval', plan);
    if (policy == PlayerUpdatePolicy.always) {
      progress.approvedPlans.add(approval);
      return;
    }
    if (policy == PlayerUpdatePolicy.never || !stdin.hasTerminal) {
      throw ApprovalRequired(plan);
    }
    stderr.write('[rhr] Continue? [y/N] ');
    final answer = await _connected(
      terminalInput
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .cast<String?>()
          .firstWhere((_) => true, orElse: () => null),
    );
    // Input that ends without a line is no one answering, not a "no".
    if (answer == null) throw ApprovalRequired(plan);
    final normalized = answer.trim().toLowerCase();
    if (normalized != 'y' && normalized != 'yes') {
      throw ApprovalRequired(plan, declined: true);
    }
    progress.approvedPlans.add(approval);
  }

  Future<void> _deliver(
    File apk, {
    required bool player,
    bool debuggable = true,
  }) async {
    final identity = await readApkIdentity(apk);
    if (identity.debuggable != debuggable) {
      throw StateError(
        debuggable
            ? 'The built APK is not debuggable. RHR requires a debug build.'
            : 'The release build is debuggable. Check the release build type.',
      );
    }
    final installed = await request('inspect', package: identity.package);
    if (installed['installed'] == true &&
        !(installed['certificates'] is List &&
            (installed['certificates'] as List).contains(
              identity.certificate,
            ))) {
      throw StateError(
        'Cannot update ${identity.package}: the installed app was signed with a different key. '
        'Use its original signing key. RHR will not uninstall it or erase its data.',
      );
    }
    await _setup('install_permission');
    phase('updating', player ? 'Sending player update.' : 'Sending your app.');
    final sender = PlayerUpdateSender(
      transport,
      kind: player ? UpdateKind.player : UpdateKind.app,
      target: identity.package,
    );
    _sender = sender;
    try {
      await _connected(transport.payloadReady);
      final outcome = await _connected(
        sender.send(
          apk,
          onProgress: (sent, total) {
            if (!_closed.isCompleted)
              transport.sendControl(
                jsonEncode({
                  't': 'progress',
                  'phase': 'updating',
                  'done': sent,
                  'total': total,
                }),
              );
          },
        ),
      );
      if (player) {
        progress.playerUpdateSubmitted = true;
        phase(
          outcome == PlayerUpdateOutcome.pendingUser
              ? 'install_confirm'
              : 'installing',
          'Confirm the update on the phone, then reopen RHR. This session will reconnect and verify it.',
        );
        // A self-update kills the phone process. A commit is not proof of installation.
        await _connected(sender.waitForInstallation());
        await _connected(Future<void>.delayed(const Duration(seconds: 30)));
        throw TimeoutException(
          'The updated player did not reconnect. Check installation on the phone.',
        );
      }
      final expected = (await sha256.bind(apk.openRead()).first).toString();
      final actual = await request('inspect', package: identity.package);
      if (actual['apkSha256'] != expected ||
          actual['debuggable'] != debuggable) {
        throw StateError(
          'Android reported installation, but the expected APK is not installed.',
        );
      }
    } finally {
      _sender = null;
      sender.close();
    }
  }

  /// Prepares the phone and returns the VM to attach to, or null once a
  /// [task] other than a session has finished.
  Future<PreparedRun?> run() async {
    try {
      return await _prepare();
    } catch (error) {
      progress._settlePersist(error);
      rethrow;
    }
  }

  Future<PreparedRun?> _prepare() async {
    final info = await _connected(_firstInfo.future);
    _deviceId = '${info['deviceId']}';
    phase(
      'checking',
      'Phone connected: ${info['deviceName'] ?? 'Android'}. Checking the project.',
    );
    if (task == RunTask.release) {
      await release();
      return null;
    }
    final raw = info['compatibility'];
    if (raw is! Map<String, dynamic>)
      throw const FormatException('The player did not report its runtime.');
    final route = routeOverride ?? selectRunRoute(profile, raw);
    final persist = task == RunTask.persist || progress.persistRequested;
    if (persist && route == RunRoute.player) {
      throw StateError(
        'This project runs inside the player, and persist only works for '
        'projects that run as their own app. It is not supported yet for '
        'player-hosted projects.',
      );
    }
    if (routeOverride == RunRoute.player &&
        selectRunRoute(profile, raw) == RunRoute.app) {
      throw StateError(
        'This project needs its own native app. Use --mode app or --mode auto.',
      );
    }
    if (route == RunRoute.app) {
      final reasons = profile.nativeDifferencesFrom(raw);
      phase(
        'checking',
        reasons.isEmpty
            ? 'This project will run as a separate debug app (--mode app).'
            : 'This project will run as a separate debug app: it needs native '
                  'code the player does not include.',
      );
      for (final reason in reasons) stderr.writeln('[rhr]   $reason');
      final beacon = beaconPlayerFrom(info);
      if (beacon == null) {
        throw StateError(
          'The player did not report the package and signing certificate a '
          'debug build should trust.',
        );
      }
      final projectInputs = await projectBuildIdentity(
        project,
        profile.flutter,
      );
      final inputs = [
        projectInputs.native,
        'beacon:$beaconVersion:${beacon.package}:${beacon.certificate}',
      ].join('|');
      final cached = await cachedProjectApk(project, inputs);
      // A plain run reuses an APK with older Dart and hot restarts it;
      // persisting is asking for an APK that holds the current Dart.
      final stale = persist && cached?.dart != projectInputs.dart;
      var apk = stale ? null : cached?.apk;
      var apkDart = stale ? null : cached?.dart;

      // Decide what needs doing before asking anyone for anything: the
      // developer approves real work, and the tester is never walked through
      // setup for a build the developer then declines.
      // Asking to persist is the approval.
      var current = false;
      if (apk == null) {
        if (!persist) {
          await _approve(
            "Build this project's debug app and install it on the phone.",
          );
        }
      } else {
        final package = (await readApkIdentity(apk)).package;
        final installed = await request('inspect', package: package);
        current =
            installed['debuggable'] == true &&
            installed['apkSha256'] ==
                (await sha256.bind(apk.openRead()).first).toString();
        if (!current && !persist) {
          await _approve('Install the current debug build of $package.');
        }
      }
      // The overlay carries the session controls, and holding it is what
      // lets the player open the app from the background.
      await _setup('beacon_setup');

      if (apk == null) {
        phase('building', 'Building your debug app.');
        apk = await (await buildBeaconDebugApk(
          project: project,
          player: beacon,
          targetPlatform: 'android-arm64',
        )).copy('$project/.dart_tool/rhr/app-debug.apk');
        final afterBuild = await projectBuildIdentity(project, profile.flutter);
        if (afterBuild != projectInputs) {
          throw StateError(
            'Build inputs changed while the APK was being built. Run rhr again before installing it.',
          );
        }
        await recordProjectApk(project, inputs, projectInputs.dart, apk);
        apkDart = projectInputs.dart;
      }
      // The package comes from the APK, not the Gradle file: a build type's
      // applicationIdSuffix only shows up in what Gradle produced.
      final package = (await readApkIdentity(apk)).package;
      if (current) {
        phase('checking', 'The correct debug app is already installed.');
      } else {
        await _deliver(apk, player: false);
      }
      if (persist) {
        progress._settlePersist();
        phase(
          'installed',
          'The app on the phone now starts with the current code.',
        );
        if (task == RunTask.persist) return null;
      }
      phase('launching', 'Opening $package.');
      final launched = await request('launch', package: package);
      final vm = Uri.parse(launched['vm'] as String);
      return PreparedRun(
        vm,
        '',
        route,
        package,
        staleDart: apkDart != projectInputs.dart,
      );
    }
    final report = profile.differencesFrom(raw);
    if (report.blockers.isNotEmpty) {
      if (progress.playerUpdateSubmitted) {
        throw StateError(
          'The player is still incompatible after its update. Check the installation on the phone.',
        );
      }
      await _approve(
        "Update the player to match this project's Flutter ${profile.flutter.frameworkVersion} runtime.",
      );
      await _setup('install_permission');
      phase('building', 'Building the compatible player.');
      final apk = await buildUpdatePlayerApk(
        project: project,
        template: await resolvePlayerTemplate(),
        frameworkRevision: profile.flutter.frameworkRevision,
        flutterExecutable: projectFlutterExecutable(project),
      );
      await _deliver(apk, player: true);
    }
    var hosted = await request('host_player');
    final runtimeDeadline = DateTime.now().add(const Duration(seconds: 45));
    while (hosted['ready'] != true &&
        DateTime.now().isBefore(runtimeDeadline)) {
      await _connected(Future<void>.delayed(const Duration(seconds: 1)));
      hosted = await request('host_player');
    }
    final vm = Uri.tryParse('${hosted['vm']}');
    if (vm == null || !vm.hasPort || vm.port == 0) {
      throw StateError(
        'The player runtime has not started. Reopen RHR and retry.',
      );
    }
    final store = info['assetStoreId'];
    if (store is! String || store.isEmpty)
      throw const FormatException('The player asset store is missing.');
    phase('building', 'Building the Android asset bundle.');
    final build = await Process.run(projectFlutterExecutable(project), [
      'build',
      'bundle',
      '--debug',
      '--target-platform',
      'android-arm64',
    ], workingDirectory: project);
    if (build.exitCode != 0)
      throw StateError(
        'Android bundle build failed:\n${build.stdout}\n${build.stderr}',
      );
    final player = info['playerPackage'];
    if (player is! String)
      throw const FormatException('The player did not report its package.');
    return PreparedRun(vm, store, route, player);
  }

  /// Builds the project's release APK, signed the way the project signs
  /// releases, with no beacon and nothing of RHR in it, and installs it
  /// through the player. Hot reload does not reach the result, by design.
  Future<void> release() async {
    phase('building', 'Building a release build of your app.');
    final build = await Process.run(projectFlutterExecutable(project), [
      'build',
      'apk',
      '--release',
    ], workingDirectory: project);
    if (build.exitCode != 0) {
      throw StateError(
        'Release build failed:\n${build.stdout}\n${build.stderr}',
      );
    }
    await _deliver(
      File('$project/build/app/outputs/flutter-apk/app-release.apk'),
      player: false,
      debuggable: false,
    );
    phase('installed', 'The release build is installed.');
  }
}

/// The player a beacon build should trust, as the player announced itself.
BeaconPlayer? beaconPlayerFrom(Map<String, dynamic> info) {
  final package = info['playerPackage'];
  final certificate = info['playerCertificate'];
  if (package is! String ||
      certificate is! String ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(certificate)) {
    return null;
  }
  return (package: package, certificate: certificate);
}

/// Work the run needs that the developer has not approved: no terminal to
/// ask in and no `--yes`, or a "no" at the prompt. Its own outcome, so the
/// terminal gets the command to run and the tester gets a message meant for
/// them, not the developer's error.
final class ApprovalRequired implements Exception {
  const ApprovalRequired(this.plan, {this.declined = false});

  final String plan;
  final bool declined;

  @override
  String toString() => plan;
}

final class RunDisconnected implements Exception {
  const RunDisconnected();
}
