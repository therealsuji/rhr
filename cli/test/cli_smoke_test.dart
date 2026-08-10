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
    expect('${result.stdout}', contains('rhr doctor'));
  });
}
