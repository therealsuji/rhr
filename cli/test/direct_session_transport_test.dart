import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:rhr_bridge/direct_signaling.dart';
import 'package:rhr_bridge/direct_webrtc.dart';
import 'package:rhr_cli/direct_session_transport.dart';
import 'package:rhr_cli/relay_race.dart';
import 'package:test/test.dart';

final class _FakeControlTransport implements RelayControlTransport {
  final controller = StreamController<String>();
  final sent = <String>[];
  void Function(String message)? onSend;

  @override
  Stream<String> get controlStream => controller.stream;

  @override
  Future<String> get selectedRelay async => 'fake';

  @override
  String? get closeReason => null;

  @override
  void sendControl(String message) {
    sent.add(message);
    onSend?.call(message);
  }

  @override
  Future<void> close() => controller.close();
}

void main() {
  test('a send racing relay loss remains reconnectable', () async {
    final relay = _FakeControlTransport();
    final transport = DirectSessionTransport(relay);
    final subscription = transport.stream.listen((_) {}, onError: (_) {});
    final readiness = expectLater(
      transport.payloadReady,
      throwsA(isA<DirectTransportFailure>()),
    );
    await relay.close();
    await readiness;
    await expectLater(
      transport.sendPayload(Uint8List.fromList([2, 0, 0, 0, 1])),
      throwsA(
        isA<DirectTransportFailure>().having(
          (failure) => failure.transient,
          'transient',
          isTrue,
        ),
      ),
    );
    await subscription.cancel();
    await transport.close();
  });

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

  // A dead WebRTC payload path used to veto control traffic, which rides the
  // relay and never touches WebRTC. That took out the farewell (dev_gone), the
  // presence heartbeat, and the re-signaling that would rebuild the channel —
  // so a tester was left reading "Can't reach relay - retrying..." after a
  // clean quit.
  test(
    'control still reaches the relay after the payload path fails',
    () async {
      final relay = _FakeControlTransport();
      final transport = DirectSessionTransport(
        relay,
        offerTimeout: const Duration(milliseconds: 20),
      );
      final subscription = transport.stream.listen((_) {}, onError: (_) {});

      relay.controller.add(
        jsonEncode({'t': 'info', 'vm': 'http://127.0.0.1:1/'}),
      );
      await expectLater(
        transport.payloadReady,
        throwsA(isA<DirectTransportFailure>()),
      );

      // Payloads genuinely need the data channel, so they must still fail.
      await expectLater(
        transport.sendPayload(Uint8List.fromList([1, 2, 3])),
        throwsA(isA<DirectTransportFailure>()),
      );

      // Control does not, so it must go out regardless.
      transport.sendControl(jsonEncode({'t': 'dev_gone'}));
      expect(
        relay.sent.map((message) => jsonDecode(message)['t']),
        contains('dev_gone'),
      );

      await subscription.cancel();
      await transport.close();
    },
  );

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
        isA<DirectTransportFailure>()
            .having(
              (failure) => failure.message,
              'message',
              contains('ICE failed'),
            )
            // Nothing was ever open, so a fresh offer may well succeed.
            .having((failure) => failure.transient, 'transient', isTrue),
      ),
    );
    expect(relay.sent, isEmpty, reason: 'remote errors must not be echoed');

    await subscription.cancel();
    await transport.close();
  });

  test(
    'waits for end-of-candidates before answering an offer',
    () async {
      final relay = _FakeControlTransport();
      final transport = DirectSessionTransport(relay);
      final subscription = transport.stream.listen((_) {}, onError: (_) {});
      late final DirectWebRtcPeer device;
      final offerSent = Completer<void>();

      device = DirectWebRtcPeer.localOnly(
        onSignal: (signal) {
          if (signal is DirectEndSignal) return;
          relay.controller.add(signal.encode());
          if (signal is DirectDescriptionSignal && !offerSent.isCompleted) {
            offerSent.complete();
          }
        },
      );
      relay.onSend = (message) {
        final signal = DirectSignal.decode(message);
        switch (signal) {
          case DirectDescriptionSignal(:final type) when type == 'answer':
            unawaited(device.acceptAnswer(signal));
          case DirectCandidateSignal():
            unawaited(device.addCandidate(signal));
          case DirectDescriptionSignal() || DirectEndSignal():
            break;
          case DirectErrorSignal():
            fail('unexpected direct transport failure: ${signal.message}');
        }
      };

      await device.startOffer();
      await offerSent.future;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        relay.sent
            .map(DirectSignal.decode)
            .whereType<DirectDescriptionSignal>(),
        isEmpty,
        reason: 'starting checks while candidates trickle mutates the ICE list',
      );

      relay.controller.add(const DirectEndSignal().encode());
      await transport.payloadReady.timeout(const Duration(seconds: 10));

      await subscription.cancel();
      await transport.close();
      await device.close();
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );
}
