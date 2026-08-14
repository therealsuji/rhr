// End-to-end session state-machine tests against the LOCAL Dart relay
// (relay/bin/relay.dart) with the bridge's desktop fake device.
//
// Covers the session state transitions hermetic-ally (no phone, no
// internet): dev-first pairing, the honest "waiting for device bridge" state
// when no peer exists, and the CLI recovery loop when the relay drops
// mid-session (the wsDied → reconnect → re-pair path).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

String _findRepo() {
  var dir = Directory.current;
  while (true) {
    if (File('${dir.path}/relay/bin/relay.dart').existsSync()) return dir.path;
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('repo root not found from ${Directory.current.path}');
    }
    dir = parent;
  }
}

final _repo = _findRepo();

Future<int> _freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}

/// Spawns a process and merges stdout+stderr into a shared line list.
Future<Process> _spawn(
  List<String> args, {
  required String workDir,
  required List<String> lines,
}) async {
  final p = await Process.start(Platform.resolvedExecutable, [
    'run',
    ...args,
  ], workingDirectory: workDir);
  void drain(Stream<List<int>> s) {
    s
        .transform(SystemEncoding().decoder)
        .transform(const LineSplitter())
        .listen(lines.add);
  }

  drain(p.stdout);
  drain(p.stderr);
  return p;
}

/// Waits until [re] matches one of [lines]; fails with the collected output.
Future<void> _waitFor(
  List<String> lines,
  RegExp re,
  String what, {
  Duration timeout = const Duration(seconds: 120),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (lines.any(re.hasMatch)) return;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  fail('timed out waiting for "$what". Output so far:\n${lines.join('\n')}');
}

void main() {
  late int port;
  late List<String> relayLines;
  late Process relay;

  setUp(() async {
    port = await _freePort();
    relayLines = [];
    relay = await _spawn(
      ['bin/relay.dart', '$port'],
      workDir: '$_repo/relay',
      lines: relayLines,
    );
    await _waitFor(relayLines, RegExp('listening'), 'relay up');
  });

  tearDown(() async {
    relay.kill();
    await relay.exitCode
        .timeout(const Duration(seconds: 10))
        .catchError((_) => 0);
  });

  test(
    'dev-first pairing: device arrives, tunnel opens',
    () async {
      final code = 'state-${DateTime.now().millisecondsSinceEpoch}';
      final cliLines = <String>[];
      final cli = await _spawn(
        [
          'bin/rhr.dart',
          'attach',
          '--no-flutter',
          '--relay',
          'ws://127.0.0.1:$port',
          '--code',
          code,
        ],
        workDir: '$_repo/cli',
        lines: cliLines,
      );
      addTearDown(() => cli.kill());

      await _waitFor(cliLines, RegExp('connected to relay'), 'cli connected');
      await _waitFor(
        cliLines,
        RegExp('waiting for device bridge'),
        'cli waiting for device',
      );

      final deviceLines = <String>[];
      final device = await _spawn(
        [
          '--enable-vm-service=0',
          'example/fake_device.dart',
          'ws://127.0.0.1:$port',
          code,
        ],
        workDir: '$_repo/bridge',
        lines: deviceLines,
      );
      addTearDown(() => device.kill());

      await _waitFor(
        cliLines,
        RegExp('device VM service:'),
        'cli learned the device VM URI',
      );
      await _waitFor(
        cliLines,
        RegExp('tunneled VM service:'),
        'cli exposed the tunneled VM URI',
      );
    },
    timeout: const Timeout(Duration(seconds: 240)),
  );

  test(
    'no peer: cli waits honestly instead of failing or hanging silently',
    () async {
      final code = 'nope-${DateTime.now().millisecondsSinceEpoch}';
      final cliLines = <String>[];
      final cli = await _spawn(
        [
          'bin/rhr.dart',
          'attach',
          '--no-flutter',
          '--relay',
          'ws://127.0.0.1:$port',
          '--code',
          code,
        ],
        workDir: '$_repo/cli',
        lines: cliLines,
      );
      addTearDown(() => cli.kill());

      await _waitFor(
        cliLines,
        RegExp('waiting for device bridge'),
        'cli waiting for device',
      );
      await Future<void>.delayed(const Duration(seconds: 5));
      expect(
        cliLines.any(RegExp('device VM service').hasMatch),
        isFalse,
        reason: 'no device must not pair',
      );
      expect(
        cliLines.any(RegExp('reconnecting').hasMatch),
        isFalse,
        reason: 'no relay failure must not trigger reconnect churn',
      );
    },
    timeout: const Timeout(Duration(seconds: 240)),
  );

  test(
    'relay drop mid-session: CLI recovery loop re-pairs',
    () async {
      final code = 'drop-${DateTime.now().millisecondsSinceEpoch}';
      final cliLines = <String>[];
      final cli = await _spawn(
        [
          'bin/rhr.dart',
          'attach',
          '--no-flutter',
          '--relay',
          'ws://127.0.0.1:$port',
          '--code',
          code,
        ],
        workDir: '$_repo/cli',
        lines: cliLines,
      );
      addTearDown(() => cli.kill());

      final deviceLines = <String>[];
      final device = await _spawn(
        [
          '--enable-vm-service=0',
          'example/fake_device.dart',
          'ws://127.0.0.1:$port',
          code,
        ],
        workDir: '$_repo/bridge',
        lines: deviceLines,
      );
      addTearDown(() => device.kill());

      await _waitFor(cliLines, RegExp('tunneled VM service:'), 'initial pair');

      // Drop the relay mid-session.
      relay.kill();
      await relay.exitCode
          .timeout(const Duration(seconds: 10))
          .catchError((_) => 0);
      await _waitFor(
        cliLines,
        RegExp('relay connection closed|reconnecting'),
        'cli noticed the drop',
      );

      // Bring the relay back on the same port; both ends re-dial.
      relay = await _spawn(
        ['bin/relay.dart', '$port'],
        workDir: '$_repo/relay',
        lines: relayLines,
      );
      await _waitFor(relayLines, RegExp('listening'), 'relay back up');

      await _waitFor(
        cliLines,
        RegExp('connected to relay'),
        'cli reconnected to relay',
      );
      await _waitFor(
        cliLines,
        RegExp('device VM service:'),
        'cli re-paired with the device after relay recovery',
      );
    },
    timeout: const Timeout(Duration(seconds: 240)),
  );

  test(
    'device death: relay drops the dev so the CLI recovery loop wakes',
    () async {
      final code = 'devdeath-${DateTime.now().millisecondsSinceEpoch}';
      final cliLines = <String>[];
      final cli = await _spawn(
        [
          'bin/rhr.dart',
          'attach',
          '--no-flutter',
          '--relay',
          'ws://127.0.0.1:$port',
          '--code',
          code,
        ],
        workDir: '$_repo/cli',
        lines: cliLines,
      );
      addTearDown(() => cli.kill());

      Future<Process> startDevice() => _spawn(
        [
          '--enable-vm-service=0',
          'example/fake_device.dart',
          'ws://127.0.0.1:$port',
          code,
        ],
        workDir: '$_repo/bridge',
        lines: [],
      );

      final device = await startDevice();
      addTearDown(() => device.kill());
      await _waitFor(cliLines, RegExp('tunneled VM service:'), 'initial pair');

      // Kill the phone stand-in. A session without a device is dead — the
      // relay must close the dev connection or flutter attach hangs forever.
      device.kill();
      await device.exitCode
          .timeout(const Duration(seconds: 10))
          .catchError((_) => 0);
      await _waitFor(
        cliLines,
        RegExp('relay connection closed'),
        'cli woke up when its device died',
      );

      // Device comes back; the CLI recovery loop re-pairs.
      final device2 = await startDevice();
      addTearDown(() => device2.kill());
      await _waitFor(
        cliLines,
        RegExp('connected to relay'),
        'cli reconnected to relay',
      );
      await _waitFor(
        cliLines,
        RegExp('device VM service:'),
        'cli re-paired after device death',
      );
    },
    timeout: const Timeout(Duration(seconds: 240)),
  );
}
