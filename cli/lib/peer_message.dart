import 'dart:convert';

/// Decodes a control message from the phone, or from a relay speaking for it.
///
/// Everything in it is untrusted. A message that is not a JSON object yields
/// null for the caller to drop, rather than a cast error that ends the
/// process. Every string comes back with its control characters removed:
/// phone-supplied text such as device names, framework versions and error
/// messages is printed to the developer's terminal, where an escape sequence
/// could rewrite earlier output, forge a prompt or set the clipboard.
Map<String, Object?>? decodePeerMessage(String raw) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  return decoded is Map<String, Object?> ? _cleanMap(decoded) : null;
}

/// [text] without C0 and C1 control characters, keeping newlines and tabs.
String withoutControlCharacters(String text) =>
    text.replaceAll(_controlCharacters, '');

final _controlCharacters = RegExp(
  '[\u0000-\u0008\u000b-\u001f\u007f-\u009f]',
);

Map<String, Object?> _cleanMap(Map<String, Object?> map) => {
  for (final MapEntry(:key, :value) in map.entries) key: _clean(value),
};

Object? _clean(Object? value) => switch (value) {
  String() => withoutControlCharacters(value),
  Map<String, Object?>() => _cleanMap(value),
  List() => [for (final item in value) _clean(item)],
  _ => value,
};
