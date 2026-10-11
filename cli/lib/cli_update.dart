import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:pub_semver/pub_semver.dart';

import 'version.dart';

const cliRepository = 'https://github.com/therealsuji/rhr.git';
final _releasesUrl = Uri.parse(
  'https://api.github.com/repos/therealsuji/rhr/releases?per_page=100',
);

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

Future<int> activateCliRelease(String tag) async {
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
    tag,
  ], mode: ProcessStartMode.inheritStdio);
  return process.exitCode;
}

Future<int> runCliUpdate(
  List<String> args, {
  String currentVersion = rhrVersion,
  Future<CliRelease> Function()? fetchRelease,
  Future<int> Function(String tag)? activate,
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
    write(
      '[rhr] Installing ${release.tag} into the Dart global package cache.',
    );
    final result = await (activate ?? activateCliRelease)(release.tag);
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
