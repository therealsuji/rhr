import 'dart:io';
import 'package:rhr_cli/flutter_compatibility.dart';
import 'package:rhr_cli/project_apk.dart';
import 'package:test/test.dart';

void main() {
  test(
    'receipts reject changed source or APK but ignore build outputs',
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
      final inputs = await projectBuildIdentity(root.path, sdk);
      await recordProjectApk(root.path, inputs, apk);
      expect(await cachedProjectApk(root.path, inputs), isNotNull);
      final output = File('${root.path}/build/generated');
      await output.parent.create();
      await output.writeAsString('generated');
      expect(await projectBuildIdentity(root.path, sdk), inputs);
      await source.writeAsString('other');
      expect(
        await cachedProjectApk(
          root.path,
          await projectBuildIdentity(root.path, sdk),
        ),
        isNull,
      );
      await apk.writeAsString('bad');
      expect(await cachedProjectApk(root.path, inputs), isNull);
    },
  );
}
