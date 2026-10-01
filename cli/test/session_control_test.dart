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
