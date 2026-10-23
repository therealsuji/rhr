import 'dart:io';
import 'package:rhr_cli/flutter_compatibility.dart';
import 'package:rhr_cli/project_apk.dart';
import 'package:test/test.dart';

void main() {
  test(
    'receipts reject changed APK inputs or APK, but not Dart or unrelated edits',
    () async {
      final root = await Directory.systemTemp.createTemp('rhr-receipt-');
      addTearDown(() => root.delete(recursive: true));
      const sdk = FlutterCompatibility(
        frameworkVersion: '3',
        frameworkRevision: 'f',
        engineRevision: 'e',
        dartSdkVersion: 'd',
        channel: 'stable',
      );
      final source = File('${root.path}/main.dart');
      await source.writeAsString('first');
      final apk = File('${root.path}/.dart_tool/rhr/app-debug.apk');
      await apk.parent.create(recursive: true);
      await apk.writeAsString('apk');
      final native = File('${root.path}/android/app/build.gradle');
      await native.parent.create(recursive: true);
      await native.writeAsString('first');
      final identity = await projectBuildIdentity(root.path, sdk);
      await recordProjectApk(root.path, identity.native, identity.dart, apk);
      expect(
        (await cachedProjectApk(root.path, identity.native))?.dart,
        identity.dart,
      );
      final output = File('${root.path}/build/generated');
      await output.parent.create();
      await output.writeAsString('generated');
      expect(await projectBuildIdentity(root.path, sdk), identity);

      // Dart source reaches the app by hot restart: the APK stays valid,
      // and the caller learns its Dart is older than the project's.
      await source.writeAsString('other');
      final edited = await projectBuildIdentity(root.path, sdk);
      expect(edited.native, identity.native);
      expect(edited.dart, isNot(identity.dart));
      expect(await cachedProjectApk(root.path, edited.native), isNotNull);

      // Files that never reach the APK leave it valid; a declared asset
      // does not.
      await File(
        '${root.path}/pubspec.yaml',
      ).writeAsString('name: app\nflutter:\n  assets:\n    - images/\n');
      final image = File('${root.path}/images/logo.png');
      await image.parent.create();
      await image.writeAsString('first');
      final withAssets = await projectBuildIdentity(root.path, sdk);
      for (final path in ['design/mock.fig', 'README.md', '.rhr-device']) {
        final unrelated = File('${root.path}/$path');
        await unrelated.parent.create(recursive: true);
        await unrelated.writeAsString('anything');
      }
      expect(
        (await projectBuildIdentity(root.path, sdk)).native,
        withAssets.native,
      );
      await image.writeAsString('other');
      expect(
        (await projectBuildIdentity(root.path, sdk)).native,
        isNot(withAssets.native),
      );

      await native.writeAsString('other');
      expect(
        await cachedProjectApk(
          root.path,
          (await projectBuildIdentity(root.path, sdk)).native,
        ),
        isNull,
      );
      await apk.writeAsString('bad');
      expect(await cachedProjectApk(root.path, identity.native), isNull);
    },
  );

  test(
    'the debug key is found where Gradle looks, and changes the digest',
    () async {
      final home = await Directory.systemTemp.createTemp('rhr-key-');
      addTearDown(() => home.delete(recursive: true));
      expect(
        defaultDebugKeystore({'HOME': '/h'}).path,
        '/h/.android/debug.keystore',
      );
      expect(
        defaultDebugKeystore({'HOME': '/h', 'ANDROID_SDK_HOME': '/s'}).path,
        '/s/.android/debug.keystore',
      );
      expect(
        defaultDebugKeystore({
          'HOME': '/h',
          'ANDROID_SDK_HOME': '/s',
          'ANDROID_USER_HOME': '/u',
        }).path,
        '/u/debug.keystore',
      );

      final env = {'ANDROID_USER_HOME': home.path};
      expect(await debugKeystoreDigest(env), 'none');
      final keystore = File('${home.path}/debug.keystore');
      await keystore.writeAsString('one key');
      final first = await debugKeystoreDigest(env);
      await keystore.writeAsString('another key');
      expect(await debugKeystoreDigest(env), isNot(first));
    },
  );

  test('reads the certificate digest the way apksigner prints it', () {
    expect(
      keytoolSha256(
        '\t SHA1: 11:01:78:2B\n'
        '\t SHA256: 19:8F:CD:3A:6C:BD\n'
        'Signature algorithm name: SHA256withRSA\n',
      ),
      '198fcd3a6cbd',
    );
    expect(keytoolSha256('keytool error: wrong password'), isNull);
  });

  test('lists each debug keystore on the machine once', () async {
    final home = await Directory.systemTemp.createTemp('rhr-keys-');
    addTearDown(() => home.delete(recursive: true));
    for (final dir in ['.android', '.config/.android']) {
      await File('${home.path}/$dir/debug.keystore').create(recursive: true);
    }
    final env = {
      'HOME': home.path,
      'ANDROID_USER_HOME': '${home.path}/.config/.android',
    };
    expect(debugKeystoreCandidates(env).map((file) => file.path), [
      '${home.path}/.config/.android/debug.keystore',
      '${home.path}/.android/debug.keystore',
    ]);
  });

  test('a pinned key reaches Gradle only while its keystore exists', () async {
    final root = await Directory.systemTemp.createTemp('rhr-pin-');
    addTearDown(() => root.delete(recursive: true));
    final userHome = Directory('${root.path}/keys')..createSync();
    expect(await debugSigningEnvironment(root.path), isEmpty);

    await pinDebugSigning(root.path, userHome);
    expect(await debugSigningEnvironment(root.path), isEmpty);

    File('${userHome.path}/debug.keystore').writeAsStringSync('key');
    expect(await debugSigningEnvironment(root.path), {
      'ANDROID_USER_HOME': userHome.path,
    });
  });
}
