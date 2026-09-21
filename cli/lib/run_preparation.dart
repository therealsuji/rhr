import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'apk_identity.dart';
import 'flutter_compatibility.dart';
import 'player_builder.dart';
import 'player_update.dart';
import 'project_apk.dart';
import 'relay_race.dart';

enum RunRoute { player, app }

RunRoute selectRunRoute(
  ProjectCompatibilityProfile project,
  Map<String, dynamic> player,
) {
  final plugins = parseAndroidPluginProfile(player['androidPlugins']);
  final missingNativeInput =
      project.unsupportedAndroidInputs.isNotEmpty ||
      project.androidPlugins.entries.any(
        (entry) => plugins[entry.key] != entry.value,
      ) ||
      androidPermissionDifferences(
        required: project.androidPermissions,
        available: parseAndroidPermissionProfile(player['androidPermissions']),
      ).isNotEmpty;
  return missingNativeInput ? RunRoute.app : RunRoute.player;
}

final class PreparedRun {
  const PreparedRun(this.vm, this.assetStoreId, this.route);
  final Uri vm;
  final String assetStoreId;
  final RunRoute route;
}

/// Reconnects reuse approvals; APK receipts independently validate build inputs.
final class RunProgress {
  final approvedPlans = <String>{};
  bool playerUpdateSubmitted = false;
}

/// Owns preparation on the same connection that later carries the VM tunnel.
final class RunPreparation {
  RunPreparation({
    required this.transport,
    required this.project,
    required this.profile,
    required this.policy,
    this.routeOverride,
    RunProgress? progress,
  }) : progress = progress ?? RunProgress();

  final SessionTransport transport;
  final String project;
  final ProjectCompatibilityProfile profile;
  final PlayerUpdatePolicy policy;
  final RunRoute? routeOverride;
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

  void phase(String name, String message) {
    if (_closed.isCompleted) return;
    stderr.writeln('[rhr] $message');
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
      throw StateError(
        '$plan Run `rhr run --yes` to approve the required build and installation.',
      );
    }
    stderr.write('[rhr] Continue? [y/N] ');
    final answer = (await _connected(
      stdin.transform(utf8.decoder).transform(const LineSplitter()).first,
    )).trim().toLowerCase();
    if (answer != 'y' && answer != 'yes')
      throw StateError('Preparation canceled. No installation was started.');
    progress.approvedPlans.add(approval);
  }

  Future<void> _deliver(File apk, {required bool player}) async {
    final identity = await readApkIdentity(apk);
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
      if (actual['apkSha256'] != expected || actual['debuggable'] != true) {
        throw StateError(
          'Android reported installation, but the expected debug APK is not installed.',
        );
      }
    } finally {
      _sender = null;
      sender.close();
    }
  }

  Future<PreparedRun> run() async {
    final info = await _connected(_firstInfo.future);
    if (info['runProtocol'] != 1) {
      throw StateError(
        'This player needs the connection-first RHR update. Install a current player before using rhr run. '
        '`rhr attach` remains available for manual sessions.',
      );
    }
    _deviceId = '${info['deviceId']}';
    phase(
      'checking',
      'Phone connected: ${info['deviceName'] ?? 'Android'}. Checking the project.',
    );
    final raw = info['compatibility'];
    if (raw is! Map<String, dynamic>)
      throw const FormatException('The player did not report its runtime.');
    final route = routeOverride ?? selectRunRoute(profile, raw);
    if (routeOverride == RunRoute.player &&
        selectRunRoute(profile, raw) == RunRoute.app) {
      throw StateError(
        'This project needs its own native app. Use --mode app or --mode auto.',
      );
    }
    if (route == RunRoute.app) {
      phase('checking', 'This project will run as a separate debug app.');
      await _setup('connector');
      await _setup('install_permission');
      final inputs = await projectBuildIdentity(project, profile.flutter);
      var apk = await cachedProjectApk(project, inputs);
      var approvedBuild = false;
      if (apk == null) {
        await _approve(
          "Build this project's debug APK and install it if the phone needs it.",
        );
        approvedBuild = true;
        phase('building', 'Building your debug app.');
        apk = await buildProjectDebugApk(
          project: project,
          output: '$project/.dart_tool/rhr/app-debug.apk',
          flutterExecutable: projectFlutterExecutable(project),
          targetPlatform: 'android-arm64',
        );
        final afterBuild = await projectBuildIdentity(project, profile.flutter);
        if (afterBuild != inputs) {
          throw StateError(
            'Build inputs changed while the APK was being built. Run rhr again before installing it.',
          );
        }
        await recordProjectApk(project, inputs, apk);
      }
      final identity = await readApkIdentity(apk);
      final expected = (await sha256.bind(apk.openRead()).first).toString();
      final installed = await request('inspect', package: identity.package);
      if (installed['apkSha256'] != expected ||
          installed['debuggable'] != true) {
        if (!approvedBuild)
          await _approve(
            'Install the current debug build of ${identity.package}.',
          );
        await _deliver(apk, player: false);
      } else {
        phase('checking', 'The correct debug app is already installed.');
      }
      phase('launching', 'Opening ${identity.package}.');
      final launched = await request('launch', package: identity.package);
      final vm = Uri.parse(launched['vm'] as String);
      return PreparedRun(vm, '', route);
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
    return PreparedRun(vm, store, route);
  }
}

final class RunDisconnected implements Exception {
  const RunDisconnected();
}
