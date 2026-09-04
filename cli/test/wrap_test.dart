// Unit tests for the tier-2 wrap: session-code stability, init-script
// injection content, and gradle-launcher resolution. Everything runs against
// a temp "home" via rhrHomeOverride — the real ~/.rhr is never touched.
import 'dart:io';

import 'package:rhr_cli/flutter_compatibility.dart';
import 'package:rhr_cli/wrap.dart';
import 'package:test/test.dart';

void main() {
  late Directory home;
  late Directory project;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('rhr_wrap_home');
    project = await Directory.systemTemp.createTemp('rhr_wrap_project');
    rhrHomeOverride = home.path;
  });

  tearDown(() {
    rhrHomeOverride = null;
    home.deleteSync(recursive: true);
    project.deleteSync(recursive: true);
  });

  group('resolveSessionCode', () {
    test('mints a code and returns the same one on the next call', () {
      final first = resolveSessionCode(project.path, null);
      expect(first, matches(RegExp(r'^rhr-[a-z2-9]{4}-[a-z2-9]{4}-[a-z2-9]{4}$')));
      expect(resolveSessionCode(project.path, null), first);
      // Persisted under the overridden home, keyed by project path.
      expect(codeStoreFile(project.path).readAsStringSync(), first);
    });

    test('distinct projects get distinct codes', () {
      final other = Directory.systemTemp.createTempSync('rhr_other_project');
      addTearDown(() => other.deleteSync(recursive: true));
      expect(resolveSessionCode(other.path, null),
          isNot(resolveSessionCode(project.path, null)));
    });

    test('an explicit code wins and is persisted', () {
      final code = resolveSessionCode(project.path, 'rhr-abcd-efgh-jkmn');
      expect(code, 'rhr-abcd-efgh-jkmn');
      expect(codeStoreFile(project.path).readAsStringSync(), code);
    });

    test('an invalid explicit code is rejected', () {
      expect(
        () => resolveSessionCode(project.path, 'not-a-code'),
        throwsA(isA<WrapFailure>()),
      );
    });

    test('.rhr.yaml code wins over the persisted one', () {
      resolveSessionCode(project.path, null);
      File('${project.path}/.rhr.yaml')
          .writeAsStringSync('relay: wss://example\n'
              'code: rhr-2345-6789-abcd\n');
      expect(resolveSessionCode(project.path, null), 'rhr-2345-6789-abcd');
    });
  });

  group('writeInitScript', () {
    const identity = FlutterCompatibility(
      frameworkVersion: '3.44.0',
      frameworkRevision: '559ffa3f75e7402d65a8def9c28389a9b2e6fe42',
      engineRevision: '4c525dac5ebe5971c5708ef73558ed8edcf4a362',
      dartSdkVersion: '3.12.0',
      channel: '[user-branch]',
    );

    test('injects config resources, the AAR dependency, and the id suffix',
        () {
      final path = writeInitScript(
        project: project.path,
        relay: 'wss://relay.example',
        code: 'rhr-abcd-efgh-jkmn',
        suffix: '.rhr',
        identity: identity,
        pluginsJson: '{"squawk":"0.1.2"}',
      );
      final script = File(path).readAsStringSync();
      expect(script, contains("resValue 'string', 'rhr_session_code', 'rhr-abcd-efgh-jkmn'"));
      expect(script, contains("resValue 'string', 'rhr_relay_url', 'wss://relay.example'"));
      expect(script, contains("resValue 'string', 'rhr_host', 'app'"));
      expect(script, contains("resValue 'string', 'rhr_prefer_direct', 'true'"));
      expect(script, contains("resValue 'string', 'rhr_framework_revision', '559ffa3f75e7402d65a8def9c28389a9b2e6fe42'"));
      expect(script, contains("resValue 'string', 'rhr_android_plugins_json', '{\"squawk\":\"0.1.2\"}'"));
      expect(script, contains("add 'debugImplementation', 'dev.rhr:bridge-android:"));
      expect(script, contains("applicationIdSuffix = '.rhr'"));
    });

    test('verbatim id mode omits the suffix', () {
      final path = writeInitScript(
        project: project.path,
        relay: 'wss://relay.example',
        code: 'rhr-abcd-efgh-jkmn',
        suffix: '',
        identity: identity,
        pluginsJson: '{}',
        preferDirect: false,
      );
      final script = File(path).readAsStringSync();
      expect(script, isNot(contains('applicationIdSuffix')));
      expect(script, contains("resValue 'string', 'rhr_prefer_direct', 'false'"));
    });
  });

  group('loadDotRhrYaml', () {
    test('parses flat keys, quotes, and comments', () {
      File('${project.path}/.rhr.yaml').writeAsStringSync('# comment\n'
          'relay: wss://private.example\n'
          "code: 'rhr-abcd-efgh-jkmn'\n"
          'direct: true\n'
          'other: ignored\n');
      final cfg = loadDotRhrYaml(project.path);
      expect(cfg, {
        'relay': 'wss://private.example',
        'code': 'rhr-abcd-efgh-jkmn',
        'direct': 'true',
      });
    });

    test('missing file is an empty map', () {
      expect(loadDotRhrYaml(project.path), isEmpty);
    });
  });

  group('resolveGradleLauncher', () {
    test('prefers the project gradlew', () async {
      final android = Directory('${project.path}/android')
        ..createSync(recursive: true);
      File('${android.path}/gradlew').writeAsStringSync('#!/bin/sh\n');
      final launcher = await resolveGradleLauncher(android);
      expect(launcher!.executable, '${android.path}/gradlew');
      expect(launcher.prefix, isEmpty);
    });

    test('falls back to java + the project wrapper jar', () async {
      final android = Directory('${project.path}/android')
        ..createSync(recursive: true);
      final jar = File(
          '${android.path}/gradle/wrapper/gradle-wrapper.jar')
        ..createSync(recursive: true);
      final launcher = await resolveGradleLauncher(android);
      expect(launcher!.executable, 'java');
      expect(launcher.prefix[0], '-cp');
      expect(launcher.prefix[1], jar.path);
      expect(launcher.prefix[2], 'org.gradle.wrapper.GradleWrapperMain');
    });
  });
}
