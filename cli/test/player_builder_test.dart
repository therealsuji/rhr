import 'dart:convert';
import 'dart:io';

import 'package:rhr_cli/player_builder.dart';
import 'package:test/test.dart';

void main() {
  test(
    'prepares an isolated player with target plugins and permissions',
    () async {
      final root = await Directory.systemTemp.createTemp('rhr_player_builder_');
      addTearDown(() => root.delete(recursive: true));
      final project = Directory('${root.path}/project')..createSync();
      final workspace = Directory('${root.path}/workspace')..createSync();
      final plugin = Directory('${root.path}/camera_android')..createSync();
      File('${plugin.path}/pubspec.yaml').writeAsStringSync('''
name: camera_android
version: 1.2.3
''');
      File('${project.path}/pubspec.yaml').writeAsStringSync('''
name: target
environment:
  sdk: ^3.10.0
''');
      File('${project.path}/.flutter-plugins-dependencies').writeAsStringSync(
        jsonEncode({
          'plugins': {
            'android': [
              {'name': 'camera_android', 'path': plugin.path},
            ],
          },
        }),
      );
      final targetManifest = File(
        '${project.path}/android/app/src/main/AndroidManifest.xml',
      );
      targetManifest.parent.createSync(recursive: true);
      targetManifest.writeAsStringSync('''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
  <uses-permission android:name="android.permission.CAMERA"/>
</manifest>
''');

      File('${workspace.path}/pubspec.yaml').writeAsStringSync('''
name: rhr_player
dependencies:
  flutter:
    sdk: flutter
dev_dependencies:
  flutter_test:
    sdk: flutter
flutter:
  uses-material-design: true
''');
      final playerManifest = File(
        '${workspace.path}/android/app/src/main/AndroidManifest.xml',
      );
      playerManifest.parent.createSync(recursive: true);
      playerManifest.writeAsStringSync('''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
  <uses-permission android:name="android.permission.INTERNET"/>
  <application/>
</manifest>
''');

      final first = prepareProjectPlayer(
        project: project.path,
        workspace: workspace.path,
      );
      expect(first.plugins, {'camera_android': '1.2.3'});
      expect(first.permissions, {'android.permission.CAMERA'});
      expect(first.id, startsWith('android-'));

      final generatedPubspec = File(
        '${workspace.path}/pubspec.yaml',
      ).readAsStringSync();
      expect(generatedPubspec, contains('  camera_android:'));
      expect(generatedPubspec, contains('dependency_overrides:'));
      expect(generatedPubspec, contains('    path: ${plugin.path}'));
      expect(
        playerManifest.readAsStringSync(),
        contains('<uses-permission android:name="android.permission.CAMERA"/>'),
      );
    },
  );
}
