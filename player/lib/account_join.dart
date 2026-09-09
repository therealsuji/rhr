// Joining an account by redeeming a scanned invitation.
//
// The phone never signs in. It generates an installation identity on first
// run, redeems an invite, and holds a membership from then on — which is what
// lets a tester lend their phone to a developer without being asked to create
// an account of their own.
//
// Redemption goes straight to the account service over HTTPS, never through
// the relay: the relay does not authenticate its peers, and one of the
// transports it speaks is a plaintext LAN socket.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'session_code_field.dart';

const _connector = MethodChannel('rhr/connector');

/// An account this phone has joined.
class JoinedAccount {
  const JoinedAccount({required this.id, required this.email});

  final String id;

  /// Whose account it is, as the developer's sign-in reported it.
  final String email;

  Map<String, Object?> toJson() => {'id': id, 'email': email};

  static JoinedAccount? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    return id is String
        ? JoinedAccount(id: id, email: json['email'] is String ? json['email'] as String : '')
        : null;
  }
}

sealed class JoinOutcome {
  const JoinOutcome();
}

class JoinAccepted extends JoinOutcome {
  const JoinAccepted(this.account, {required this.alreadyJoined});

  final JoinedAccount account;

  /// True when this phone had already joined — a retry after a lost response,
  /// which must read as success rather than a second join.
  final bool alreadyJoined;
}

class JoinRejected extends JoinOutcome {
  const JoinRejected(this.reason);

  final String reason;
}

/// Redeems [invite], joining this installation to the account behind it.
Future<JoinOutcome> redeemInvite(AccountInvite invite) async {
  final installationId =
      await _connector.invokeMethod<String>('installationId');
  final secret = await _connector.invokeMethod<String>('installationSecret');
  if (installationId == null || secret == null) {
    return const JoinRejected('This phone could not identify itself.');
  }
  final http = HttpClient();
  try {
    final request = await http.postUrl(Uri.parse('${invite.service}/device/join'));
    request.headers.contentType = ContentType.json;
    request.write(
      jsonEncode({
        'invite': invite.token,
        'installationId': installationId,
        // Registered on the first join and required by anything that acts on
        // a membership afterwards.
        'secret': secret,
        'label': await _deviceLabel(),
      }),
    );
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    final json = jsonDecode(body) as Map<String, Object?>;
    if (response.statusCode != 200) {
      return JoinRejected(
        json['error'] is String
            ? json['error']! as String
            : 'The invitation could not be used.',
      );
    }
    final account = JoinedAccount(
      id: json['accountId']! as String,
      email: json['account'] is String ? json['account']! as String : '',
    );
    await _remember(account);
    return JoinAccepted(
      account,
      alreadyJoined: json['alreadyJoined'] == true,
    );
  } on SocketException {
    return const JoinRejected('Could not reach the account service.');
  } on FormatException {
    return const JoinRejected('The account service sent something unexpected.');
  } finally {
    http.close();
  }
}

/// The session name this phone waits on when reached through an account.
///
/// Derived from the installation id rather than fetched, so it is the same
/// name the account service gives a developer, computed without a round trip
/// and available offline. Not a secret: it says where to wait, and membership
/// is what decides who may.
String rendezvousFor(String installationId) {
  final safe = installationId.replaceAll(RegExp('[^A-Za-z0-9_-]'), '');
  return 'dev-$safe'.padRight(16, '0');
}

/// Whether a session name is a derived rendezvous rather than a typed code.
///
/// Codes and rendezvous names both name a session, so both are valid here;
/// they differ only in where they came from.
bool isRendezvousName(String value) =>
    value.startsWith('dev-') && value.length >= 16;

/// This installation's rendezvous, or null before it has one.
Future<String?> ownRendezvous() async {
  final id = await _connector.invokeMethod<String>('installationId');
  return id == null ? null : rendezvousFor(id);
}

/// What the developer will see this phone called in their device list.
Future<String> _deviceLabel() async {
  final model = await _connector.invokeMethod<String>('deviceLabel');
  return model?.trim().isNotEmpty == true ? model!.trim() : 'phone';
}

const _accountsKey = 'rhr_joined_accounts';

/// The accounts this phone belongs to.
///
/// Kept apart from the saved session code: disconnecting a session must not
/// drop a membership, and leaving an account must not clear a code.
Future<List<JoinedAccount>> joinedAccounts() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getStringList(_accountsKey) ?? const [];
  return raw
      .map((entry) => JoinedAccount.fromJson(jsonDecode(entry)))
      .whereType<JoinedAccount>()
      .toList(growable: false);
}

Future<void> _remember(JoinedAccount account) async {
  final existing = await joinedAccounts();
  if (existing.any((a) => a.id == account.id)) return;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setStringList(_accountsKey, [
    ...existing.map((a) => jsonEncode(a.toJson())),
    jsonEncode(account.toJson()),
  ]);
}

/// Forgets an account locally.
///
/// Blocks it here immediately, whatever the network is doing: the tester's
/// decision to stop lending their phone should not wait on a server they may
/// not be able to reach. The account's own record is removed separately.
Future<void> forgetAccount(String accountId) async {
  final remaining = (await joinedAccounts()).where((a) => a.id != accountId);
  final prefs = await SharedPreferences.getInstance();
  await prefs.setStringList(
    _accountsKey,
    remaining.map((a) => jsonEncode(a.toJson())).toList(growable: false),
  );
}
