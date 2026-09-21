// Desktop stand-in for a phone: run with --enable-vm-service so the bridge
// has a real VM service to tunnel.
//   dart run --enable-vm-service=0 example/fake_device.dart ws://127.0.0.1:8123 test
//
// Reports the LOCAL Flutter SDK's compatibility profile (same machine as the
// dev CLI, so the CLI's compatibility gate passes) plus a stable per-process
// asset-store id.
//
// Flags:
//   --direct            negotiate the WebRTC path instead of relaying
//   --connector         announce as a connector tunneling a third-party app
//   --outdated          report a Flutter version the CLI's gate will refuse,
//                       which is what makes it offer an update at all
//   --install=<how>     what to do once a transfer verifies:
//                       committed (default) | pending-user | installed | fail
//   --no-gzip           decline the dev's gzip offer and take the raw stream
//
// The update flags are what make the CLI's whole update path runnable
// without a phone: with --outdated the gate blocks, the CLI builds and
// streams an APK, and this answers as the player would — so the phases, the
// flow-control window, the gzip negotiation and every terminal state get
// exercised in CI rather than only on hardware.
import 'dart:convert';
import 'dart:developer' show Service;
import 'dart:io';

import 'package:rhr_bridge/fake_updater.dart';
import 'package:rhr_bridge/rhr_bridge.dart';

/// With `--outdated`, reports a Flutter revision that cannot match the
/// developer's, so the CLI's compatibility gate blocks and offers an update.
///
/// The gate compares revisions for equality, so a made-up one is enough and
/// is honest about being made up — the alternative is pinning a real old
/// SDK, which rots the moment the version in it stops being interesting.
Map<String, dynamic> _outdated(Map<String, dynamic> local, List<String> args) {
  if (!args.contains('--outdated')) return local;
  return {
    ...local,
    'frameworkVersion': '0.0.0-fake-outdated',
    'frameworkRevision': 'fake0outdated0revision',
  };
}

/// Parses `--install=<how>` into the outcome the fake phone will report.
FakeInstallOutcome _installOutcome(List<String> args) {
  final flag = args.firstWhere(
    (a) => a.startsWith('--install='),
    orElse: () => '',
  );
  return switch (flag.split('=').last) {
    'pending-user' => FakeInstallOutcome.pendingUser,
    'installed' => FakeInstallOutcome.installed,
    'fail' => FakeInstallOutcome.fail,
    _ => FakeInstallOutcome.committed,
  };
}

Map<String, dynamic> _localCompatibility() {
  final candidates = <File>[];
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    candidates.add(File('$flutterRoot/bin/cache/flutter.version.json'));
  }
  var directory = File(Platform.resolvedExecutable).absolute.parent;
  for (var i = 0; i < 8; i++) {
    candidates.add(File('${directory.path}/bin/cache/flutter.version.json'));
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  final versionFile = candidates.where((file) => file.existsSync()).firstOrNull;
  if (versionFile == null) {
    throw StateError('could not locate flutter.version.json');
  }
  final json =
      jsonDecode(versionFile.readAsStringSync()) as Map<String, dynamic>;
  return {
    'frameworkVersion': json['frameworkVersion'],
    'frameworkRevision': json['frameworkRevision'],
    'engineRevision': json['engineRevision'],
    'dartSdkVersion': json['dartSdkVersion'],
    'channel': json['channel'],
    'androidPlugins': <String, dynamic>{},
    // What the real player's manifest declares. Claiming none made the
    // compatibility gate block every project on the spot — every Flutter app
    // needs INTERNET — so the gate could never be observed PASSING, which is
    // half of what it does. Keep this in step with
    // player/android/app/src/main/AndroidManifest.xml.
    'androidPermissions': const <String>[
      'android.permission.ACCESS_COARSE_LOCATION',
      'android.permission.ACCESS_FINE_LOCATION',
      'android.permission.BLUETOOTH',
      'android.permission.BLUETOOTH_ADMIN',
      'android.permission.BLUETOOTH_CONNECT',
      'android.permission.BLUETOOTH_SCAN',
      'android.permission.CAMERA',
      'android.permission.FOREGROUND_SERVICE',
      'android.permission.FOREGROUND_SERVICE_DATA_SYNC',
      'android.permission.FOREGROUND_SERVICE_SPECIAL_USE',
      'android.permission.INTERNET',
      'android.permission.POST_NOTIFICATIONS',
      'android.permission.READ_EXTERNAL_STORAGE',
      'android.permission.REQUEST_INSTALL_PACKAGES',
      'android.permission.SYSTEM_ALERT_WINDOW',
      'android.permission.WRITE_EXTERNAL_STORAGE',
    ],
  };
}

Future<void> main(List<String> args) async {
  final preferDirect = args.contains('--direct');

  // Print the phase sequence the developer sends. This is what the phone's
  // progress card is drawn from, so seeing it here is how the banner
  // wording gets checked without holding a phone. Percentages are only
  // printed when they move, or a 60 MB transfer buries the log.
  var lastPercent = -1;
  RhrBridge.onProgress =
      ({
        required String phase,
        required int done,
        required int total,
        required String message,
      }) {
        final percent = total > 0 ? (done * 100 / total).round() : -1;
        if (phase == 'updating' && percent == lastPercent) return;
        lastPercent = percent;
        stderr.writeln(
          '[phase] ${phase.isEmpty ? '(cleared)' : phase}'
          '${total > 0 ? ' $done/$total = $percent%' : ''}'
          '${message.isEmpty ? '' : ' — $message'}',
        );
      };

  // Answer update transfers as the player does. Installed unconditionally:
  // a session that is never offered an update never builds a handler, so
  // this costs nothing until the CLI actually starts one.
  RhrBridge.updateHandlerFactory = ({required sendText, required sendBinary}) =>
      FakeUpdater(
        sendText: sendText,
        outcome: _installOutcome(args),
        acceptGzip: !args.contains('--no-gzip'),
        onEvent: (event) => stderr.writeln('[fake_updater] $event'),
      );
  // --connector stands in for the player tunneling a THIRD-party app: it
  // announces host "connector" and deliberately omits the identity block,
  // because the identity would describe the player rather than the target.
  final connectorMode = args.contains('--connector');
  if (connectorMode) {
    // On a phone this URI is discovered out of the target's log. Here the
    // isolate's own service door stands in for it: what the test cares about
    // is the SHAPE of the hello, not whose VM answers.
    final own = (await Service.getInfo()).serverUri;
    if (own == null) {
      stderr.writeln('run with --enable-vm-service to use --connector');
      exit(2);
    }
    RhrBridge.startExternal(
      relayUrl: args[0],
      sessionCode: args[1],
      vmUri: own,
      preferDirect: preferDirect,
    );
  } else {
    RhrBridge.start(
      relayUrl: args[0],
      sessionCode: args[1],
      assetStoreId: 'fake-${DateTime.now().millisecondsSinceEpoch}',
      compatibility: _outdated(_localCompatibility(), args),
      preferDirect: preferDirect,
    );
  }
  // A clean close on termination so the local relay's device-death handling
  // (drop the dev connection) is exercised in tests.
  Future<void> shutDown() async {
    await RhrBridge.instance?.dispose();
    exit(0);
  }

  ProcessSignal.sigterm.watch().listen((_) => shutDown());
  ProcessSignal.sigint.watch().listen((_) => shutDown());
  await Future<void>.delayed(const Duration(days: 1));
}
