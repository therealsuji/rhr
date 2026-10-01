import 'dart:math';

/// Alphabet for session codes: no `0 1 i l o`, the characters people misread
/// off a screen or hear wrong over a call.
///
/// Twelve characters from these 31 symbols is about 59 bits, which is what
/// keeps a code unguessable while a session is live. Word lists were
/// considered and rejected: six words from a 2048-word list buys 66 bits at
/// two to three times the typing, and only pays off when a code is read
/// aloud — which the QR already covers.
const rhrSessionCodeAlphabet = '23456789abcdefghjkmnpqrstuvwxyz';

final rhrSessionCodePattern = RegExp(
  '^rhr-[$rhrSessionCodeAlphabet]{4}-'
  '[$rhrSessionCodeAlphabet]{4}-'
  '[$rhrSessionCodeAlphabet]{4}\$',
);

bool isValidRhrSessionCode(String code) => rhrSessionCodePattern.hasMatch(code);

/// Fresh bearer-token session code grouped for painless manual entry.
String mintRhrSessionCode({Random? random}) {
  random ??= Random.secure();
  final token = List.generate(
    12,
    (_) =>
        rhrSessionCodeAlphabet[random!.nextInt(rhrSessionCodeAlphabet.length)],
  ).join();
  return 'rhr-${token.substring(0, 4)}-${token.substring(4, 8)}-'
      '${token.substring(8, 12)}';
}
