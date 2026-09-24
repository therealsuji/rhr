import 'package:rhr_cli/direct_path.dart';
import 'package:test/test.dart';

void main() {
  test('describes the route the phone selected', () {
    expect(
      describeDirectPath({
        't': 'path',
        'network': 'cellular',
        'family': 'ipv6',
        'protocol': 'udp',
        'local': 'host',
        'remote': 'srflx',
      }),
      'direct path: phone on cellular, IPv6/UDP, '
      'phone local address to computer public address (STUN)',
    );
  });

  test('ignores other messages and malformed paths', () {
    expect(describeDirectPath({'t': 'info'}), isNull);
    expect(describeDirectPath({'t': 'path', 'network': 'wifi'}), isNull);
  });
}
