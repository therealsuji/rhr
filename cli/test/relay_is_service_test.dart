import 'package:rhr_cli/account_auth.dart';
import 'package:test/test.dart';

void main() {
  test('the public relay is its own account service', () {
    // The case production hit: no explicit port on either side.
    expect(relayIsService('wss://getrhr.dev', 'https://getrhr.dev'), isTrue);
    expect(
      relayIsService('wss://getrhr.dev:443', 'https://getrhr.dev'),
      isTrue,
    );
    expect(
      relayIsService('ws://127.0.0.1:8788', 'http://127.0.0.1:8788'),
      isTrue,
    );
  });

  test('no other relay is handed a ticket', () {
    expect(relayIsService('wss://evil.dev', 'https://getrhr.dev'), isFalse);
    expect(
      relayIsService('wss://getrhr.dev:8443', 'https://getrhr.dev'),
      isFalse,
    );
    expect(relayIsService('ws://getrhr.dev', 'https://getrhr.dev'), isFalse);
    expect(
      relayIsService('wss://192.168.1.17:55099', 'https://getrhr.dev'),
      isFalse,
    );
  });
}
