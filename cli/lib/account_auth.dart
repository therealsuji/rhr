// Account sign-in for the CLI, over the OAuth 2.0 Device Authorization
// Grant (RFC 8628).
//
// A terminal is not a browser, so the usual redirect dance does not fit: the
// device flow prints a short code, the user approves it in a browser
// anywhere — another machine, a phone — and this process polls until a token
// comes back. That also keeps working over SSH and inside containers, where a
// localhost callback has no port to listen on.
//
// Nothing here touches the session path. A user who never logs in keeps
// using session codes exactly as before.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:rhr_bridge/relay_defaults.dart';
import 'package:rhr_bridge/session_code.dart';

import 'private_file.dart';

/// WorkOS AuthKit, which implements the device grant as a first-class endpoint.
const _authorizeDeviceUrl =
    'https://api.workos.com/user_management/authorize/device';
const _tokenUrl = 'https://api.workos.com/user_management/authenticate';

/// Public client identifier. Not a secret: the device grant is designed for
/// clients that cannot keep one, which is why there is no client secret here.
/// Overridable so a contributor can point at their own environment.
const rhrClientId = String.fromEnvironment(
  'RHR_CLIENT_ID',
  defaultValue: 'client_01M20J8AWHXDECB250NDEB8YYJ',
);

/// What the CLI shows the user while it waits for them to approve.
class DeviceCodePrompt {
  const DeviceCodePrompt({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.verificationUriComplete,
    required this.expiresIn,
    required this.interval,
  });

  final String deviceCode;

  /// Short, human-transcribable code (`ABCD-EFGH`) the user types in.
  final String userCode;
  final String verificationUri;

  /// The same page with the code already filled in, for a clickable terminal.
  final String verificationUriComplete;
  final Duration expiresIn;

  /// Minimum gap between polls, set by the server.
  final Duration interval;
}

/// A signed-in user's credentials.
class AccountSession {
  const AccountSession({
    required this.accessToken,
    required this.refreshToken,
    required this.userId,
    required this.email,
    this.provider = '',
  });

  final String accessToken;
  final String refreshToken;
  final String userId;
  final String email;

  /// Which identity provider signed this user in, when the service says.
  ///
  /// Recorded from the start because the same person arriving once through
  /// Google and once through GitHub is the case that decides whether they get
  /// one account or two — and that is expensive to change after people have
  /// accounts.
  final String provider;

  Map<String, Object?> toJson() => {
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'userId': userId,
    'email': email,
    'provider': provider,
  };

  static AccountSession? fromJson(Map<String, Object?> json) {
    final access = json['accessToken'];
    final refresh = json['refreshToken'];
    final id = json['userId'];
    final email = json['email'];
    if (access is! String || refresh is! String || id is! String) return null;
    final provider = json['provider'];
    return AccountSession(
      accessToken: access,
      refreshToken: refresh,
      userId: id,
      email: email is String ? email : '',
      provider: provider is String ? provider : '',
    );
  }
}

/// Raised when sign-in cannot proceed: the user declined, the code
/// expired, or the service said no.
class AuthFailure implements Exception {
  const AuthFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Asks the service for a code the user can approve in a browser.
Future<DeviceCodePrompt> requestDeviceCode({HttpClient? client}) async {
  final http = client ?? HttpClient();
  try {
    final request = await http.postUrl(Uri.parse(_authorizeDeviceUrl));
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({'client_id': rhrClientId}));
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) {
      throw AuthFailure(
        'could not start sign-in (${response.statusCode}): $body',
      );
    }
    final json = jsonDecode(body) as Map<String, Object?>;
    return DeviceCodePrompt(
      deviceCode: json['device_code']! as String,
      userCode: json['user_code']! as String,
      verificationUri: json['verification_uri']! as String,
      verificationUriComplete:
          (json['verification_uri_complete'] as String?) ??
          json['verification_uri']! as String,
      expiresIn: Duration(
        seconds: (json['expires_in'] as num?)?.toInt() ?? 300,
      ),
      interval: Duration(seconds: (json['interval'] as num?)?.toInt() ?? 5),
    );
  } finally {
    if (client == null) http.close();
  }
}

/// Polls until the user approves in their browser, or the attempt ends.
///
/// `authorization_pending` is the normal answer while they are still typing;
/// `slow_down` means back off, and RFC 8628 says by five seconds. Everything
/// else is terminal, so the caller is told rather than left waiting.
Future<AccountSession> pollForToken(
  DeviceCodePrompt prompt, {
  HttpClient? client,
}) async {
  final http = client ?? HttpClient();
  var interval = prompt.interval;
  final deadline = DateTime.now().add(prompt.expiresIn);
  try {
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(interval);
      final request = await http.postUrl(Uri.parse(_tokenUrl));
      request.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
      );
      request.write(
        'grant_type=${Uri.encodeComponent('urn:ietf:params:oauth:grant-type:device_code')}'
        '&device_code=${Uri.encodeComponent(prompt.deviceCode)}'
        '&client_id=${Uri.encodeComponent(rhrClientId)}',
      );
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, Object?>;

      if (response.statusCode == 200) {
        final user = json['user'] as Map<String, Object?>?;
        return AccountSession(
          accessToken: json['access_token']! as String,
          refreshToken: json['refresh_token']! as String,
          userId: (user?['id'] as String?) ?? '',
          email: (user?['email'] as String?) ?? '',
          provider: (json['authentication_method'] as String?) ?? '',
        );
      }

      switch (json['error']) {
        case 'authorization_pending':
          continue;
        case 'slow_down':
          interval += const Duration(seconds: 5);
        case 'access_denied':
          throw const AuthFailure('sign-in was declined');
        case 'expired_token':
          throw const AuthFailure('the code expired — run `rhr login` again');
        default:
          throw AuthFailure(
            'sign-in failed: ${json['error_description'] ?? json['error'] ?? body}',
          );
      }
    }
    throw const AuthFailure('the code expired — run `rhr login` again');
  } finally {
    if (client == null) http.close();
  }
}

/// Where this machine's sign-in stands.
///
/// "Never signed in" and "the service ended the sign-in" both leave no usable
/// token, but only the first may quietly fall back to a pairing link: a user
/// whose session ended still expects their account's phone, and has to be told
/// to sign in again rather than handed a QR.
sealed class AccountState {
  const AccountState();
}

final class SignedIn extends AccountState {
  const SignedIn(this.session);
  final AccountSession session;
}

/// No sign-in on this machine, or `rhr logout` removed it.
final class SignedOut extends AccountState {
  const SignedOut();
}

/// A stored sign-in the account service refused to refresh, in its words
/// ("Session ended due to inactivity."). It stays on disk until `rhr login`
/// replaces it, so every command keeps saying why instead of only the first.
final class SignInEnded extends AccountState {
  const SignInEnded(this.reason);
  final String reason;
}

/// The account service could not be asked: offline, DNS, a 5xx.
final class AccountUnreachable extends AccountState {
  const AccountUnreachable(this.reason);
  final String reason;
}

/// Exchanges the refresh token for a new access token.
///
/// WorkOS access tokens last minutes, so any command run the next morning
/// would otherwise be told to sign in again. The refresh token outlives them
/// and is what makes sign-in a one-time step rather than a daily one.
Future<AccountState> refreshAccountSession(
  AccountSession session, {
  HttpClient? client,
}) async {
  final http = client ?? HttpClient();
  try {
    final request = await http.postUrl(Uri.parse(_tokenUrl));
    request.headers.contentType = ContentType(
      'application',
      'x-www-form-urlencoded',
    );
    request.write(
      'grant_type=refresh_token'
      '&refresh_token=${Uri.encodeComponent(session.refreshToken)}'
      '&client_id=${Uri.encodeComponent(rhrClientId)}',
    );
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    return refreshOutcome(response.statusCode, body, session);
  } on Exception catch (error) {
    return AccountUnreachable('$error');
  } finally {
    if (client == null) http.close();
  }
}

/// What a refresh response means. A 4xx is the service's answer about this
/// session, so it ends it; anything else says nothing about the session.
AccountState refreshOutcome(int status, String body, AccountSession session) {
  Object? json;
  try {
    json = jsonDecode(body);
  } on FormatException {
    json = null;
  }
  if (status == 200 && json is Map<String, Object?>) {
    final access = json['access_token'];
    if (access is String) {
      final user = json['user'];
      String? field(String name) =>
          user is Map<String, Object?> && user[name] is String
          ? user[name]! as String
          : null;
      return SignedIn(
        AccountSession(
          accessToken: access,
          refreshToken:
              (json['refresh_token'] as String?) ?? session.refreshToken,
          userId: field('id') ?? session.userId,
          email: field('email') ?? session.email,
          provider: session.provider,
        ),
      );
    }
  }
  if (status >= 400 && status < 500) {
    final reason = json is Map<String, Object?>
        ? json['error_description'] ?? json['error']
        : null;
    return SignInEnded(reason is String ? reason : 'HTTP $status');
  }
  return AccountUnreachable('the account service answered HTTP $status');
}

/// The stored sign-in, with its token refreshed when it is about to expire.
///
/// Every caller wants a usable token rather than whatever was written to disk
/// last time, so the refresh happens here instead of at each call site, and
/// the refreshed session is written back so the next command starts valid.
Future<AccountState> accountState() async {
  final stored = await loadAccountSession();
  if (stored == null) return const SignedOut();
  if (!_expiresSoon(stored.accessToken)) return SignedIn(stored);
  final refreshed = await refreshAccountSession(stored);
  if (refreshed is SignedIn) await saveAccountSession(refreshed.session);
  return refreshed;
}

/// What to tell a user who needs to be signed in and is not.
String signInHint(AccountState state) => switch (state) {
  SignedIn() => '',
  SignedOut() => 'not signed in, run `rhr login`',
  SignInEnded(:final reason) => 'your sign-in ended ($reason), run `rhr login`',
  AccountUnreachable(:final reason) =>
    'could not reach the account service: $reason',
};

/// True when a token is expired or close enough that a request would race it.
bool _expiresSoon(String jwt) {
  final parts = jwt.split('.');
  if (parts.length != 3) return true;
  try {
    var payload = parts[1].replaceAll('-', '+').replaceAll('_', '/');
    payload += '=' * ((4 - payload.length % 4) % 4);
    final claims =
        jsonDecode(utf8.decode(base64.decode(payload))) as Map<String, Object?>;
    final exp = claims['exp'];
    if (exp is! num) return true;
    final expiry = DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000);
    // A minute of headroom: a token that expires mid-request is the same
    // problem as one that expired already.
    return DateTime.now().add(const Duration(minutes: 1)).isAfter(expiry);
  } on FormatException {
    return true;
  }
}

/// The account service: the deployment the CLI was built against. The bearer
/// token only ever goes here, never to a relay passed with `--relay` or named
/// in `.rhr.yaml`, which may belong to someone else.
String accountService() => const String.fromEnvironment(
  'RHR_RELAY',
  defaultValue: defaultPublicRelay,
).replaceFirst('wss://', 'https://').replaceFirst('ws://', 'http://');

/// Whether the WebSocket [relay] is the deployment behind the HTTPS [service].
///
/// Decides who is handed a ticket, so it compares origins exactly. Ports are
/// defaulted by scheme: Dart's [Uri.port] answers 443 for https but 0 for
/// wss, so a plain `wss://getrhr.dev` would never match `https://getrhr.dev`.
bool relayIsService(String relay, String service) {
  final serviceUri = Uri.parse(service);
  final relayUri = Uri.tryParse(relay);
  return relayUri != null &&
      relayUri.scheme == (serviceUri.scheme == 'https' ? 'wss' : 'ws') &&
      relayUri.host == serviceUri.host &&
      _port(relayUri) == _port(serviceUri);
}

int _port(Uri uri) {
  if (uri.hasPort) return uri.port;
  return uri.scheme == 'https' || uri.scheme == 'wss' ? 443 : 80;
}

/// Permission from the account service to dial one device once.
typedef DeviceGrant = ({String rendezvous, String ticket});

/// Asks the account service for a device this account may use.
///
/// The rendezvous says where the phone waits; the ticket is what the relay
/// requires before it lets this developer in, and it lives for minutes, so
/// every dial asks again (see [rendezvousTicket]). That also means a device
/// removed from the account stops answering within one ticket's lifetime.
/// A device this account was never invited to returns null, and the caller
/// must not fall back to an unauthenticated session on somebody's phone.
Future<DeviceGrant?> requestDeviceGrant({
  required String service,
  required String installationId,
  required AccountSession session,
  HttpClient? client,
}) async {
  final http = client ?? HttpClient();
  try {
    final request = await http.getUrl(
      Uri.parse(
        '$service/account/connect'
        '?installationId=${Uri.encodeQueryComponent(installationId)}',
      ),
    );
    request.headers.add('Authorization', 'Bearer ${session.accessToken}');
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) return null;
    final json = jsonDecode(body);
    if (json is! Map<String, Object?>) return null;
    return switch (json) {
      {'rendezvous': final String rendezvous, 'ticket': final String ticket} =>
        (rendezvous: rendezvous, ticket: ticket),
      _ => null,
    };
  } on Exception {
    return null;
  } finally {
    if (client == null) http.close();
  }
}

/// A fresh ticket for dialing [rendezvous], or null when this developer is
/// signed out or the device has left their account.
Future<String?> rendezvousTicket(String rendezvous) async {
  final installationId = rhrRendezvousInstallation(rendezvous);
  if (installationId == null) return null;
  if (await accountState() case SignedIn(:final session)) {
    final grant = await requestDeviceGrant(
      service: accountService(),
      installationId: installationId,
      session: session,
    );
    return grant?.rendezvous == rendezvous ? grant?.ticket : null;
  }
  return null;
}

/// The device this project last connected to.
///
/// Per project rather than global: someone with two projects and two phones
/// should not have one of them silently retarget the other. Under
/// `.dart_tool` with the rest of RHR's project state, where it is neither a
/// file in the user's tree nor something a commit picks up.
File _preferredDeviceFile(String project) =>
    File('$project/.dart_tool/rhr/device');

/// Where earlier releases kept it, in the project root.
File _legacyPreferredDeviceFile(String project) => File('$project/.rhr-device');

Future<String?> preferredDevice(String project) async {
  final legacy = _legacyPreferredDeviceFile(project);
  if (legacy.existsSync()) {
    final value = (await legacy.readAsString()).trim();
    await legacy.delete();
    if (value.isNotEmpty) await rememberDevice(project, value);
    stderr.writeln(
      '[rhr] Moved .rhr-device to .dart_tool/rhr/device, with the rest of '
      "rhr's project state.",
    );
  }
  final file = _preferredDeviceFile(project);
  if (!file.existsSync()) return null;
  final value = (await file.readAsString()).trim();
  return value.isEmpty ? null : value;
}

Future<void> rememberDevice(String project, String installationId) async {
  final file = _preferredDeviceFile(project);
  await file.parent.create(recursive: true);
  await file.writeAsString('$installationId\n');
}

Future<void> forgetPreferredDevice(String project) async {
  final file = _preferredDeviceFile(project);
  if (file.existsSync()) await file.delete();
}

/// A phone on the signed-in account: its installation id, which the account
/// service knows it by, and the name the phone gave itself.
typedef AccountDevice = ({String id, String label});

/// The phones on [session]'s account.
Future<List<AccountDevice>> listAccountDevices(
  AccountSession session, {
  HttpClient? client,
}) async {
  final http = client ?? HttpClient();
  try {
    final request = await http.getUrl(
      Uri.parse('${accountService()}/account/devices'),
    );
    request.headers.add('Authorization', 'Bearer ${session.accessToken}');
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) {
      throw AuthFailure('could not list devices: $body');
    }
    final devices = (jsonDecode(body) as Map<String, Object?>)['devices'];
    return [
      for (final entry in devices is List ? devices : const [])
        if (entry is Map && entry['installationId'] is String)
          (
            id: entry['installationId'] as String,
            label: entry['label'] is String ? entry['label'] as String : '',
          ),
    ];
  } finally {
    if (client == null) http.close();
  }
}

/// The devices [wanted] names: the one whose id it is; else those whose
/// label it is, ignoring case; else those whose id starts with it. More than
/// one means it is ambiguous, none that it names nothing.
List<AccountDevice> matchDevices(List<AccountDevice> devices, String wanted) {
  final byId = devices.where((d) => d.id == wanted).toList();
  if (byId.isNotEmpty) return byId;
  final byLabel = devices
      .where((d) => d.label.toLowerCase() == wanted.toLowerCase())
      .toList();
  if (byLabel.isNotEmpty) return byLabel;
  return devices.where((d) => d.id.startsWith(wanted)).toList();
}

/// Where the signed-in session lives between runs.
///
/// Beside the rest of this tool's state rather than in the project, so a token
/// is never committed by accident.
File accountSessionFile() {
  final home =
      Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      '.';
  return File('$home/.rhr/session.json');
}

/// Stores the session readable only by its owner.
///
/// The token authorises this user's devices, so it deserves the same care
/// as an SSH key: on a shared machine the default umask would otherwise leave
/// it world-readable.
Future<void> saveAccountSession(AccountSession session) async =>
    writePrivateFile(accountSessionFile(), jsonEncode(session.toJson()));

Future<AccountSession?> loadAccountSession() async {
  final file = accountSessionFile();
  if (!file.existsSync()) return null;
  try {
    final json = jsonDecode(await file.readAsString());
    if (json is! Map<String, Object?>) return null;
    return AccountSession.fromJson(json);
  } on FormatException {
    // A truncated or hand-edited file should send the user back through
    // sign-in rather than crash the command they actually ran.
    return null;
  }
}

Future<void> clearAccountSession() async {
  final file = accountSessionFile();
  if (file.existsSync()) await file.delete();
}
