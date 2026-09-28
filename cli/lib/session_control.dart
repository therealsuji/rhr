import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// How `rhr persist` and `rhr release` reach an `rhr run` already holding
/// the phone. The relay admits one developer per phone, so a second CLI
/// cannot connect; it asks the running one instead.
///
/// The running session listens on loopback and writes the port and a random
/// token to `.dart_tool/rhr/control.json` (mode 600). A command is one JSON
/// line `{"token", "command"}`; the answer is one line `{"ok", "message"}`,
/// sent once the work is done. [SessionAnswer.then] runs after the answer is
/// sent, for work that ends the session.
typedef SessionAnswer = ({bool ok, String message, void Function()? then});

final class SessionControl {
  SessionControl._(this._server, this._file);

  final ServerSocket _server;
  final File _file;

  static File fileFor(String project) =>
      File('$project/.dart_tool/rhr/control.json');

  /// Serves commands with [handle] until [close].
  static Future<SessionControl> serve(
    String project,
    Future<SessionAnswer> Function(String command) handle,
  ) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final token = base64UrlEncode(
      List<int>.generate(16, (_) => Random.secure().nextInt(256)),
    );
    final file = fileFor(project);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode({'port': server.port, 'token': token}));
    if (!Platform.isWindows) Process.runSync('chmod', ['600', file.path]);
    server.listen((client) async {
      client.done.catchError((_) {});
      try {
        final line = await utf8.decoder
            .bind(client)
            .transform(const LineSplitter())
            .first
            .timeout(const Duration(seconds: 5));
        final request = jsonDecode(line);
        if (request is! Map<String, dynamic> || request['token'] != token) {
          return;
        }
        final answer = await handle('${request['command']}');
        try {
          client.writeln(
            jsonEncode({'ok': answer.ok, 'message': answer.message}),
          );
          await client.flush();
        } finally {
          answer.then?.call();
        }
      } on Object {
        // A malformed or abandoned request has no one to answer.
      } finally {
        client.destroy();
      }
    });
    return SessionControl._(server, file);
  }

  Future<void> close() async {
    await _server.close();
    if (_file.existsSync()) _file.deleteSync();
  }
}

/// Sends [command] to the session running for [project], and waits for its
/// answer. Null when no session is running to ask.
Future<({bool ok, String message})?> sendSessionCommand(
  String project,
  String command,
) async {
  final file = SessionControl.fileFor(project);
  if (!file.existsSync()) return null;
  final Socket socket;
  final Object? token;
  try {
    final saved = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    token = saved['token'];
    socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      saved['port'] as int,
    ).timeout(const Duration(seconds: 3));
  } on Object {
    // Left behind by a session that is gone.
    return null;
  }
  socket.done.catchError((_) {});
  try {
    socket.writeln(jsonEncode({'token': token, 'command': command}));
    await socket.flush();
    final line = await utf8.decoder
        .bind(socket)
        .transform(const LineSplitter())
        .first;
    final answer = jsonDecode(line) as Map<String, dynamic>;
    return (ok: answer['ok'] == true, message: '${answer['message']}');
  } on StateError {
    return (ok: false, message: 'The running rhr session closed the request.');
  } finally {
    socket.destroy();
  }
}
