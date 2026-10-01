// rhr relay: pairs a device bridge and a dev CLI by session code and pipes
// text control messages between them. Binary tunnel payloads are rejected:
// they belong on the direct WebRTC data channel.
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

import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

final sessions = <String, Session>{};
const minSessionCodeLength = 16;
const maxControlMessageBytes = 64 * 1024;

class Session {
  Session({this.onEmpty, this.allowBinaryPayloads = false});

  final void Function()? onEmpty;
  final bool allowBinaryPayloads;
  WebSocketChannel? device;
  WebSocketChannel? dev;
  String? lastDeviceInfo;

  void pipeDevice(WebSocketChannel ch) {
    device?.sink.close(4001, 'replaced by new connection');
    device = ch;
    ch.stream.listen(
      (msg) {
        if (!allowBinaryPayloads && msg is! String) {
          stderr.writeln('[relay] rejected binary payload from device');
          ch.sink.close(4002, 'binary payload disabled');
          return;
        }
        if (msg is String && utf8.encode(msg).length > maxControlMessageBytes) {
          stderr.writeln(
            '[relay] rejected oversized control message from device',
          );
          ch.sink.close(4003, 'control message too large');
          return;
        }
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
        if (!allowBinaryPayloads && msg is! String) {
          stderr.writeln('[relay] rejected binary payload from dev');
          ch.sink.close(4002, 'binary payload disabled');
          return;
        }
        if (msg is String && utf8.encode(msg).length > maxControlMessageBytes) {
          stderr.writeln('[relay] rejected oversized control message from dev');
          ch.sink.close(4003, 'control message too large');
          return;
        }
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

Session _sessionFor(String code, {bool allowBinaryPayloads = false}) {
  final existing = sessions[code];
  if (existing != null) return existing;
  late final Session created;
  created = Session(
    allowBinaryPayloads: allowBinaryPayloads,
    onEmpty: () {
      if (identical(sessions[code], created)) sessions.remove(code);
    },
  );
  sessions[code] = created;
  return created;
}

Future<HttpServer> startRelay(
  int port, {
  bool allowBinaryPayloads = false,
}) async {
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
        final s = _sessionFor(code, allowBinaryPayloads: allowBinaryPayloads);
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
  final server = await startRelay(
    port,
    allowBinaryPayloads:
        Platform.environment['RHR_ALLOW_BINARY_PAYLOADS'] == '1',
  );
  stderr.writeln('[relay] listening on :${server.port}');
}
