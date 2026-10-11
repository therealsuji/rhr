import 'package:rhr_cli/direct_session_transport.dart';
import 'package:rhr_cli/reconnect_backoff.dart';
import 'package:test/test.dart';

void main() {
  test('failed attempts back off and remain capped during an outage', () {
    final backoff = ReconnectBackoff();
    expect(List.generate(10, (_) => backoff.nextDelay().inSeconds), [
      2,
      4,
      6,
      8,
      10,
      12,
      14,
      15,
      15,
      15,
    ]);
  });

  test(
    'a ready session recovers immediately without inheriting old failures',
    () {
      final backoff = ReconnectBackoff();
      for (var i = 0; i < 10; i++) {
        backoff.nextDelay();
      }
      backoff.markReady();
      expect(backoff.nextDelay(), Duration.zero);
      expect(backoff.nextDelay(), const Duration(seconds: 2));
      expect(backoff.nextDelay(), const Duration(seconds: 4));
      backoff.markReady();
      expect(backoff.nextDelay(), Duration.zero);
    },
  );

  test('three direct routes that never open in a row mean no path', () {
    const noPath = DirectTransportFailure(
      'ICE failed',
      transient: true,
      noPath: true,
    );
    const dropped = DirectTransportFailure('relay closed', transient: true);
    final backoff = ReconnectBackoff();

    expect(backoff.directPathImpossible(noPath), isFalse);
    expect(backoff.directPathImpossible(noPath), isFalse);
    // A phone that went offline is a different failure: start over.
    expect(backoff.directPathImpossible(dropped), isFalse);
    expect(backoff.directPathImpossible(noPath), isFalse);
    expect(backoff.directPathImpossible(noPath), isFalse);
    expect(backoff.directPathImpossible(noPath), isTrue);

    // A session that worked proves a path exists.
    backoff.markReady();
    expect(backoff.directPathImpossible(noPath), isFalse);
  });
}
