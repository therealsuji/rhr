// The phases the CLI actually puts on the wire, from a real process.
//
// update_loopback_test.dart checks the transfer protocol; this checks what
// the tester is TOLD while it happens. They are different failures: the bar
// that sat at 54% was correct about the bytes and wrong about the phase, and
// the phase that never cleared was not a protocol error at all — the CLI
// simply said nothing on success, so the phone kept the last thing it heard.
//
// The rule being pinned is the one a tester's patience depends on: a phase
// that goes up comes down. Every exit from the update path reports.
//
// These spawn a real relay, a real CLI and a real device bridge. Paths that
// need an actual player build are not here — a Gradle build is minutes and
// belongs in the hardware pass, not in CI — so this covers the decline and
// no-terminal exits, which are the fast ones and the ones that used to leave
// a phone stuck on "Out of date".

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

String _findRepo() {
  var directory = Directory.current;
  while (true) {
    if (File('${directory.path}/relay/bin/relay.dart').existsSync()) {
      return directory.path;
    }
    final parent = directory.parent;
    if (parent.path == directory.path) {
      throw StateError('repo root not found from ${Directory.current.path}');
    }
    directory = parent;
  }
}

final _repo = _findRepo();

Future<int> _freePort() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  await server.close();
  return port;
}

Future<Process> _spawn(
  List<String> args, {
  required String workDir,
  required List<String> lines,
}) async {
  final process = await Process.start(Platform.resolvedExecutable, [
    'run',
    ...args,
  ], workingDirectory: workDir);
  void drain(Stream<List<int>> stream) {
    stream
        .transform(SystemEncoding().decoder)
        .transform(const LineSplitter())
        .listen(lines.add);
  }

  drain(process.stdout);
  drain(process.stderr);
  return process;
}

Future<void> _waitFor(
  List<String> lines,
  bool Function(List<String>) done,
  String description,
) async {
  // A real relay, CLI and bridge on real sockets, so this is generous for a
  // CI runner — but not 200s generous: the path under test involves no build
  // and settles in about three seconds, and a missing phase clear should
  // report quickly rather than look like a hang.
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  while (DateTime.now().isBefore(deadline)) {
    if (done(lines)) return;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  fail('timed out waiting for $description:\n${lines.join('\n')}');
}

/// The phases the device printed, in order, without the byte counts.
List<String> _phases(List<String> deviceLines) => [
  for (final line in deviceLines)
    if (line.startsWith('[phase] '))
      line.substring('[phase] '.length).split(' ').first,
];

void main() {
  test('a declined update leaves no phase behind on the phone', () async {
    final port = await _freePort();
    final code = 'phases-${DateTime.now().millisecondsSinceEpoch}';
    final relayLines = <String>[];
    final cliLines = <String>[];
    final deviceLines = <String>[];

    final relay = await _spawn(
      ['bin/relay.dart', '$port'],
      workDir: '$_repo/relay',
      lines: relayLines,
    );
    // --outdated makes the compatibility gate block, which is the only way
    // the update path is entered at all.
    final device = await _spawn([
      '--enable-vm-service=0',
      'example/fake_device.dart',
      'ws://127.0.0.1:$port',
      code,
      '--outdated',
    ], workDir: '$_repo/bridge', lines: deviceLines);
    // No --update-player and no terminal to prompt on: the CLI declines on
    // the tester's behalf and must say so. This exits 78, and the phone used
    // to keep "Out of date — waiting for the developer" forever.
    final cli = await _spawn([
      'bin/rhr.dart',
      'attach',
      '--no-flutter',
      '--no-direct',
      '--relay',
      'ws://127.0.0.1:$port',
      '--code',
      code,
    ], workDir: '$_repo/cli', lines: cliLines);

    try {
      await _waitFor(
        deviceLines,
        (lines) => _phases(lines).contains('(cleared)'),
        'the phase to be cleared after the update was declined',
      );

      final phases = _phases(deviceLines);
      expect(
        phases.first,
        'outdated',
        reason: 'the tester should learn the session is blocked, not just '
            'watch it go quiet',
      );
      expect(
        phases.last,
        '(cleared)',
        reason: 'a phase that went up must come down; this one used to stay',
      );
    } finally {
      for (final process in [cli, device, relay]) {
        process.kill(ProcessSignal.sigterm);
      }
      await Future.wait([cli.exitCode, device.exitCode, relay.exitCode]);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
