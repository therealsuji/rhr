import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:rhr_cli/direct_session_transport.dart';
import 'package:rhr_cli/relay_race.dart';
import 'package:test/test.dart';

final class _FakeControlTransport implements RelayControlTransport {
  final controller = StreamController<String>();
  final sent = <String>[];

  @override
  Stream<String> get controlStream => controller.stream;

  @override
  Future<String> get selectedRelay async => 'fake';

  @override
  String? get closeReason => null;

  @override
  void sendControl(String message) => sent.add(message);

  @override
  Future<void> close() => controller.close();
}

void main() {
  test('missing direct offer fails without a relay payload fallback', () async {
    final relay = _FakeControlTransport();
    final transport = DirectSessionTransport(
      relay,
      offerTimeout: const Duration(milliseconds: 20),
    );
    final errors = <Object>[];
    final subscription = transport.stream.listen(
      (_) {},
      onError: (Object error) => errors.add(error),
    );

    relay.controller.add(
      jsonEncode({'t': 'info', 'vm': 'http://127.0.0.1:1/'}),
    );

    await expectLater(
      transport.payloadReady,
      throwsA(isA<DirectTransportFailure>()),
    );
    await expectLater(
      transport.sendPayload(Uint8List.fromList([1, 2, 3])),
      throwsA(isA<DirectTransportFailure>()),
    );
    expect(errors, contains(isA<DirectTransportFailure>()));
    expect(
      relay.sent.map((message) => jsonDecode(message)['t']),
      contains('direct_error'),
    );

    await subscription.cancel();
    await transport.close();
  });

  test('a device-side direct failure terminates payload readiness', () async {
    final relay = _FakeControlTransport();
    final transport = DirectSessionTransport(relay);
    final subscription = transport.stream.listen((_) {}, onError: (_) {});

    relay.controller.add(
      jsonEncode({'v': 1, 't': 'direct_error', 'message': 'ICE failed'}),
    );

    await expectLater(
      transport.payloadReady,
      throwsA(
        isA<DirectTransportFailure>().having(
          (failure) => failure.message,
          'message',
          contains('ICE failed'),
        ),
      ),
    );
    expect(relay.sent, isEmpty, reason: 'remote errors must not be echoed');

    await subscription.cancel();
    await transport.close();
  });
}
