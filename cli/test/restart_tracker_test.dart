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

  test('ignores a malformed isolate id while polling', () async {
    var request = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((requestObject) async {
      final id = switch (request++) {
        0 => 123,
        1 => 'isolates/old',
        _ => 'isolates/new',
      };
      requestObject.response.headers.contentType = ContentType.json;
      requestObject.response.write(
        jsonEncode({
          'jsonrpc': '2.0',
          'result': {
            'isolates': [
              {'name': 'main', 'id': id},
            ],
          },
        }),
      );
      await requestObject.response.close();
    });

    final phases = <String>[];
    await trackHotRestart(
      vmService: Uri.parse('http://127.0.0.1:${server.port}/auth/'),
      trigger: () {},
      onProgress: (phase, _, _) => phases.add(phase),
      timeout: const Duration(seconds: 1),
      pollInterval: const Duration(milliseconds: 1),
    );

    expect(phases, ['restarting', '']);
    expect(request, greaterThanOrEqualTo(3));
  });
}
