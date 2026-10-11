import 'dart:convert';
import 'dart:io';
import 'package:rhr_cli/running_project.dart';
import 'package:test/test.dart';

void main() {
  test('a live lobby isolate is not the requested project', () async {
    final project = await Directory.systemTemp.createTemp('rhr-runtime-');
    addTearDown(() => project.delete(recursive: true));
    final config = File('${project.path}/.dart_tool/package_config.json');
    await config.parent.create();
    await config.writeAsString(
      jsonEncode({
        'packages': [
          {'name': 'guest', 'rootUri': '../'},
        ],
      }),
    );
    var root = 'package:rhr_player/main.dart';
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((request) async {
      request.response.write(
        jsonEncode({
          'result': request.uri.path.endsWith('getVM')
              ? {
                  'isolates': [
                    {'name': 'main', 'id': 'isolates/1'},
                  ],
                }
              : {
                  'rootLib': {'uri': root},
                },
        }),
      );
      await request.response.close();
    });
    final vm = Uri.parse('http://127.0.0.1:${server.port}/auth/');
    expect(await isProjectRunning(vm, project.path), isFalse);
    root = 'package:guest/main.dart';
    expect(await isProjectRunning(vm, project.path), isTrue);
  });
}
