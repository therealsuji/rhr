import 'dart:math';

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
