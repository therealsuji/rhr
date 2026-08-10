import 'dart:convert';
import 'dart:io';

import 'package:rhr_cli/restart_tracker.dart';
import 'package:test/test.dart';

void main() {
  test('clears restart progress after the main isolate is replaced', () async {
    var restarted = false;
    var requests = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((request) async {
      requests++;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'jsonrpc': '2.0',
          'result': {
            'type': 'VM',
            'isolates': [
              {
                'type': '@Isolate',
                'id': restarted ? 'isolates/new' : 'isolates/old',
                'name': 'main',
              },
            ],
          },
        }),
      );
      await request.response.close();
    });
    final phases = <String>[];

    await trackHotRestart(
      vmService: Uri.parse('http://127.0.0.1:${server.port}/auth/'),
      trigger: () => restarted = true,
      onProgress: (phase, _, _) => phases.add(phase),
      timeout: const Duration(seconds: 1),
      pollInterval: const Duration(milliseconds: 1),
    );

    expect(requests, greaterThanOrEqualTo(2));
    expect(phases, ['restarting', '']);
  });
}
