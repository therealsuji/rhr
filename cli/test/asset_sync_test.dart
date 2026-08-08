import 'dart:convert';
import 'dart:io';

import 'package:rhr_cli/asset_sync.dart';
import 'package:test/test.dart';

void main() {
  test('preserves encoded filenames and skips unchanged assets', () async {
    final project = await Directory.systemTemp.createTemp('rhr_asset_sync_');
    addTearDown(() => project.delete(recursive: true));

    final asset = File(
      '${project.path}/build/flutter_assets/assets/Sample%20image.png',
    );
    asset.parent.createSync(recursive: true);
    asset.writeAsBytesSync([1, 2, 3, 4]);

    final receivedUris = <String>[];
    final progress = <(int, int)>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((request) async {
      receivedUris.add(
        utf8.decode(base64.decode(request.headers.value('dev_fs_uri_b64')!)),
      );
      await request.drain<void>();
      request.response.write('{}');
      await request.response.close();
    });
    final vmService = Uri.parse('http://127.0.0.1:${server.port}/');

    await syncAssets(
      vmService: vmService,
      project: project.path,
      assetStoreId: 'phone-store-a',
      onProgress: (phase, done, total) {
        if (phase == 'assets') progress.add((done, total));
      },
    );
    expect(receivedUris, ['build/flutter_assets/assets/Sample%2520image.png']);
    expect(progress, [(0, 1), (1, 1)]);

    await syncAssets(
      vmService: vmService,
      project: project.path,
      assetStoreId: 'phone-store-a',
    );
    expect(receivedUris, hasLength(1));

    await syncAssets(
      vmService: vmService,
      project: project.path,
      assetStoreId: 'phone-store-b',
    );
    expect(receivedUris, hasLength(2));

    await syncAssets(
      vmService: vmService,
      project: project.path,
      assetStoreId: 'phone-store-b',
      forceResync: true,
    );
    expect(receivedUris, hasLength(3));

    asset.deleteSync();
    await syncAssets(
      vmService: vmService,
      project: project.path,
      assetStoreId: 'phone-store-b',
    );
    final savedManifest =
        jsonDecode(
              File(
                '${project.path}/.dart_tool/rhr/pushed_assets.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    expect(savedManifest['files'], isEmpty);
  });

  test('encodes each DevFS path segment without encoding separators', () {
    expect(
      devFsAssetUri('assets/a%20b/c d.png'),
      'build/flutter_assets/assets/a%2520b/c%20d.png',
    );
  });

  test('fails incomplete uploads and retries only missing files', () async {
    final project = await Directory.systemTemp.createTemp('rhr_asset_retry_');
    addTearDown(() => project.delete(recursive: true));
    final assets = Directory('${project.path}/build/flutter_assets')
      ..createSync(recursive: true);
    File('${assets.path}/good.txt').writeAsStringSync('good');
    File('${assets.path}/bad.txt').writeAsStringSync('bad');

    var rejectOne = true;
    String? failedUri;
    final received = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((request) async {
      final uri = utf8.decode(
        base64.decode(request.headers.value('dev_fs_uri_b64')!),
      );
      received.add(uri);
      await request.drain<void>();
      if (rejectOne &&
          (uri == failedUri || (failedUri == null && received.length >= 2))) {
        failedUri = uri;
        request.response.write('{"error":"rejected"}');
      } else {
        request.response.write('{}');
      }
      await request.response.close();
    });
    final vmService = Uri.parse('http://127.0.0.1:${server.port}/');

    await expectLater(
      syncAssets(
        vmService: vmService,
        project: project.path,
        assetStoreId: 'phone-store',
      ),
      throwsA(isA<StateError>()),
    );
    rejectOne = false;
    received.clear();
    await syncAssets(
      vmService: vmService,
      project: project.path,
      assetStoreId: 'phone-store',
    );
    expect(received, [failedUri]);
  });
}
