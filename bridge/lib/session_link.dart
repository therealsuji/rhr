import 'session_code.dart';

Uri sessionConnectionWebLink(Uri deepLink) => Uri(
  scheme: 'https',
  host: 'getrhr.dev',
  path: '/connect',
  fragment: Uri.encodeComponent(deepLink.toString()),
);

/// A session link carries the same ordered relay choices as its QR.
Uri sessionConnectionLink(String code, List<String> relays) => Uri(
  scheme: 'rhr',
  host: 'connect',
  queryParameters: {'code': code, 'relay': relays},
);

({String code, List<String> relays}) parseSessionConnectionLink(String raw) {
  var uri = Uri.parse(raw);
  if (uri.scheme == 'https' &&
      uri.host == 'getrhr.dev' &&
      uri.path == '/connect') {
    uri = Uri.parse(Uri.decodeComponent(uri.fragment));
  }
  final code = uri.queryParameters['code'];
  final relays = uri.queryParametersAll['relay'] ?? const <String>[];
  if (uri.scheme != 'rhr' ||
      uri.host != 'connect' ||
      uri.path.isNotEmpty ||
      uri.hasFragment ||
      uri.userInfo.isNotEmpty ||
      uri.hasPort ||
      code == null ||
      !isValidRhrSessionCode(code) ||
      relays.isEmpty ||
      uri.queryParametersAll['code']?.length != 1) {
    throw const FormatException(
      'Invalid RHR connection link. Ask your developer for a new link.',
    );
  }
  for (final value in relays) {
    final relay = Uri.tryParse(value);
    if (relay == null ||
        !const {'ws', 'wss'}.contains(relay.scheme) ||
        relay.host.isEmpty ||
        relay.userInfo.isNotEmpty ||
        relay.hasFragment) {
      throw const FormatException(
        'The RHR connection link has an invalid relay address.',
      );
    }
  }
  return (code: code, relays: List.unmodifiable(relays));
}
