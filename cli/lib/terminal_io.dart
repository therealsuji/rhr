import 'dart:async';
import 'dart:convert';
import 'dart:io';

final terminalInput = stdin.asBroadcastStream();

enum FlutterReloadEvent { reloading, restarting, completed, failed }

/// Preserve Flutter's output while observing its connection-loss verdict.
Future<void> forwardFlutterOutput(
  Stream<List<int>> source,
  IOSink destination,
  void Function() onConnectionLost, {
  void Function(FlutterReloadEvent)? onReloadEvent,
}) async {
  const marker = 'Lost connection to device.';
  final events = RegExp(
    r'Performing hot reload|Performing hot restart|Reloaded \d+ (?:of \d+ )?libraries|Restarted application in|Try again after fixing the above error|Hot reload was rejected',
  );
  var eventBuffer = '';
  var pending = '';
  var reported = false;
  await for (final chunk in source.transform(utf8.decoder)) {
    destination.write(chunk);
    eventBuffer += chunk;
    while (true) {
      final match = events.firstMatch(eventBuffer);
      if (match == null) break;
      final message = match.group(0)!;
      onReloadEvent?.call(switch (message) {
        'Performing hot reload' => FlutterReloadEvent.reloading,
        'Performing hot restart' => FlutterReloadEvent.restarting,
        'Hot reload was rejected' ||
        'Try again after fixing the above error' => FlutterReloadEvent.failed,
        _ => FlutterReloadEvent.completed,
      });
      eventBuffer = eventBuffer.substring(match.end);
    }
    if (eventBuffer.length > 256)
      eventBuffer = eventBuffer.substring(eventBuffer.length - 256);
    pending += chunk;
    if (!reported && pending.contains(marker)) {
      reported = true;
      onConnectionLost();
    }
    if (pending.length >= marker.length) {
      pending = pending.substring(pending.length - marker.length + 1);
    }
  }
}
