// rhr relay: pairs a device bridge and a dev CLI by session code and pipes
// WebSocket frames between them verbatim.
//
// Endpoints:
//   GET /s/<code>/device   — device bridge dials out here
//   GET /s/<code>/dev      — dev CLI connects here
//   GET /healthz
//
// The relay never parses tunnel frames. The one exception: the most recent
// TEXT frame from the device (the bridge's "info" hello carrying the VM
// service URI) is cached and replayed to a dev that connects later, so
// connection order doesn't matter.

import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

final sessions = <String, Session>{};
const minSessionCodeLength = 16;

class Session {
  Session({this.onEmpty});

  final void Function()? onEmpty;
  WebSocketChannel? device;
  WebSocketChannel? dev;
  String? lastDeviceInfo;

  void pipeDevice(WebSocketChannel ch) {
    device?.sink.close(4001, 'replaced by new connection');
    device = ch;
    ch.stream.listen(
      (msg) {
        if (_isInfoMessage(msg)) lastDeviceInfo = msg;
        dev?.sink.add(msg);
      },
      onDone: () => _deviceClosed(ch),
      onError: (_) => _deviceClosed(ch),
    );
    final info = lastDeviceInfo;
    if (info != null && dev != null) dev!.sink.add(info);
  }

  void pipeDev(WebSocketChannel ch) {
    dev?.sink.close(4001, 'replaced by new connection');
    dev = ch;
    ch.stream.listen(
      (msg) {
        device?.sink.add(msg);
      },
      onDone: () => _devClosed(ch),
      onError: (_) => _devClosed(ch),
    );
    final info = lastDeviceInfo;
    if (info != null) ch.sink.add(info);
  }

  void _deviceClosed(WebSocketChannel ch) {
    stderr.writeln('[relay] device channel done');
    // A dead device's info is worse than none: a dev attaching later would
    // tunnel to a VM service port that no longer exists.
    if (device == ch) {
      device = null;
      lastDeviceInfo = null;
      // The session is dead without a device: drop the dev too so the
      // CLI's recovery loop re-dials and re-pairs when the device returns.
      dev?.sink.close(4000, 'device disconnected');
      dev = null;
      _maybeEvict();
    }
  }

  void _devClosed(WebSocketChannel ch) {
    if (dev == ch) {
      dev = null;
      _maybeEvict();
    }
  }

  void _maybeEvict() {
    if (device == null && dev == null && lastDeviceInfo == null)
      onEmpty?.call();
  }
}

bool _isInfoMessage(Object message) {
  if (message is! String) return false;
  return message.contains('"t":"info"') || message.contains('"t": "info"');
}

Session _sessionFor(String code) {
  final existing = sessions[code];
  if (existing != null) return existing;
  late final Session created;
  created = Session(
    onEmpty: () {
      if (identical(sessions[code], created)) sessions.remove(code);
    },
  );
  sessions[code] = created;
  return created;
}

Future<HttpServer> startRelay(int port) async {
  final handler = (Request req) {
    final seg = req.url.pathSegments;
    if (seg.length == 1 && seg[0] == 'healthz') return Response.ok('ok');
    if (seg.length == 3 && seg[0] == 's') {
      final code = seg[1];
      final role = seg[2];
      if (role != 'device' && role != 'dev')
        return Response.notFound('bad role');
      if (code.length < minSessionCodeLength) {
        return Response(
          HttpStatus.badRequest,
          body: 'session code must be at least $minSessionCodeLength chars',
        );
      }
      if (req.headers['origin'] != null) {
        return Response.forbidden('browser clients not allowed');
      }
      return webSocketHandler((WebSocketChannel ws, _) {
        final s = _sessionFor(code);
        stderr.writeln('[relay] $role connected');
        role == 'device' ? s.pipeDevice(ws) : s.pipeDev(ws);
      })(req);
    }
    return Response.notFound('not found');
  };

  return shelf_io.serve(handler, InternetAddress.anyIPv4, port);
}

Future<void> main(List<String> args) async {
  final port = int.parse(
    args.isNotEmpty ? args[0] : Platform.environment['PORT'] ?? '8123',
  );
  final server = await startRelay(port);
  stderr.writeln('[relay] listening on :${server.port}');
}
