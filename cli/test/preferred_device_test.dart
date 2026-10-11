import 'dart:io';

import 'package:rhr_cli/account_auth.dart';
import 'package:test/test.dart';

void main() {
  late Directory project;

  setUp(() {
    project = Directory.systemTemp.createTempSync('rhr_pref');
  });

  tearDown(() {
    if (project.existsSync()) project.deleteSync(recursive: true);
  });

  test('remembers the device a project last used', () async {
    expect(await preferredDevice(project.path), isNull);

    await rememberDevice(project.path, 'phoneReal');
    expect(await preferredDevice(project.path), 'phoneReal');

    // A phone that has left the account is forgotten rather than retried
    // forever, so the next run prompts instead of failing the same way.
    await forgetPreferredDevice(project.path);
    expect(await preferredDevice(project.path), isNull);
  });

  test('is per project, so two projects do not retarget each other', () async {
    final other = Directory.systemTemp.createTempSync('rhr_pref_other');
    addTearDown(() => other.deleteSync(recursive: true));

    await rememberDevice(project.path, 'samsung');
    await rememberDevice(other.path, 'pixel');

    expect(await preferredDevice(project.path), 'samsung');
    expect(await preferredDevice(other.path), 'pixel');
  });

  test('forgetting a project with no preference is not an error', () async {
    await forgetPreferredDevice(project.path);
    expect(await preferredDevice(project.path), isNull);
  });
}
