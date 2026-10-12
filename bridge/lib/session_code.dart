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

/// Prefix of the session a phone waits on when reached through an account.
const rhrRendezvousPrefix = 'dev-';

/// An installation id is 16 random bytes, base64url without padding.
final _installationIdPattern = RegExp(r'^[A-Za-z0-9_-]{22}$');

/// The session name a phone that joined an account waits on.
///
/// Derived from the installation id, so the phone and the account service
/// compute the same name without a round trip. It is not a credential: the
/// relay admits a developer to it only with a ticket from the account service,
/// and the phone only with its installation secret. Mirrors `rendezvousFor`
/// in relay-worker/src/accounts.ts.
String? rhrRendezvousFor(String installationId) =>
    _installationIdPattern.hasMatch(installationId)
    ? '$rhrRendezvousPrefix$installationId'
    : null;

/// The installation [name] is the rendezvous of, or null when it is not one.
String? rhrRendezvousInstallation(String name) {
  if (!name.startsWith(rhrRendezvousPrefix)) return null;
  final id = name.substring(rhrRendezvousPrefix.length);
  return _installationIdPattern.hasMatch(id) ? id : null;
}
