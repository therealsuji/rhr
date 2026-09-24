import 'dart:convert';
import 'dart:io';

/// Checks the root library, since replacing an isolate alone can restart the lobby.
Future<bool> isProjectRunning(Uri vmService, String project) async {
  final root = Directory(project).resolveSymbolicLinksSync();
  final config = File('$root/.dart_tool/package_config.json');
  final packages =
      (jsonDecode(await config.readAsString()) as Map)['packages'] as List;
  final package =
      packages.cast<Map>().singleWhere((entry) {
            final directory = Directory.fromUri(
              config.uri.resolve(entry['rootUri'] as String),
            );
            return directory.resolveSymbolicLinksSync() == root;
          })['name']
          as String;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  Future<Map> rpc(String method, [Map<String, String>? params]) async {
    final request = await client.getUrl(
      vmService.resolve(method).replace(queryParameters: params),
    );
    final response = await request.close();
    final decoded =
        jsonDecode(await response.transform(utf8.decoder).join()) as Map;
    if (decoded['result'] is! Map)
      throw StateError('VM service failed to answer $method.');
    return decoded['result'] as Map;
  }

  try {
    return await (() async {
      final vm = await rpc('getVM');
      for (final isolate in (vm['isolates'] as List).cast<Map>()) {
        if (isolate['name'] != 'main') continue;
        final detail = await rpc('getIsolate', {
          'isolateId': isolate['id'] as String,
        });
        final library = detail['rootLib'];
        final uri = library is Map ? library['uri'] : null;
        return uri == 'package:$package/main.dart' ||
            uri == Uri.file('$root/lib/main.dart').toString();
      }
      return false;
    })().timeout(const Duration(seconds: 15));
  } finally {
    client.close(force: true);
  }
}
