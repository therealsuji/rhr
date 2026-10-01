import 'package:rhr_bridge/session_link.dart';
import 'package:test/test.dart';

void main() {
  const code = 'rhr-abcd-efgh-jkmn';
  final relays = [
    'ws://192.168.1.5:8123',
    'wss://example.com/path?x=a%26b&y=2',
  ];
  test('deep and web links preserve the code and ordered relay URLs', () {
    final link = sessionConnectionLink(code, relays);
    for (final raw in [
      link.toString(),
      sessionConnectionWebLink(link).toString(),
    ]) {
      final parsed = parseSessionConnectionLink(raw);
      expect(parsed.code, code);
      expect(parsed.relays, relays);
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
    ]) {
      expect(
        () => parseSessionConnectionLink(raw),
        throwsFormatException,
        reason: raw,
      );
    }
  });
}
