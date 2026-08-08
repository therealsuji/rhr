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

class Session {
  WebSocketChannel? device;
  WebSocketChannel? dev;
  String? lastDeviceInfo;

  void pipeDevice(WebSocketChannel ch) {
    device?.sink.close();
    device = ch;
    ch.stream.listen((msg) {
      if (msg is String) lastDeviceInfo = msg;
      dev?.sink.add(msg);
    }, onDone: () {
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
      }
    }, onError: (_) {
      stderr.writeln('[relay] device channel error');
      if (device == ch) {
        device = null;
        lastDeviceInfo = null;
        dev?.sink.close(4000, 'device disconnected');
        dev = null;
      }
    });
    final info = lastDeviceInfo;
    if (info != null && dev != null) dev!.sink.add(info);
  }

  void pipeDev(WebSocketChannel ch) {
    dev?.sink.close();
    dev = ch;
    ch.stream.listen((msg) {
      device?.sink.add(msg);
    }, onDone: () {
      if (dev == ch) dev = null;
    }, onError: (_) {
      if (dev == ch) dev = null;
    });
    final info = lastDeviceInfo;
    if (info != null) ch.sink.add(info);
  }
}

Future<void> main(List<String> args) async {
  final port = int.parse(
      args.isNotEmpty ? args[0] : Platform.environment['PORT'] ?? '8787');

  final handler = (Request req) {
    final seg = req.url.pathSegments;
    if (seg.length == 1 && seg[0] == 'healthz') return Response.ok('ok');
    if (seg.length == 3 && seg[0] == 's') {
      final code = seg[1];
      final role = seg[2];
      if (role != 'device' && role != 'dev') return Response.notFound('bad role');
      return webSocketHandler((WebSocketChannel ws, _) {
        final s = sessions.putIfAbsent(code, Session.new);
        stderr.writeln('[relay] $role connected to session $code');
        role == 'device' ? s.pipeDevice(ws) : s.pipeDev(ws);
      })(req);
    }
    return Response.notFound('not found');
  };

  final server = await shelf_io.serve(handler, InternetAddress.anyIPv4, port);
  stderr.writeln('[relay] listening on :${server.port}');
}
