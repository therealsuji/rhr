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
  Map<String, String>? environment,
}) async {
  final process = await Process.start(
    Platform.resolvedExecutable,
    ['run', ...args],
    workingDirectory: workDir,
    environment: environment,
  );
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
  RegExp pattern,
  String description,
) async {
  // These spawn a real relay, CLI and device bridge and wait on actual
  // sockets, so they are the slowest tests here. A GitHub runner is much
  // slower than a laptop, and 120s inside a 240s budget left no headroom —
  // this test was the one intermittently failing CI while passing locally.
  final deadline = DateTime.now().add(const Duration(seconds: 200));
  while (DateTime.now().isBefore(deadline)) {
    if (lines.any(pattern.hasMatch)) return;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  fail('timed out waiting for $description:\n${lines.join('\n')}');
}

void main() {
  test(
    'default direct transport uses a relay that rejects binary payloads',
    () async {
      final port = await _freePort();
      final code = 'direct-${DateTime.now().millisecondsSinceEpoch}';
      final relayLines = <String>[];
      final cliLines = <String>[];
      final deviceLines = <String>[];
      final relay = await _spawn(
        ['bin/relay.dart', '$port'],
        workDir: '$_repo/relay',
        lines: relayLines,
      );
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
      final device = await _spawn(
        [
          '--enable-vm-service=0',
          'example/fake_device.dart',
          'ws://127.0.0.1:$port',
          code,
          '--direct',
        ],
        workDir: '$_repo/bridge',
        lines: deviceLines,
      );

      Future<void> stop(Process process) async {
        process.kill();
        await process.exitCode.timeout(const Duration(seconds: 10));
      }

      addTearDown(() async {
        await stop(device);
        await stop(cli);
        await stop(relay);
      });

      await _waitFor(
        deviceLines,
        RegExp('direct WebRTC/STUN path is ready'),
        'direct peer',
      );
      await _waitFor(
        cliLines,
        RegExp(r'tunneled VM service: http://127\.0\.0\.1:(\d+)/'),
        'tunnel',
      );

      final tunnelLine = cliLines.firstWhere(
        (line) => line.contains('tunneled VM service:'),
      );
      final uri = Uri.parse(tunnelLine.split('tunneled VM service: ').last);
      final client = HttpClient();
      try {
        final response = await client
            .getUrl(uri.resolve('getVMInfo'))
            .then((request) => request.close())
            .timeout(const Duration(seconds: 10));
        final body = await utf8.decoder.bind(response).join();
        expect(response.statusCode, HttpStatus.ok);
        expect(body, contains('jsonrpc'));
        expect(
          relayLines.where((line) => line.contains('rejected binary payload')),
          isEmpty,
        );
      } finally {
        client.close(force: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 420)),
  );

  test(
    '--no-direct keeps the relay-only transport working',
    () async {
      final port = await _freePort();
      final code = 'relay-${DateTime.now().millisecondsSinceEpoch}';
      final relayLines = <String>[];
      final cliLines = <String>[];
      final deviceLines = <String>[];
      final relay = await _spawn(
        ['bin/relay.dart', '$port'],
        workDir: '$_repo/relay',
        lines: relayLines,
        environment: const {'RHR_ALLOW_BINARY_PAYLOADS': '1'},
      );
      final cli = await _spawn(
        [
          'bin/rhr.dart',
          'attach',
          '--no-flutter',
          '--no-direct',
          '--relay',
          'ws://127.0.0.1:$port',
          '--code',
          code,
        ],
        workDir: '$_repo/cli',
        lines: cliLines,
      );
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

      Future<void> stop(Process process) async {
        process.kill();
        await process.exitCode.timeout(const Duration(seconds: 10));
      }

      addTearDown(() async {
        await stop(device);
        await stop(cli);
        await stop(relay);
      });

      await _waitFor(
        cliLines,
        RegExp(r'tunneled VM service: http://127\.0\.0\.1:(\d+)/'),
        'relay-only tunnel',
      );
      final tunnelLine = cliLines.firstWhere(
        (line) => line.contains('tunneled VM service:'),
      );
      final uri = Uri.parse(tunnelLine.split('tunneled VM service: ').last);
      final client = HttpClient();
      try {
        final response = await client
            .getUrl(uri.resolve('getVMInfo'))
            .then((request) => request.close())
            .timeout(const Duration(seconds: 10));
        expect(response.statusCode, HttpStatus.ok);
      } finally {
        client.close(force: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 420)),
  );
}
