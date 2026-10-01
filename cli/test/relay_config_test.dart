import 'package:rhr_cli/relay_config.dart';
import 'package:test/test.dart';

void main() {
  test('shared public relay and lease defaults are safe', () {
    expect(defaultPublicRelay, startsWith('wss://'));
    expect(developerLeasePingInterval, lessThan(const Duration(seconds: 45)));
  });

  test('private relay replaces the shared fallback', () {
    expect(
      relayCandidates(
        local: 'ws://192.168.1.2:8123',
        configured: 'wss://relay.example.test',
      ),
      ['ws://192.168.1.2:8123', 'wss://relay.example.test'],
    );
    expect(relayCandidates(configured: 'wss://relay.example.test'), [
      'wss://relay.example.test',
    ]);
  });

  test('default relay remains the fallback when none is configured', () {
    expect(relayCandidates(local: 'ws://192.168.1.2:8123'), [
      'ws://192.168.1.2:8123',
      defaultPublicRelay,
    ]);
  });
}
