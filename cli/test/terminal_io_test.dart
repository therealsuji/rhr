import 'dart:convert';
import 'dart:io';

import 'package:rhr_cli/terminal_io.dart';
import 'package:test/test.dart';

void main() {
  test(
    'detects connection loss across chunks while preserving output',
    () async {
      final dir = await Directory.systemTemp.createTemp('rhr-output-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/output');
      final sink = file.openWrite();
      var losses = 0;
      final chunks = ['Reloading…\nLost con', 'nection to device.\n'];
      await forwardFlutterOutput(
        Stream.fromIterable(chunks.map(utf8.encode)),
        sink,
        () => losses++,
      );
      await sink.close();
      expect(losses, 1);
      expect(await file.readAsString(), chunks.join());
    },
  );

  test('normal Flutter quit does not request reconnection', () async {
    final dir = await Directory.systemTemp.createTemp('rhr-output-');
    addTearDown(() => dir.delete(recursive: true));
    final sink = File('${dir.path}/output').openWrite();
    var losses = 0;
    await forwardFlutterOutput(
      Stream.value(utf8.encode('Application finished.\n')),
      sink,
      () => losses++,
    );
    await sink.close();
    expect(losses, 0);
  });
  test(
    'reports reload, restart, rejection and retry across output chunks',
    () async {
      final dir = await Directory.systemTemp.createTemp('rhr-events-');
      addTearDown(() => dir.delete(recursive: true));
      final sink = File('${dir.path}/output').openWrite();
      final events = <FlutterReloadEvent>[];
      const text =
          'Performing hot reload... Reloaded 1 of 753 libraries in 717ms.\n'
          'Performing hot restart... Restarted application in 12,000ms.\n'
          'Performing hot reload... Try again after fixing the above error(s).\n'
          'Performing hot reload... Reloaded 0 libraries in 200ms.';
      await forwardFlutterOutput(
        Stream.fromIterable(text.split('').map(utf8.encode)),
        sink,
        () {},
        onReloadEvent: events.add,
      );
      await sink.close();
      expect(events, [
        FlutterReloadEvent.reloading,
        FlutterReloadEvent.completed,
        FlutterReloadEvent.restarting,
        FlutterReloadEvent.completed,
        FlutterReloadEvent.reloading,
        FlutterReloadEvent.failed,
        FlutterReloadEvent.reloading,
        FlutterReloadEvent.completed,
      ]);
    },
  );
}
