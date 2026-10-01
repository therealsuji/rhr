import 'dart:io';

import 'package:crypto/crypto.dart';

import 'apk_identity.dart';
import 'player_update.dart';
import 'version.dart';

/// The RHR Agent's package: the accessibility service that serves device
/// control (player/android/agent).
const agentPackage = 'dev.rhr.agent';

/// The RHR Agent APK for a phone whose player is signed with
/// [playerCertificate] (SHA-256, lowercase hex). The agent only serves a
/// player signed with its own key, so the two must match.
///
/// The published player gets the agent published with this CLI's release. A
/// player built from this checkout gets the agent built from it too:
/// `./gradlew :agent:assembleDebug` in player/android, which signs with the
/// same key as that player build.
Future<File> agentApkFor(String playerCertificate) async {
  final template = await resolvePlayerTemplate();
  final published = File(
    '$template/tool/release-signing.sha256',
  ).readAsStringSync().trim();
  final apk = playerCertificate == published
      ? await _publishedAgent()
      : File('$template/build/agent/outputs/apk/debug/agent-debug.apk');
  if (!apk.existsSync()) {
    throw StateError(
      'The player on the phone is not the published build, so RHR Agent must '
      'be built with the same key: run `./gradlew :agent:assembleDebug` in '
      '$template/android, then try again.',
    );
  }
  final identity = await readApkIdentity(apk);
  if (identity.package != agentPackage) {
    throw StateError('${apk.path} is ${identity.package}, not RHR Agent.');
  }
  if (identity.certificate != playerCertificate) {
    throw StateError(
      'RHR Agent at ${apk.path} is signed with ${identity.certificate}, but '
      'the player on the phone is signed with $playerCertificate. The agent '
      'only serves a player signed with its own key; build both with the '
      'same one.',
    );
  }
  return apk;
}

/// The agent attached to this CLI version's GitHub release, downloaded once
/// and checked against the release's SHA256SUMS.
Future<File> _publishedAgent() async {
  final name = 'rhr-agent-$rhrVersion.apk';
  final home = Platform.environment['HOME'] ?? Directory.systemTemp.path;
  final cached = File('$home/.rhr/agent/$name');
  if (cached.existsSync()) return cached;
  final base =
      'https://github.com/therealsuji/rhr/releases/download/v$rhrVersion';
  final sums = String.fromCharCodes(await _download('$base/SHA256SUMS'));
  final expected = checksumIn(sums, name);
  if (expected == null) {
    throw StateError('The v$rhrVersion release lists no checksum for $name.');
  }
  final bytes = await _download('$base/$name');
  if (sha256.convert(bytes).toString() != expected) {
    throw StateError(
      '$name from the v$rhrVersion release failed its checksum.',
    );
  }
  cached.parent.createSync(recursive: true);
  final partial = File('${cached.path}.partial')..writeAsBytesSync(bytes);
  partial.renameSync(cached.path);
  return cached;
}

/// The SHA-256 [name] has in a `sha256sum` listing, or null if it has none.
String? checksumIn(String sums, String name) => RegExp(
  '^([0-9a-f]{64}) [ *]${RegExp.escape(name)}\$',
  multiLine: true,
).firstMatch(sums)?.group(1);

Future<List<int>> _download(String url) async {
  final client = HttpClient();
  try {
    final response = await (await client.getUrl(Uri.parse(url))).close();
    if (response.statusCode != 200) {
      throw StateError('Downloading $url failed: HTTP ${response.statusCode}.');
    }
    return [for (final chunk in await response.toList()) ...chunk];
  } finally {
    client.close();
  }
}
