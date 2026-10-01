import 'dart:io';

import 'package:rhr_cli/flutter_compatibility.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('rhr_fvm_test_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('unpinned project resolves to PATH flutter', () {
    expect(projectPinnedFlutterSdk(tmp.path), isNull);
    expect(projectFlutterExecutable(tmp.path), 'flutter');
  });

  test('fvm symlink pin resolves to the pinned SDK binary', () {
    final sdk = Directory('${tmp.path}/sdks/3.29.0')..createSync(recursive: true);
    Directory('${tmp.path}/project/.fvm').createSync(recursive: true);
    Link('${tmp.path}/project/.fvm/flutter_sdk').createSync(sdk.path);
    final resolved = projectPinnedFlutterSdk('${tmp.path}/project');
    expect(resolved, sdk.resolveSymbolicLinksSync());
    expect(
      projectFlutterExecutable('${tmp.path}/project'),
      '$resolved/bin/flutter',
    );
  });

  test('dangling fvm symlink with no .fvmrc behaves as unpinned', () {
    Directory('${tmp.path}/project/.fvm').createSync(recursive: true);
    Link('${tmp.path}/project/.fvm/flutter_sdk')
        .createSync('${tmp.path}/gone');
    expect(projectPinnedFlutterSdk('${tmp.path}/project'), isNull);
  });

  test('pinned project reads the pinned SDK identity', () {
    final sdk = Directory('${tmp.path}/sdks/pinned/bin/cache')
      ..createSync(recursive: true);
    File('${sdk.path}/flutter.version.json').writeAsStringSync('''
{
  "frameworkVersion": "3.29.0",
  "frameworkRevision": "aaaaaaaaaa",
  "engineRevision": "bbbbbbbbbb",
  "dartSdkVersion": "3.7.0",
  "channel": "stable"
}
''');
    Directory('${tmp.path}/project/.fvm').createSync(recursive: true);
    Link('${tmp.path}/project/.fvm/flutter_sdk')
        .createSync('${tmp.path}/sdks/pinned');
    final identity = readProjectFlutterCompatibility('${tmp.path}/project');
    expect(identity.frameworkVersion, '3.29.0');
    expect(identity.dartSdkVersion, '3.7.0');
  });
}
