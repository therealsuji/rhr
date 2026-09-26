import 'dart:io';
import 'package:rhr_cli/flutter_compatibility.dart';
import 'package:rhr_cli/project_apk.dart';
import 'package:test/test.dart';

void main() {
  test(
    'receipts reject changed native inputs or APK but not Dart edits',
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
}
