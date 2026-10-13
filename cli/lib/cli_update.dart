import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:pub_semver/pub_semver.dart';

import 'version.dart';

const cliRepository = 'https://github.com/therealsuji/rhr.git';
const _api = 'https://api.github.com/repos/therealsuji/rhr';
final _releasesUrl = Uri.parse('$_api/releases?per_page=100');

/// The public key release tags are signed with (`git tag -s`, SSH format).
///
/// A tag is only a name: anyone who can push to the repository, or holds a
/// stolen token, can move it. `rhr update` installs a release only when its
/// tag carries a signature from this key, and then installs the exact commit
/// the signed tag names.
const releaseSigningKey =
    'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIpgv+yMevOfNzmnHxjkZNL621hz1OUHre4SuXcMMZ/b';

/// A release that cannot be shown to come from the RHR release key.
final class UntrustedRelease implements Exception {
  const UntrustedRelease(this.message);
  final String message;

  @override
  String toString() => message;
}

final class CliRelease {
  const CliRelease(this.tag, this.version);
  final String tag;
  final Version version;
}

CliRelease newestCliRelease(Object? data) {
  if (data is! List)
    throw const FormatException('Invalid GitHub release list.');
  CliRelease? newest;
  for (final item in data) {
    if (item is! Map || item['draft'] != false) continue;
    final tag = item['tag_name'];
    if (tag is! String ||
        !RegExp(
          r'^v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$',
        ).hasMatch(tag)) {
      continue;
    }
    Version version;
    try {
      version = Version.parse(tag.substring(1));
    } on FormatException {
      continue;
    }
    if (newest == null || version > newest.version) {
      newest = CliRelease(tag, version);
    }
  }
  if (newest == null) throw StateError('No published RHR releases were found.');
  return newest;
}

Future<CliRelease> fetchCliRelease({Uri? endpoint}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    return await (() async {
      final request = await client.getUrl(endpoint ?? _releasesUrl);
      request.headers.set(HttpHeaders.userAgentHeader, 'rhr-cli/$rhrVersion');
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/vnd.github+json',
      );
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'GitHub returned HTTP ${response.statusCode}. Retry later.',
        );
      }
      return newestCliRelease(
        jsonDecode(await response.transform(utf8.decoder).join()),
      );
    })().timeout(const Duration(seconds: 20));
  } finally {
    client.close(force: true);
  }
}

/// The commit [tag] names, once its signature from [signingKey] checks out.
///
/// Reads the tag object from GitHub, but trusts none of GitHub's answer: the
/// signed payload itself must name [tag] and a commit, and `ssh-keygen`
/// verifies the signature over it.
Future<String> verifiedReleaseCommit(
  String tag, {
  Future<Object?> Function(Uri url)? getJson,
  String signingKey = releaseSigningKey,
}) async {
  final get = getJson ?? _getJson;
  final ref = await get(Uri.parse('$_api/git/ref/tags/$tag'));
  final object = ref is Map ? ref['object'] : null;
  if (object is! Map || object['type'] != 'tag' || object['sha'] is! String) {
    throw UntrustedRelease('$tag is not a signed release tag.');
  }
  final tagObject = await get(Uri.parse('$_api/git/tags/${object['sha']}'));
  final verification = tagObject is Map ? tagObject['verification'] : null;
  final payload = verification is Map ? verification['payload'] : null;
  final signature = verification is Map ? verification['signature'] : null;
  if (payload is! String || signature is! String) {
    throw UntrustedRelease('$tag carries no signature.');
  }
  final commit = signedTagCommit(payload, tag);
  await verifyReleaseSignature(payload, signature, signingKey: signingKey);
  return commit;
}

/// The commit a tag object's [payload] names, when it is the tag [tag].
String signedTagCommit(String payload, String tag) {
  final header = <String, String>{};
  for (final line in payload.split('\n\n').first.split('\n')) {
    final space = line.indexOf(' ');
    if (space > 0) header[line.substring(0, space)] = line.substring(space + 1);
  }
  final commit = header['object'];
  if (header['type'] != 'commit' ||
      header['tag'] != tag ||
      commit == null ||
      !RegExp(r'^[0-9a-f]{40}$').hasMatch(commit)) {
    throw UntrustedRelease('The signed tag does not name $tag and a commit.');
  }
  return commit;
}

/// Checks [signature] over [payload] with `ssh-keygen -Y verify`, the way
/// `git verify-tag` checks SSH-signed tags.
Future<void> verifyReleaseSignature(
  String payload,
  String signature, {
  String signingKey = releaseSigningKey,
}) async {
  final dir = Directory.systemTemp.createTempSync('rhr-update-');
  try {
    final allowed = File('${dir.path}/allowed_signers')
      ..writeAsStringSync('rhr-release namespaces="git" $signingKey\n');
    final signatureFile = File('${dir.path}/tag.sig')
      ..writeAsStringSync(signature);
    final Process process;
    try {
      process = await Process.start('ssh-keygen', [
        '-Y',
        'verify',
        '-f',
        allowed.path,
        '-I',
        'rhr-release',
        '-n',
        'git',
        '-s',
        signatureFile.path,
      ]);
    } on ProcessException {
      throw const UntrustedRelease(
        'ssh-keygen (OpenSSH) is needed to verify the release. Install it and retry.',
      );
    }
    process.stdin.write(payload);
    await process.stdin.close();
    final output = process.stdout.drain<void>();
    final errors = process.stderr.drain<void>();
    final code = await process.exitCode;
    await Future.wait([output, errors]);
    if (code != 0) {
      throw const UntrustedRelease(
        'The release tag is not signed by the RHR release key. Not installing it.',
      );
    }
  } finally {
    dir.deleteSync(recursive: true);
  }
}

Future<Object?> _getJson(Uri url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await client.getUrl(url);
    request.headers.set(HttpHeaders.userAgentHeader, 'rhr-cli/$rhrVersion');
    request.headers.set(
      HttpHeaders.acceptHeader,
      'application/vnd.github+json',
    );
    final response = await request.close().timeout(const Duration(seconds: 20));
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'GitHub returned HTTP ${response.statusCode}. Retry later.',
      );
    }
    return jsonDecode(body);
  } finally {
    client.close(force: true);
  }
}

/// Installs the CLI at [commit], the commit a verified release tag names.
Future<int> activateCliRelease(String commit) async {
  final executable = File(Platform.resolvedExecutable).uri.pathSegments.last;
  final dart = executable == 'dart' || executable == 'dart.exe'
      ? Platform.resolvedExecutable
      : 'dart';
  final process = await Process.start(dart, [
    'pub',
    'global',
    'activate',
    '--source',
    'git',
    cliRepository,
    '--git-path',
    'cli',
    '--git-ref',
    commit,
  ], mode: ProcessStartMode.inheritStdio);
  return process.exitCode;
}

Future<int> runCliUpdate(
  List<String> args, {
  String currentVersion = rhrVersion,
  Future<CliRelease> Function()? fetchRelease,
  Future<String> Function(String tag)? verify,
  Future<int> Function(String commit)? activate,
  void Function(String)? output,
}) async {
  final write = output ?? stdout.writeln;
  if (args.isNotEmpty && (args.length != 1 || args.single != '--check')) {
    write('Usage: rhr update [--check]');
    return 64;
  }
  try {
    final release = await (fetchRelease ?? fetchCliRelease)();
    final current = Version.parse(currentVersion);
    write('[rhr] Current: $current. Latest published: ${release.version}.');
    if (release.version <= current) {
      write(
        release.version == current
            ? '[rhr] You are up to date.'
            : '[rhr] This CLI is newer than the published release. Keeping it.',
      );
      return 0;
    }
    if (args.contains('--check')) {
      write('[rhr] Update available. Run `rhr update` to install it.');
      return 0;
    }
    final commit = await (verify ?? verifiedReleaseCommit)(release.tag);
    write(
      '[rhr] ${release.tag} is signed by the RHR release key '
      '(commit ${commit.substring(0, 12)}).',
    );
    write(
      '[rhr] Installing ${release.tag} into the Dart global package cache.',
    );
    final result = await (activate ?? activateCliRelease)(commit);
    if (result != 0) {
      write(
        '[rhr] Update failed. Check the Dart output above and retry `rhr update`.',
      );
      return result;
    }
    write(
      '[rhr] Installed ${release.version}. The next global `rhr` command uses it.',
    );
    write(
      '[rhr] Run `rhr --version` to verify your PATH selects the updated CLI.',
    );
    return 0;
  } on UntrustedRelease catch (error) {
    write('[rhr] $error');
  } on TimeoutException {
    write('[rhr] Update check timed out. Check your connection and retry.');
  } on SocketException {
    write('[rhr] Could not reach GitHub. Check your connection and retry.');
  } on ProcessException catch (error) {
    write(
      '[rhr] Could not start Dart: ${error.message}. Install Dart and Git, then retry.',
    );
  } catch (error) {
    write('[rhr] Could not update the CLI: $error');
  }
  return 1;
}
