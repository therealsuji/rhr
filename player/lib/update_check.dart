// "Am I running the current player?" — asked from the phone, answered
// without a computer.
//
// A tester holds the phone and the developer holds the terminal, so the two
// people who need this answer are not in the same place. Until now nobody
// could get it: every release reported `versionName=0.1.0`, so beta.6, .7
// and .8 were indistinguishable on the device. The release workflow stamps
// the real version in now, and this compares it with what GitHub has.
//
// Deliberately small. It reads a version and opens a URL; it does not
// download 100 MB, resume a transfer, or install anything. Chrome and
// Android already do that part well, and the player has enough install
// paths to maintain.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Where releases live. Public repo, so the API needs no token.
const _releasesApi =
    'https://api.github.com/repos/therealsuji/rhr/releases?per_page=1';
const releasesPage = 'https://github.com/therealsuji/rhr/releases/latest';

/// What a check found.
sealed class UpdateStatus {
  const UpdateStatus();
}

/// The installed player is the newest release.
final class UpToDate extends UpdateStatus {
  const UpToDate(this.version);

  /// The version installed, which is also the newest.
  final String version;
}

/// A newer release exists.
final class UpdateAvailable extends UpdateStatus {
  const UpdateAvailable({required this.installed, required this.latest});

  final String installed;
  final String latest;
}

/// The check could not be completed. [reason] is for the tester, not a log.
final class UpdateCheckFailed extends UpdateStatus {
  const UpdateCheckFailed(this.reason);

  final String reason;
}

/// Asks GitHub for the newest release tag.
///
/// Uses `/releases?per_page=1` rather than `/releases/latest`, because that
/// endpoint excludes pre-releases and every rhr release so far is one — it
/// returns nothing at all today.
Future<String?> fetchLatestTag({HttpClient? client}) async {
  final http = client ?? HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await http.getUrl(Uri.parse(_releasesApi));
    // GitHub wants a User-Agent and rejects requests without one.
    request.headers.set(HttpHeaders.userAgentHeader, 'rhr-player');
    request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
    final response = await request.close().timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw HttpException('GitHub answered ${response.statusCode}');
    }
    final body = await response.transform(utf8.decoder).join();
    final releases = jsonDecode(body);
    if (releases is! List || releases.isEmpty) return null;
    final tag = (releases.first as Map<String, dynamic>)['tag_name'];
    return tag is String ? tag : null;
  } finally {
    if (client == null) http.close();
  }
}

/// Compares the installed version with the newest release tag.
///
/// Both sides are messy in their own way: the tag carries a leading `v`, and
/// the installed version is whatever `--build-name` stamped. Normalising is
/// the whole job, so it is separate from the network call and tested.
UpdateStatus compareVersions({
  required String installed,
  required String? latestTag,
}) {
  if (latestTag == null || latestTag.isEmpty) {
    return const UpdateCheckFailed('No releases found.');
  }
  final latest = _normalise(latestTag);
  final current = _normalise(installed);
  if (current.isEmpty) {
    return const UpdateCheckFailed('This build does not report its version.');
  }
  return current == latest
      ? UpToDate(current)
      : UpdateAvailable(installed: current, latest: latest);
}

/// Strips a leading `v` and surrounding whitespace.
///
/// Equality is the comparison, not ordering. A tester whose build differs
/// from the release should look at the release either way, and guessing
/// which of `0.1.0-beta.8` and `0.1.0` is "newer" invites being confidently
/// wrong about a locally built player.
String _normalise(String version) {
  final trimmed = version.trim();
  return trimmed.startsWith('v') ? trimmed.substring(1) : trimmed;
}

/// Reads the installed version, asks GitHub, and reports the difference.
Future<UpdateStatus> checkForUpdate({
  required Future<String> Function() installedVersion,
  Future<String?> Function()? fetchTag,
}) async {
  try {
    final installed = await installedVersion();
    final tag = await (fetchTag ?? fetchLatestTag)();
    return compareVersions(installed: installed, latestTag: tag);
  } on SocketException {
    return const UpdateCheckFailed('No connection — check the phone\'s network.');
  } on TimeoutException {
    return const UpdateCheckFailed('GitHub did not answer in time.');
  } on HttpException catch (e) {
    return UpdateCheckFailed(e.message);
  } catch (e) {
    return UpdateCheckFailed('Could not check: $e');
  }
}
