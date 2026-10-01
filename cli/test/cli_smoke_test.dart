import 'dart:io';

import 'package:rhr_cli/version.dart';
import 'package:test/test.dart';

void main() {
  test('--version prints the package version', () async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'bin/rhr.dart',
      '--version',
    ]);

    expect(result.exitCode, 0);
    expect('${result.stdout}'.trim(), 'rhr $rhrVersion');
    expect('${result.stderr}', isEmpty);
  });

  test('--help includes the main installed commands', () async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'bin/rhr.dart',
      '--help',
    ]);

    expect(result.exitCode, 0);
    expect('${result.stdout}', contains('rhr run [options]'));
    expect('${result.stdout}', contains('--relay <wss://...>'));
    expect('${result.stdout}', contains('rhr doctor'));
  });

  // version.dart is hand-written while the release name comes from the
  // pubspec, so the two drift silently: beta.5 shipped reporting beta.4.
  test('the version constant matches the pubspec', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final declared = RegExp(r'^version:\s*(\S+)', multiLine: true)
        .firstMatch(pubspec)
        ?.group(1);
    expect(declared, rhrVersion);
  });
}
