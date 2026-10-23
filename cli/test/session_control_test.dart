import 'dart:convert';
import 'dart:io';

import 'package:rhr_cli/session_control.dart';
import 'package:test/test.dart';

void main() {
  late Directory project;
  setUp(() => project = Directory.systemTemp.createTempSync('rhr-control-'));
  tearDown(() => project.deleteSync(recursive: true));

  test('a command reaches the running session and gets its answer', () async {
    final received = <String>[];
    var after = false;
    final control = await SessionControl.serve(project.path, (command) async {
      received.add(command);
      return (ok: true, message: 'done', then: () => after = true);
    });
    addTearDown(control.close);

    final answer = await sendSessionCommand(project.path, 'persist');
    expect(received, ['persist']);
    expect(answer, (ok: true, message: 'done'));
    expect(after, isTrue);
  });

  test('no running session, or one that is gone, means null', () async {
    expect(await sendSessionCommand(project.path, 'persist'), isNull);
    final control = await SessionControl.serve(
      project.path,
      (_) async => (ok: true, message: '', then: null),
    );
    // A session that crashed leaves its file behind.
    final file = SessionControl.fileFor(project.path);
    final saved = file.readAsStringSync();
    await control.close();
    file.writeAsStringSync(saved);
    expect(await sendSessionCommand(project.path, 'persist'), isNull);
  });

  test('a request without the token is not served', () async {
    var served = false;
    final control = await SessionControl.serve(project.path, (_) async {
      served = true;
      return (ok: true, message: '', then: null);
    });
    addTearDown(control.close);
    final file = SessionControl.fileFor(project.path);
    file.writeAsStringSync(
      file.readAsStringSync().replaceFirst(
        RegExp(r'"token":"[^"]+"'),
        '"token":"x"',
      ),
    );
    final answer = await sendSessionCommand(project.path, 'release');
    expect(served, isFalse);
    expect(answer?.ok, isFalse);
  });

  test('a request line with no end is cut off, not buffered', () async {
    final control = await SessionControl.serve(
      project.path,
      (_) async => (ok: true, message: '', then: null),
    );
    addTearDown(control.close);
    final config = jsonDecode(
      SessionControl.fileFor(project.path).readAsStringSync(),
    );
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      config['port'] as int,
    );
    // A hang-up is a close or, when it lands mid-write, a reset: either is
    // the server cutting the line off.
    final closed = socket.drain<void>().then((_) => true, onError: (_) => true);
    // Writes may fail once the server hangs up; that is the point. Under load
    // the failure can surface synchronously from add.
    socket.done.catchError((_) {});
    for (var i = 0; i < 8 && !await _settled(closed); i++) {
      try {
        socket.add(List.filled(1024, 0x61));
        await socket.flush();
      } on SocketException {
        break;
      }
    }
    expect(await closed.timeout(const Duration(seconds: 2)), isTrue);
    socket.destroy();
  });

  test('readConnectionInfo reads the pairing file, or nothing', () {
    expect(readConnectionInfo(project.path), isNull);
    File('${project.path}/.dart_tool/rhr/connection.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'code': 'rhr-abcd-efgh-ijkl',
          'url':
              'https://getrhr.dev/connect#rhr%3A%2F%2Fconnect%3Fcode%3Drhr-abcd-efgh-ijkl',
          'deepLink': 'rhr://connect?code=rhr-abcd-efgh-ijkl',
          'relays': ['ws://192.168.1.12:39857', 'wss://getrhr.dev'],
          'qrPayload':
              '{"code":"rhr-abcd-efgh-ijkl","relays":["ws://192.168.1.12:39857","wss://getrhr.dev"]}',
        }),
      );
    final info = readConnectionInfo(project.path);
    expect(info?.code, 'rhr-abcd-efgh-ijkl');
    expect(info?.url, startsWith('https://getrhr.dev/connect#'));
    expect(info?.deepLink, startsWith('rhr://connect?'));
    expect(info?.relays, ['ws://192.168.1.12:39857', 'wss://getrhr.dev']);
    expect(
      info?.qrPayload,
      '{"code":"rhr-abcd-efgh-ijkl","relays":["ws://192.168.1.12:39857","wss://getrhr.dev"]}',
    );
  });

  test('findSessionProject finds the session above, or the one below', () {
    final root = Directory.systemTemp.createTempSync('rhr-mono-');
    addTearDown(() => root.deleteSync(recursive: true));
    void session(String dir) =>
        SessionControl.fileFor('${root.path}/$dir').createSync(recursive: true);
    Directory('${root.path}/apps/mobile/lib').createSync(recursive: true);

    expect(findSessionProject(root.path), isNull);
    session('apps/mobile');
    final mobile = Directory('${root.path}/apps/mobile').absolute.path;
    // An agent opened at the monorepo root, and one opened inside the app.
    expect(findSessionProject(root.path), mobile);
    expect(findSessionProject('${root.path}/apps/mobile/lib'), mobile);
    // Two running apps below: ambiguous, so say which.
    session('apps/tablet');
    expect(() => findSessionProject(root.path), throwsA(isA<StateError>()));
  });
}

/// Whether [future] has already completed, without waiting for it.
Future<bool> _settled(Future<bool> future) =>
    Future.any([future, Future.delayed(Duration.zero, () => false)]);
