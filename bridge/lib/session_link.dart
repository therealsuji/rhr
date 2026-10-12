import 'session_code.dart';

Uri sessionConnectionWebLink(Uri deepLink) => Uri(
  scheme: 'https',
  host: 'getrhr.dev',
  path: '/connect',
  fragment: Uri.encodeComponent(deepLink.toString()),
);

/// Everything a phone needs to join one session.
///
/// [pin] is the SHA-256 of the certificate the developer's own LAN relay
/// presents (base64url, no padding). That relay has no CA-signed certificate,
/// so the link is what vouches for it; the pin covers every relay addressed by
/// IP, and relays addressed by name are checked against the system CAs.
typedef SessionConnection = ({String code, List<String> relays, String? pin});

/// A session link carries the same ordered relay choices as its QR.
Uri sessionConnectionLink(String code, List<String> relays, {String? pin}) =>
    Uri(
      scheme: 'rhr',
      host: 'connect',
      queryParameters: {'code': code, 'relay': relays, 'pin': ?pin},
    );

final _pinPattern = RegExp(r'^[A-Za-z0-9_-]{43}$');

/// Whether a session may use [relay].
///
/// `wss` anywhere. Plain `ws` only on loopback, where nothing crosses a
/// network: on a LAN or the internet it would hand the session code, and with
/// it the phone's VM service, to anyone who can see the traffic.
bool isAllowedRelay(Uri relay) {
  if (relay.host.isEmpty || relay.userInfo.isNotEmpty || relay.hasFragment) {
    return false;
  }
  return switch (relay.scheme) {
    'wss' => true,
    'ws' => const {'127.0.0.1', 'localhost', '::1'}.contains(relay.host),
    _ => false,
  };
}

SessionConnection parseSessionConnectionLink(String raw) {
  var uri = Uri.parse(raw);
  if (uri.scheme == 'https' &&
      uri.host == 'getrhr.dev' &&
      uri.path == '/connect') {
    uri = Uri.parse(Uri.decodeComponent(uri.fragment));
  }
  final code = uri.queryParameters['code'];
  final relays = uri.queryParametersAll['relay'] ?? const <String>[];
  final pins = uri.queryParametersAll['pin'] ?? const <String>[];
  if (uri.scheme != 'rhr' ||
      uri.host != 'connect' ||
      uri.path.isNotEmpty ||
      uri.hasFragment ||
      uri.userInfo.isNotEmpty ||
      uri.hasPort ||
      code == null ||
      !isValidRhrSessionCode(code) ||
      relays.isEmpty ||
      uri.queryParametersAll['code']?.length != 1 ||
      pins.length > 1 ||
      (pins.isNotEmpty && !_pinPattern.hasMatch(pins.single))) {
    throw const FormatException(
      'Invalid RHR connection link. Get a new link from your terminal.',
    );
  }
  for (final value in relays) {
    final relay = Uri.tryParse(value);
    if (relay == null || !isAllowedRelay(relay)) {
      throw const FormatException(
        'The RHR connection link has an invalid relay address.',
      );
    }
  }
  return (
    code: code,
    relays: List.unmodifiable(relays),
    pin: pins.isEmpty ? null : pins.single,
  );
}
