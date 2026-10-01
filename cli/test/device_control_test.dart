import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:rhr_cli/device_control.dart';
import 'package:test/test.dart';

/// A stand-in for the session's device endpoint: checks the token line, then
/// answers each framed request with [answer]. Frames are written split at an
/// odd size, as TCP may deliver them.
Future<ServerSocket> fakeEndpoint(
  Map<String, Object?> Function(Map<String, dynamic> request) answer,
) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((socket) {
    var buffer = <int>[];
    var authenticated = false;
    socket.listen((data) {
      buffer.addAll(data);
      if (!authenticated) {
        final newline = buffer.indexOf(10);
        if (newline < 0) return;
        expect(utf8.decode(buffer.sublist(0, newline)), 'secret');
        authenticated = true;
        buffer = buffer.sublist(newline + 1);
      }
      while (buffer.length >= 4) {
        final length = ByteData.sublistView(
          Uint8List.fromList(buffer),
        ).getUint32(0);
        if (buffer.length < 4 + length) break;
        final request = jsonDecode(utf8.decode(buffer.sublist(4, 4 + length)));
        buffer = buffer.sublist(4 + length);
        final body = utf8.encode(jsonEncode(answer(request)));
        final frame = [
          ...(ByteData(4)..setUint32(0, body.length)).buffer.asUint8List(),
          ...body,
        ];
        for (var i = 0; i < frame.length; i += 7) {
          socket.add(
            frame.sublist(i, i + 7 > frame.length ? frame.length : i + 7),
          );
        }
      }
    });
  });
  return server;
}

void main() {
  test('a request gets the result with its id', () async {
    final server = await fakeEndpoint(
      (r) => {
        'id': r['id'],
        'result': {'op': r['op'], 'x': r['x']},
      },
    );
    addTearDown(server.close);
    final device = await DeviceControl.connect(server.port, 'secret');
    addTearDown(device.close);

    final answers = await Future.wait([
      device.request('tap', {'x': 0.5}),
      device.request('tree'),
    ]);
    expect(answers, [
      {'op': 'tap', 'x': 0.5},
      {'op': 'tree', 'x': null},
    ]);
  });

  test('an error answer fails only its own request', () async {
    final server = await fakeEndpoint(
      (r) => r['op'] == 'set_text'
          ? {'id': r['id'], 'error': 'no_text_field', 'message': 'Tap it.'}
          : {'id': r['id'], 'result': <String, Object?>{}},
    );
    addTearDown(server.close);
    final device = await DeviceControl.connect(server.port, 'secret');
    addTearDown(device.close);

    await expectLater(
      device.request('set_text', {'text': 'hi'}),
      throwsA(
        isA<DeviceControlException>().having(
          (e) => e.code,
          'code',
          'no_text_field',
        ),
      ),
    );
    expect(await device.request('info'), isEmpty);
  });

  test('a refusal of the channel (id 0) fails every request', () async {
    final server = await fakeEndpoint(
      (_) => {'id': 0, 'error': 'unknown_target', 'message': 'No such target.'},
    );
    addTearDown(server.close);
    final device = await DeviceControl.connect(server.port, 'secret');

    await expectLater(
      device.request('info'),
      throwsA(
        isA<DeviceControlException>().having(
          (e) => e.code,
          'code',
          'unknown_target',
        ),
      ),
    );
    expect(device.isClosed, isTrue);
    await expectLater(
      device.request('info'),
      throwsA(isA<DeviceControlException>()),
    );
  });
}
