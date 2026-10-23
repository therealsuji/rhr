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

  test('moves an older project-root preference under .dart_tool', () async {
    File('${project.path}/.rhr-device').writeAsStringSync('phoneOld\n');
    expect(await preferredDevice(project.path), 'phoneOld');
    expect(File('${project.path}/.rhr-device').existsSync(), isFalse);
    expect(await preferredDevice(project.path), 'phoneOld');
  });

  test('a device is named by its id, its label, or the start of its id', () {
    const devices = [
      (id: 'W5KSE8zQ', label: 'samsung SM-S918B'),
      (id: 'Nm5rLalf', label: 'samsung SM-A566B'),
      (id: 'Cf3iJ1bm', label: 'samsung SM-A566B'),
    ];
    expect(matchDevices(devices, 'Nm5rLalf').single.id, 'Nm5rLalf');
    expect(matchDevices(devices, 'Samsung sm-s918b').single.id, 'W5KSE8zQ');
    expect(matchDevices(devices, 'Cf3').single.id, 'Cf3iJ1bm');
    // Two phones of one model share a label; that is ambiguous, not a pick.
    expect(matchDevices(devices, 'samsung SM-A566B'), hasLength(2));
    expect(matchDevices(devices, 'pixel'), isEmpty);
  });
}
