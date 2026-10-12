import 'package:rhr_bridge/session_link.dart';
import 'package:test/test.dart';

void main() {
  const code = 'rhr-abcd-efgh-jkmn';
  const pin = 'n4bQgYhMfWWaL-qgxVrQFaO_TxsrC4Is0V1sFbDwCgg';
  final relays = [
    'wss://192.168.1.5:8123',
    'wss://example.com/path?x=a%26b&y=2',
  ];
  test('deep and web links preserve the code, relays and pin', () {
    final link = sessionConnectionLink(code, relays, pin: pin);
    for (final raw in [
      link.toString(),
      sessionConnectionWebLink(link).toString(),
    ]) {
      final parsed = parseSessionConnectionLink(raw);
      expect(parsed.code, code);
      expect(parsed.relays, relays);
      expect(parsed.pin, pin);
    }
    expect(sessionConnectionWebLink(link).query, isEmpty);
  });
  test('rejects malformed links and unsafe relay addresses', () {
    for (final raw in [
      'rhr://join?code=$code&relay=wss://example.com',
      'rhr://connect?code=bad&relay=wss://example.com',
      'rhr://connect?code=$code',
      'rhr://connect?code=$code&code=$code&relay=wss://example.com',
      'rhr://connect?code=$code&relay=https://example.com',
      'rhr://connect?code=$code&relay=wss://user:password@example.com',
      'rhr://connect/path?code=$code&relay=wss://example.com',
      // Plaintext off loopback exposes the code to the network.
      'rhr://connect?code=$code&relay=ws://192.168.1.5:8123',
      'rhr://connect?code=$code&relay=ws://example.com',
      'rhr://connect?code=$code&relay=wss://example.com&pin=short',
    ]) {
      expect(
        () => parseSessionConnectionLink(raw),
        throwsFormatException,
        reason: raw,
      );
    }
  });
  test('plain ws is allowed on loopback only', () {
    expect(isAllowedRelay(Uri.parse('ws://127.0.0.1:8123')), isTrue);
    expect(isAllowedRelay(Uri.parse('ws://10.0.0.2:8123')), isFalse);
    expect(isAllowedRelay(Uri.parse('wss://10.0.0.2:8123')), isTrue);
  });
}
