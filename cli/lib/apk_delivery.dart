// Cable-free APK install: stream an APK to the rhr player over a relay and
// let the tester confirm the system install sheet.
//
// The player installs a foreign package here rather than updating itself, so
// its own process survives the install and reports the sheet's outcome back.
// That makes this the delivery half of any "we can give you a build that
// works" offer — the compatibility gate decides an APK is needed, this puts
// it on the phone without a cable.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:rhr_bridge/session_code.dart';
import 'package:rhr_bridge/tunnel.dart';

import 'direct_session_transport.dart';
import 'player_update.dart';
import 'relay_race.dart';

/// Raised when an APK could not be delivered to the phone.
class DeliveryFailure implements Exception {
  DeliveryFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Streams [apk] to the rhr player over [relay] and waits for the tester to
/// confirm the install sheet. [applicationId] is the package the APK
/// installs as — the player uses it to report the terminal install state.
///
/// Mints its own session code and prints it: delivery is a separate,
/// short-lived session from whatever the developer is otherwise doing.
Future<void> deliverViaRelay({
  required File apk,
  required String applicationId,
  required String relay,
  bool preferDirect = true,
  void Function(String)? onLog,
}) async {
  final void Function(String) log = onLog ?? stderr.writeln;
  final deliveryCode = mintRhrSessionCode();
  log('[rhr] open the rhr player on the phone and enter code: $deliveryCode');
  final relayTransport = await RelayRace.connect(
    relays: [relay],
    code: deliveryCode,
  );
  final SessionTransport transport = preferDirect
      ? DirectSessionTransport(relayTransport)
      : relayTransport;
  try {
    // The transport stream is single-subscription: one listener routes the
    // player hello AND the update statuses/acks for the whole delivery.
    final hello = Completer<void>();
    PlayerUpdateSender? sender;
    var lastPct = -10;
    final sub = transport.stream.listen((msg) {
      if (msg is String) {
        if (!hello.isCompleted && msg.contains('"t":"info"')) {
          hello.complete();
          return;
        }
        sender?.handleMessage(jsonDecode(msg) as Map<String, dynamic>);
      } else {
        final f = decodeFrame(msg as List<int>);
        if (f.op == opAck && PlayerUpdateSender.isUpdateAck(f.channel)) {
          sender?.handleAck(f.channel, decodeAckCount(f.payload));
        }
      }
    }, onError: (Object error, StackTrace stack) {
      if (!hello.isCompleted) {
        hello.completeError(error, stack);
      }
    });
    await hello.future.timeout(
      const Duration(minutes: 5),
      onTimeout: () => throw DeliveryFailure(
        'no player joined the delivery session within 5 minutes',
      ),
    );
    log('[rhr] player connected — streaming '
        '${(apk.lengthSync() / (1024 * 1024)).toStringAsFixed(1)} MB…');
    sender = PlayerUpdateSender(
      transport,
      kind: UpdateKind.app,
      target: applicationId,
    );
    try {
      final outcome = await sender.send(apk, onProgress: (sent, total) {
        final pct = (sent * 100 ~/ total);
        if (pct >= lastPct + 10) {
          lastPct = pct;
          log('[rhr] delivered $pct%');
        }
      });
      log('[rhr] delivery outcome: $outcome — confirm the sheet on the '
          'phone if it is still showing');
    } finally {
      await sub.cancel();
    }
  } on DirectTransportFailure catch (failure) {
    throw DeliveryFailure('direct connection failed: $failure');
  } finally {
    await transport.close();
  }
}
