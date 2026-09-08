// Developer sign-in for the CLI, over the OAuth 2.0 Device Authorization
// Grant (RFC 8628).
//
// A terminal is not a browser, so the usual redirect dance does not fit: the
// device flow prints a short code, the developer approves it in a browser
// anywhere — another machine, a phone — and this process polls until a token
// comes back. That also keeps working over SSH and inside containers, where a
// localhost callback has no port to listen on.
//
// Nothing here touches the session path. A developer who never logs in keeps
// using session codes exactly as before.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

/// What the CLI shows the developer while it waits for them to approve.
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

  /// Short, human-transcribable code (`ABCD-EFGH`) the developer types in.
  final String userCode;
  final String verificationUri;

  /// The same page with the code already filled in, for a clickable terminal.
  final String verificationUriComplete;
  final Duration expiresIn;

  /// Minimum gap between polls, set by the server.
  final Duration interval;
}

/// A signed-in developer's credentials.
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

  /// Which identity provider signed this developer in, when the service says.
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

/// Raised when sign-in cannot proceed: the developer declined, the code
/// expired, or the service said no.
class AuthFailure implements Exception {
  const AuthFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Asks the service for a code the developer can approve in a browser.
Future<DeviceCodePrompt> requestDeviceCode({HttpClient? client}) async {
  final http = client ?? HttpClient();
  try {
    final request = await http.postUrl(Uri.parse(_authorizeDeviceUrl));
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({'client_id': rhrClientId}));
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) {
      throw AuthFailure('could not start sign-in (${response.statusCode}): $body');
    }
    final json = jsonDecode(body) as Map<String, Object?>;
    return DeviceCodePrompt(
      deviceCode: json['device_code']! as String,
      userCode: json['user_code']! as String,
      verificationUri: json['verification_uri']! as String,
      verificationUriComplete:
          (json['verification_uri_complete'] as String?) ??
          json['verification_uri']! as String,
      expiresIn: Duration(seconds: (json['expires_in'] as num?)?.toInt() ?? 300),
      interval: Duration(seconds: (json['interval'] as num?)?.toInt() ?? 5),
    );
  } finally {
    if (client == null) http.close();
  }
}

/// Polls until the developer approves in their browser, or the attempt ends.
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
      request.headers.contentType =
          ContentType('application', 'x-www-form-urlencoded');
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

/// Where the signed-in session lives between runs.
///
/// Beside the rest of this tool's state rather than in the project, so a token
/// is never committed by accident.
File accountSessionFile() {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';
  return File('$home/.rhr/session.json');
}

/// Stores the session readable only by its owner.
///
/// The token authorises this developer's devices, so it deserves the same care
/// as an SSH key: on a shared machine the default umask would otherwise leave
/// it world-readable.
Future<void> saveAccountSession(AccountSession session) async {
  final file = accountSessionFile();
  await file.parent.create(recursive: true);
  await file.writeAsString(jsonEncode(session.toJson()));
  if (!Platform.isWindows) {
    await Process.run('chmod', ['600', file.path]);
  }
}

Future<AccountSession?> loadAccountSession() async {
  final file = accountSessionFile();
  if (!file.existsSync()) return null;
  try {
    final json = jsonDecode(await file.readAsString());
    if (json is! Map<String, Object?>) return null;
    return AccountSession.fromJson(json);
  } on FormatException {
    // A truncated or hand-edited file should send the developer back through
    // sign-in rather than crash the command they actually ran.
    return null;
  }
}

Future<void> clearAccountSession() async {
  final file = accountSessionFile();
  if (file.existsSync()) await file.delete();
}
