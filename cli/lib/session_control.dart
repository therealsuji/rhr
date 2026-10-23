import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'private_file.dart';
import 'version.dart';

/// How `rhr persist`, `rhr release` and `rhr mcp` reach an rhr session already
/// holding the phone. The relay admits one host per phone, so a second
/// CLI cannot connect; it asks the running one instead.
///
/// The running session listens on loopback and writes the port and a random
/// token to `.dart_tool/rhr/control.json`, readable only by this user, along
/// with the session's other loopback endpoints (see [SessionEndpoints]). A command is one JSON
/// line `{"token", "command"}`; the answer is one line `{"ok", "message"}`,
/// sent once the work is done. [SessionAnswer.then] runs after the answer is
/// sent, for work that ends the session.
typedef SessionAnswer = ({bool ok, String message, void Function()? then});

final class SessionControl {
  static const _maxRequestBytes = 4096;

  SessionControl._(this._server, this._file, this.token);

  final ServerSocket _server;
  final File _file;

  /// The secret a local client must present, here and on the endpoints.
  final String token;

  static File fileFor(String project) =>
      File('$project/.dart_tool/rhr/control.json');

  /// Serves commands with [handle] until [close].
  static Future<SessionControl> serve(
    String project,
    Future<SessionAnswer> Function(String command) handle, {
    Map<String, Object> endpoints = const {},
  }) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final token = base64UrlEncode(
      List<int>.generate(16, (_) => Random.secure().nextInt(256)),
    );
    final control = SessionControl._(server, fileFor(project), token)
      ..publish(endpoints);
    server.listen((client) async {
      client.done.catchError((_) {});
      try {
        final line = await _firstLine(
          client,
        ).timeout(const Duration(seconds: 5));
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
    return control;
  }

  /// The client's first line, read before its token is checked, so it is
  /// capped: any local process can connect and stream bytes with no newline.
  static Future<String> _firstLine(Stream<List<int>> client) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in client) {
      final newline = chunk.indexOf(10);
      bytes.add(newline < 0 ? chunk : chunk.sublist(0, newline));
      if (newline >= 0) break;
      if (bytes.length > _maxRequestBytes) break;
    }
    if (bytes.length > _maxRequestBytes) {
      throw const FormatException('control request too long');
    }
    return utf8.decode(bytes.takeBytes());
  }

  /// Writes the control file with [endpoints], replacing what it said. A
  /// session publishes device control first and the VM once the app runs.
  void publish(Map<String, Object> endpoints) => writePrivateFile(
    _file,
    jsonEncode({
      ...endpoints,
      'port': _server.port,
      'token': token,
      'version': rhrVersion,
    }),
  );

  Future<void> close() async {
    await _server.close();
    if (_file.existsSync()) _file.deleteSync();
  }
}

/// What a running session publishes for local clients: the control [token],
/// the tunneled VM service (null while the app is still being prepared), the
/// loopback ports that open device-control and
/// native-log channels to the phone, and the package the app runs in (absent
/// for `rhr attach`, which does not know it), and the rhr [version] the
/// session runs (absent before 0.1.0-beta.30).
typedef SessionEndpoints = ({
  String token,
  Uri? vm,
  int device,
  int logs,
  String? app,
  String? version,
});

/// The endpoints of the session running for [project], or null when none has
/// published any. A file left by a session that died still reads; connecting
/// is what tells.
SessionEndpoints? readSessionEndpoints(String project) {
  try {
    final saved = jsonDecode(
      SessionControl.fileFor(project).readAsStringSync(),
    );
    if (saved case {
      'token': final String token,
      'device': final int device,
      'logs': final int logs,
    }) {
      return (
        token: token,
        vm: switch (saved['vm']) {
          final String vm => Uri.parse(vm),
          _ => null,
        },
        device: device,
        logs: logs,
        app: saved['app'] as String?,
        version: saved['version'] as String?,
      );
    }
  } on Object {
    // No session, or one mid-write.
  }
  return null;
}

/// The pairing info of the session running for [project], from the
/// `connection.json` that `rhr run` and `rhr attach` write next to the
/// control file: the session code, the tap link and the deep link, the
/// relays, and `qrPayload`, the data encoded by the terminal QR. Null when
/// no session has written one.
typedef ConnectionInfo = ({
  String code,
  String url,
  String deepLink,
  List<String> relays,
  String qrPayload,
});

ConnectionInfo? readConnectionInfo(String project) {
  try {
    final saved = jsonDecode(
      File('$project/.dart_tool/rhr/connection.json').readAsStringSync(),
    );
    if (saved case {
      'code': final String code,
      'url': final String url,
      'deepLink': final String deepLink,
      'relays': final List<Object?> relays,
      'qrPayload': final String qrPayload,
    }) {
      return (
        code: code,
        url: url,
        deepLink: deepLink,
        relays: relays.whereType<String>().toList(),
        qrPayload: qrPayload,
      );
    }
  } on Object {
    // No session, or one mid-write.
  }
  return null;
}

/// The project whose rhr session an MCP client in [start] means: [start]
/// or the nearest folder above it with a running session, else the one
/// project below it (a few levels down, as in a monorepo) that has one.
/// Null when there is none; a [StateError] naming them when several
/// projects below run sessions.
String? findSessionProject(String start) {
  bool running(String dir) => SessionControl.fileFor(dir).existsSync();
  var dir = Directory(start).absolute;
  while (true) {
    if (running(dir.path)) return dir.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  const skipped = {'build', 'node_modules', 'ios', 'android', 'Pods'};
  final found = <String>[];
  void search(Directory directory, int depth) {
    if (depth == 0) return;
    final List<FileSystemEntity> children;
    try {
      children = directory.listSync(followLinks: false);
    } on FileSystemException {
      return;
    }
    for (final child in children.whereType<Directory>()) {
      final name = child.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (name.startsWith('.') || skipped.contains(name)) continue;
      if (running(child.path)) {
        found.add(child.path);
      } else {
        search(child, depth - 1);
      }
    }
  }

  // Not from the home folder or the root: that would crawl the disk.
  final root = Directory(start).absolute;
  final home = Platform.environment['HOME'];
  if (root.parent.path != root.path && root.path != home) search(root, 4);
  if (found.length > 1) {
    throw StateError(
      'Several rhr sessions run below $start: ${found.join(', ')}. Start '
      'your coding agent in the project you mean, or register rhr mcp with '
      '--project <dir>.',
    );
  }
  return found.singleOrNull;
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
  } on SocketException {
    // The session died between its file and this write: the connect can
    // still land in a closing listener's backlog.
    return null;
  } finally {
    socket.destroy();
  }
}
