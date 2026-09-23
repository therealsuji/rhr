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
}
