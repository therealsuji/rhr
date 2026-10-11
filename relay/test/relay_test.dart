import 'dart:async';
import 'dart:io';

import '../bin/relay.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 30));

void main() {
  late HttpServer server;

  setUp(() async {
    sessions.clear();
    server = await startRelay(0);
  });

  tearDown(() async {
    sessions.clear();
    await server.close(force: true);
  });

  test('evicts a session after both peers disconnect', () async {
    const code = 'rhr-test-eviction';
    final device = IOWebSocketChannel.connect(
      'ws://127.0.0.1:${server.port}/s/$code/device',
    );
    final host = IOWebSocketChannel.connect(
      'ws://127.0.0.1:${server.port}/s/$code/host',
    );
    await Future.wait([device.ready, host.ready]);
    expect(sessions, contains(code));

    await device.sink.close(1000, 'test complete');
    await _settle();
    expect(sessions, isNot(contains(code)));
    await host.sink.close().catchError((_) {});
  });

  test('replacement closes the previous peer with a reason', () async {
    const code = 'rhr-test-replacement';
    final first = IOWebSocketChannel.connect(
      'ws://127.0.0.1:${server.port}/s/$code/host',
    );
    await first.ready;
    final second = IOWebSocketChannel.connect(
      'ws://127.0.0.1:${server.port}/s/$code/host',
    );
    await second.ready;

    await first.stream.drain<void>();
    expect(first.closeReason, contains('replaced'));
    await second.sink.close();
  });

  test('late host replays info after direct signaling has started', () async {
    const code = 'rhr-test-direct-replay';
    final device = IOWebSocketChannel.connect(
      'ws://127.0.0.1:${server.port}/s/$code/device',
    );
    await device.ready;
    device.sink.add('{"t":"info","vm":"http://127.0.0.1:1234/"}');
    device.sink.add('{"v":1,"t":"direct_offer","sdp":"offer"}');

    final host = IOWebSocketChannel.connect(
      'ws://127.0.0.1:${server.port}/s/$code/host',
    );
    await host.ready;
    final replay = await host.stream.first.timeout(const Duration(seconds: 2));

    expect(replay, contains('"t":"info"'));
    await device.sink.close();
    await host.sink.close().catchError((_) {});
  });

  test('rejects binary payloads', () async {
    const code = 'rhr-test-text-only';
    final device = IOWebSocketChannel.connect(
      'ws://127.0.0.1:${server.port}/s/$code/device',
    );
    final host = IOWebSocketChannel.connect(
      'ws://127.0.0.1:${server.port}/s/$code/host',
    );
    await Future.wait([device.ready, host.ready]);

    device.sink.add([1, 2, 3]);

    await device.stream.drain<void>().timeout(const Duration(seconds: 2));
    expect(device.closeCode, 4002);
    expect(device.closeReason, 'binary payload disabled');
    await host.sink.close().catchError((_) {});
  });

  test('rejects short codes and browser websocket origins', () async {
    final client = HttpClient();
    addTearDown(client.close);

    final shortRequest = await client.getUrl(
      Uri.parse('http://127.0.0.1:${server.port}/s/too-short/host'),
    );
    final shortResponse = await shortRequest.close();
    expect(shortResponse.statusCode, HttpStatus.badRequest);

    final browserRequest = await client.getUrl(
      Uri.parse('http://127.0.0.1:${server.port}/s/rhr-test-origin-2345/host'),
    );
    browserRequest.headers.set('Origin', 'https://evil.example');
    final browserResponse = await browserRequest.close();
    expect(browserResponse.statusCode, HttpStatus.forbidden);
  });
}
