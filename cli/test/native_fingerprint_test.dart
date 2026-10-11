import 'dart:convert';
import 'dart:io';

import 'package:rhr_cli/native_fingerprint.dart';
import 'package:test/test.dart';

void main() {
  late Directory project;
  setUp(() => project = Directory.systemTemp.createTempSync('rhr-native-'));
  tearDown(() => project.deleteSync(recursive: true));

  void write(String path, String contents) => File('${project.path}/$path')
    ..createSync(recursive: true)
    ..writeAsStringSync(contents);

  void plugins(List<Map<String, Object>> android, {String date = '1'}) => write(
    '.flutter-plugins-dependencies',
    jsonEncode({
      'plugins': {'android': android},
      'date_created': date,
    }),
  );

  test('build output and pub get timestamps do not count', () async {
    write('pubspec.lock', 'lock');
    write('android/app/src/main/kotlin/Main.kt', 'class Main');
    plugins([]);
    final before = await nativeFingerprint(project.path);

    write('android/app/build/outputs/x.apk', 'apk');
    write('android/.gradle/cache', 'cache');
    write('android/local.properties', 'sdk.dir=/x');
    plugins([], date: '2');
    write('lib/main.dart', 'void main() {}');

    expect(await nativeFingerprint(project.path), before);
  });

  test('native edits count, however deep', () async {
    write('android/app/src/main/kotlin/dev/app/Channel.kt', 'one');
    final before = await nativeFingerprint(project.path);
    write('android/app/src/main/kotlin/dev/app/Channel.kt', 'two');
    expect(await nativeFingerprint(project.path), isNot(before));
  });

  test('a new plugin counts, and so do path plugin sources', () async {
    final local = Directory.systemTemp.createTempSync('rhr-plugin-');
    addTearDown(() => local.deleteSync(recursive: true));
    File('${local.path}/android/src/Plugin.kt')
      ..createSync(recursive: true)
      ..writeAsStringSync('v1');
    write('pubspec.lock', '''
packages:
  local:
    dependency: "direct main"
    description:
      path: "${local.path}"
      relative: false
    source: path
    version: "1.0.0"
''');
    plugins([
      {'name': 'local', 'path': '${local.path}/'},
    ]);
    final before = await nativeFingerprint(project.path);

    File('${local.path}/android/src/Plugin.kt').writeAsStringSync('v2');
    final edited = await nativeFingerprint(project.path);
    expect(edited, isNot(before));

    plugins([
      {'name': 'local', 'path': '${local.path}/'},
      {'name': 'battery_plus', 'path': '/x/.pub-cache/battery_plus-7.0.0/'},
    ]);
    expect(await nativeFingerprint(project.path), isNot(edited));
  });
}
