import 'dart:convert';
import 'dart:io';

import 'package:rhr_cli/flutter_compatibility.dart';
import 'package:test/test.dart';

void main() {
  const local = FlutterCompatibility(
    frameworkVersion: '3.44.2',
    frameworkRevision: 'framework-a',
    engineRevision: 'engine-a',
    dartSdkVersion: '3.12.2',
  );

  test('matching identities are compatible', () {
    expect(local.differencesFrom(local), isEmpty);
  });

  test('reports every incompatible runtime field', () {
    const player = FlutterCompatibility(
      frameworkVersion: '3.43.0',
      frameworkRevision: 'framework-b',
      engineRevision: 'engine-b',
      dartSdkVersion: '3.11.0',
    );

    expect(local.differencesFrom(player), [
      'Flutter revision: local framework-a, player framework-b',
      'engine revision: local engine-a, player engine-b',
      'Dart SDK: local 3.12.2, player 3.11.0',
    ]);
  });

  test('player plugin profile may be a compatible superset', () {
    expect(
      androidPluginDifferences(
        required: const {'camera_android': '1.2.3'},
        available: const {
          'camera_android': '1.2.3',
          'shared_preferences_android': '2.0.0',
        },
      ),
      isEmpty,
    );
  });

  test('newer stable plugin versions in the same major are compatible', () {
    expect(
      androidPluginDifferences(
        required: const {'firebase_core': '4.11.0'},
        available: const {'firebase_core': '4.12.1'},
      ),
      isEmpty,
    );
  });

  test('reports missing and version-drifted Android plugins', () {
    expect(
      androidPluginDifferences(
        required: const {
          'camera_android': '1.2.3',
          'package_info_plus': '4.0.0',
        },
        available: const {'camera_android': '2.0.0'},
      ),
      [
        'camera_android: required 1.2.3, player has 2.0.0',
        'package_info_plus: required 4.0.0, missing from player',
      ],
    );
  });

  test('older and pre-1.0 plugin versions remain incompatible', () {
    expect(
      androidPluginDifferences(
        required: const {
          'firebase_core': '4.12.1',
          'experimental_plugin': '0.5.1',
        },
        available: const {
          'firebase_core': '4.11.0',
          'experimental_plugin': '0.5.2',
        },
      ),
      [
        'firebase_core: required 4.12.1, player has 4.11.0',
        'experimental_plugin: required 0.5.1, player has 0.5.2',
      ],
    );
  });

  test('player permissions may be a compatible superset', () {
    expect(
      androidPermissionDifferences(
        required: const {'android.permission.CAMERA'},
        available: const {
          'android.permission.CAMERA',
          'android.permission.INTERNET',
        },
      ),
      isEmpty,
    );
  });

  test(
    'reads app and plugin permissions and reports missing capabilities',
    () async {
      final project = await Directory.systemTemp.createTemp('rhr_permissions_');
      addTearDown(() => project.delete(recursive: true));
      final appManifest = File(
        '${project.path}/android/app/src/main/AndroidManifest.xml',
      );
      appManifest.parent.createSync(recursive: true);
      appManifest.writeAsStringSync(
        '<manifest xmlns:android="http://schemas.android.com/apk/res/android">'
        '<uses-permission android:name="android.permission.CAMERA"/>'
        '</manifest>',
      );
      final plugin = Directory('${project.path}/plugin')..createSync();
      File('${plugin.path}/pubspec.yaml').writeAsStringSync('''
name: scanner
version: 1.0.0
''');
      final pluginManifest = File(
        '${plugin.path}/android/src/main/AndroidManifest.xml',
      );
      pluginManifest.parent.createSync(recursive: true);
      pluginManifest.writeAsStringSync(
        '<manifest xmlns:android="http://schemas.android.com/apk/res/android">'
        '<uses-permission-sdk-23 android:name="android.permission.BLUETOOTH_SCAN"/>'
        '</manifest>',
      );
      File('${project.path}/.flutter-plugins-dependencies').writeAsStringSync(
        jsonEncode({
          'plugins': {
            'android': [
              {'name': 'scanner', 'path': plugin.path},
            ],
          },
        }),
      );

      expect(readAndroidPermissionProfile(project.path), {
        'android.permission.BLUETOOTH_SCAN',
        'android.permission.CAMERA',
      });
      expect(
        androidPermissionDifferences(
          required: readAndroidPermissionProfile(project.path),
          available: const {'android.permission.CAMERA'},
        ),
        ['android.permission.BLUETOOTH_SCAN: required, missing from player'],
      );
    },
  );

  test(
    'allows template activity but reports project-specific Android inputs',
    () async {
      final project = await Directory.systemTemp.createTemp(
        'rhr_native_inputs_',
      );
      addTearDown(() => project.delete(recursive: true));
      final kotlin = File(
        '${project.path}/android/app/src/main/kotlin/example/MainActivity.kt',
      );
      kotlin.parent.createSync(recursive: true);
      kotlin.writeAsStringSync('''
package example
import io.flutter.embedding.android.FlutterActivity
class MainActivity : FlutterActivity()
''');
      File(
        '${kotlin.parent.path}/GeneratedPluginRegistrant.java',
      ).writeAsStringSync('generated by Flutter');
      expect(readUnsupportedAndroidInputs(project.path), isEmpty);

      final custom = File(
        '${project.path}/android/app/src/main/kotlin/example/Payments.kt',
      )..writeAsStringSync('class Payments');
      expect(readUnsupportedAndroidInputs(project.path), [
        '${custom.path.substring(project.path.length + 1)}: custom Android code '
            'or native library is not in the generic player',
      ]);
    },
  );

  test(
    'discovers Android plugins from current package config metadata',
    () async {
      final project = await Directory.systemTemp.createTemp(
        'rhr_package_config_',
      );
      addTearDown(() => project.delete(recursive: true));
      final plugin = Directory('${project.path}/plugin')..createSync();
      File('${plugin.path}/pubspec.yaml').writeAsStringSync('''
name: modern_android
version: 2.3.4
flutter:
  plugin:
    platforms:
      android:
        package: example.modern
        pluginClass: ModernPlugin
''');
      final packageConfig = File(
        '${project.path}/.dart_tool/package_config.json',
      );
      packageConfig.parent.createSync(recursive: true);
      packageConfig.writeAsStringSync(
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {
              'name': 'modern_android',
              'rootUri': plugin.uri.toString(),
              'packageUri': 'lib/',
            },
          ],
        }),
      );

      expect(readAndroidPluginProfile(project.path), {
        'modern_android': '2.3.4',
      });
    },
  );
}
