import 'dart:async';
import 'dart:convert';
import 'dart:io';

typedef RestartProgress = void Function(String phase, int done, int total);

Future<void> trackHotRestart({
  required Uri vmService,
  required FutureOr<void> Function() trigger,
  required RestartProgress onProgress,
  // A restart pushes the whole kernel, and the engine only reports the new
  // main isolate once it has taken it. On a large project over a slow link
  // that runs past a minute — a measured run took 97s and succeeded, after
  // this watchdog had already declared it lost. Failing a restart that is
  // still working costs the developer the whole session.
  Duration timeout = const Duration(minutes: 3),
  Duration pollInterval = const Duration(milliseconds: 250),
}) async {
  final deadline = DateTime.now().add(timeout);
  String? previousIsolate;
  while (previousIsolate == null && DateTime.now().isBefore(deadline)) {
    previousIsolate = await _tryMainIsolateId(vmService);
    if (previousIsolate == null) await Future<void>.delayed(pollInterval);
  }
  if (previousIsolate == null) {
    throw TimeoutException(
      'Could not identify the main isolate before hot restart.',
      timeout,
    );
  }

  onProgress('restarting', 0, 0);
  await trigger();

  while (DateTime.now().isBefore(deadline)) {
    final currentIsolate = await _tryMainIsolateId(vmService);
    if (currentIsolate != null && currentIsolate != previousIsolate) {
      onProgress('', 0, 0);
      return;
    }
    await Future<void>.delayed(pollInterval);
  }
  throw TimeoutException(
    'Hot restart did not replace the main isolate.',
    timeout,
  );
}

Future<String?> _tryMainIsolateId(Uri vmService) async {
  final client = HttpClient();
  client.connectionTimeout = const Duration(seconds: 2);
  try {
    final request = await client.getUrl(vmService.resolve('getVM'));
    final response = await request.close().timeout(const Duration(seconds: 2));
    if (response.statusCode != HttpStatus.ok) return null;
    final body = await response.transform(utf8.decoder).join();
    final decoded = jsonDecode(body) as Map<String, dynamic>;
    final result = decoded['result'];
    if (result is! Map<String, dynamic>) return null;
    final isolates = result['isolates'];
    if (isolates is! List) return null;
    for (final isolate in isolates.whereType<Map<String, dynamic>>()) {
      if (isolate['name'] == 'main') {
        final id = isolate['id'];
        if (id is String) return id;
      }
    }
    return null;
  } on Exception {
    // The VM service can briefly refuse connections while the isolate is being
    // replaced. That is an expected polling state, not a failed restart.
    return null;
  } finally {
    client.close(force: true);
  }
}
