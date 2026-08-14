// Desktop stand-in for a phone: run with --enable-vm-service so the bridge
// has a real VM service to tunnel.
//   dart run --enable-vm-service=0 example/fake_device.dart ws://127.0.0.1:8123 test
//
// Reports the LOCAL Flutter SDK's compatibility profile (same machine as the
// dev CLI, so the CLI's compatibility gate passes) plus a stable per-process
// asset-store id.
import 'dart:convert';
import 'dart:io';

import 'package:rhr_bridge/rhr_bridge.dart';

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
    'androidPlugins': <String, dynamic>{},
    'androidPermissions': <String>[],
  };
}

Future<void> main(List<String> args) async {
  final preferDirect = args.contains('--direct');
  RhrBridge.start(
    relayUrl: args[0],
    sessionCode: args[1],
    assetStoreId: 'fake-${DateTime.now().millisecondsSinceEpoch}',
    compatibility: _localCompatibility(),
    preferDirect: preferDirect,
  );
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
