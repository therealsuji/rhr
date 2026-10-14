// Joining an account by redeeming a scanned invitation.
//
// The phone never signs in. It generates an installation identity on first
// run, redeems an invite, and holds a membership from then on. That is how the
// user adds a phone to their own account: they scan an invite from the
// computer, and nobody types a password on the phone.
//
// Redemption goes to the account service baked into this build, over HTTPS
// and from native code, never through the relay and never to a service an
// invite names: the join carries the installation secret.

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:rhr_bridge/session_code.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'session_code_field.dart';

const _connector = MethodChannel('rhr/connector');

/// An account this phone has joined.
class JoinedAccount {
  const JoinedAccount({required this.id, required this.email});

  final String id;

  /// Whose account it is, as the user's sign-in on the computer reported it.
  final String email;

  Map<String, Object?> toJson() => {'id': id, 'email': email};

  static JoinedAccount? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    return id is String
        ? JoinedAccount(
            id: id,
            email: json['email'] is String ? json['email'] as String : '',
          )
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

/// Whose account [invite] joins, from the account service, or the reason it
/// cannot be used. Asked before the consent screen so the address a tester
/// reads comes from the service, not from a QR anyone can print.
Future<({String? account, String? error})> previewInvite(
  AccountInvite invite,
) async {
  final service = await _connector.invokeMethod<String>('accountService');
  if (service == null ||
      Uri.parse(service).origin != Uri.parse(invite.service).origin) {
    return (
      account: null,
      error:
          'This invite is for a different RHR service '
          '(${Uri.parse(invite.service).host}).',
    );
  }
  final json = await _call('previewInvite', invite);
  return switch (json) {
    {'account': final String account} => (account: account, error: null),
    {'error': final String error} => (account: null, error: error),
    _ => (
      account: null,
      error: 'The account service sent something unexpected.',
    ),
  };
}

/// Redeems [invite], joining this installation to the account behind it.
///
/// The request is made natively: it carries the installation secret, which
/// Dart never holds (see AccountClient.kt).
Future<JoinOutcome> redeemInvite(AccountInvite invite) async {
  final json = await _call('joinAccount', invite);
  switch (json) {
    case {'accountId': final String id}:
      final account = JoinedAccount(
        id: id,
        email: json['account'] is String ? json['account']! as String : '',
      );
      await _remember(account);
      return JoinAccepted(
        account,
        alreadyJoined: json['alreadyJoined'] == true,
      );
    case {'error': final String error}:
      return JoinRejected(error);
    default:
      return const JoinRejected(
        'The account service sent something unexpected.',
      );
  }
}

Future<Map<String, Object?>?> _call(String method, AccountInvite invite) async {
  final raw = await _connector.invokeMethod<String>(method, {
    'invite': invite.token,
  });
  if (raw == null) return null;
  try {
    final decoded = jsonDecode(raw);
    return decoded is Map<String, Object?> ? decoded : null;
  } on FormatException {
    return null;
  }
}

/// This installation's rendezvous, or null before it has one.
Future<String?> ownRendezvous() async {
  final id = await _connector.invokeMethod<String>('installationId');
  return id == null ? null : rhrRendezvousFor(id);
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

/// Takes this phone off [account]: forgotten here at once, then removed from
/// the account's device list. Null once both are done, or why the account
/// service could not be told; the phone has left either way.
Future<String?> leaveAccount(JoinedAccount account) async {
  await forgetAccount(account.id);
  final raw = await _connector.invokeMethod<String>('leaveAccount', {
    'accountId': account.id,
  });
  try {
    final json = raw == null ? null : jsonDecode(raw);
    if (json is Map<String, Object?> && json.containsKey('left')) return null;
    if (json is Map<String, Object?> && json['error'] is String) {
      return json['error']! as String;
    }
  } on FormatException {
    // Falls through to the generic reason.
  }
  return 'The account service sent something unexpected.';
}

/// Forgets an account locally.
///
/// Blocks it here immediately, whatever the network is doing: removing the
/// phone from the account should not wait on a server the phone may not be
/// able to reach. The account's own record is removed separately.
Future<void> forgetAccount(String accountId) async {
  final remaining = (await joinedAccounts()).where((a) => a.id != accountId);
  final prefs = await SharedPreferences.getInstance();
  await prefs.setStringList(
    _accountsKey,
    remaining.map((a) => jsonEncode(a.toJson())).toList(growable: false),
  );
}
