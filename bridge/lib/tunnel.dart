// Shared tunnel protocol between the device bridge and the dev CLI.
//
// Over the relay WebSocket:
//   - TEXT frames are JSON control messages, e.g. {"t":"info","vm":"<uri>"}.
//   - BINARY frames carry multiplexed TCP streams:
//       [1 byte op][4 bytes channel id, big-endian][payload]
//     op 0 = open channel, 1 = data, 2 = close channel.
//
// The dev CLI opens channels (one per local TCP connection from the Flutter
// tool); the device bridge answers each open with a TCP connection to the
// local VM service.

import 'dart:typed_data';

const opOpen = 0;
const opData = 1;
const opClose = 2;

/// Player update transfer: [op][4B transfer id][APK chunk]. The dev streams a
/// replacement player APK to the device (announced by a {"t":"update_begin"}
/// text message, sealed by {"t":"update_commit"}). Transfer ids set bit 30 so
/// they can never collide with tunnel channel ids (which count up from 1),
/// letting both ends reuse the opAck flow-control machinery unchanged. Bit 31
/// deliberately stays clear: the id also travels through JSON and Kotlin's
/// signed 32-bit ints, where a high-bit id turns negative and breaks matching.
const opUpdateData = 4;
const updateTransferIdBase = 0x40000000;

/// Flow control: receiver acks consumed bytes (payload = 4-byte big-endian
/// count). A sender pauses its TCP source once [windowBytes] are unacked —
/// without this, a fast dev machine pumping into a slow phone builds up
/// megabytes inside the relay, and Durable Objects kill the socket rather
/// than buffer unboundedly.
const opAck = 3;
const windowBytes = 512 * 1024;

/// Largest payload that may ride in one tunnel frame.
///
/// libwebrtc falls back to the 64 KiB default from
/// draft-ietf-mmusic-sdp-sctp-23 when the answer carries no
/// a=max-message-size, and a message over that limit makes it close the data
/// channel itself — after reporting the send as successful, so the sender sees
/// a spontaneous disconnect rather than an error. The 5 bytes are this
/// protocol's own header (op + channel), which count toward the limit.
///
/// The device has capped its reads at this size since the tunnel defects were
/// found (TUNNEL_READ_BYTES in RhrSessionService); the CLI never did, and
/// handed whole dart:io reads to the transport instead.
const maxTunnelPayload = 64 * 1024 - 5;

Uint8List encodeAck(int channel, int bytes) {
  final b = Uint8List(9);
  b[0] = opAck;
  final bd = ByteData.view(b.buffer);
  bd.setUint32(1, channel);
  bd.setUint32(5, bytes);
  return b;
}

int decodeAckCount(Uint8List payload) {
  if (payload.length < 4) {
    throw FormatException('ack payload too short: ${payload.length}');
  }
  return ByteData.view(payload.buffer, payload.offsetInBytes).getUint32(0);
}

/// Per-channel unacked-byte accounting shared by both tunnel ends.
class FlowControl {
  final _unacked = <int, int>{};
  final _paused = <int, void Function()>{};

  /// Record [n] sent bytes; returns true if the channel should pause.
  bool sent(int channel, int n) {
    final u = (_unacked[channel] ?? 0) + n;
    _unacked[channel] = u;
    return u >= windowBytes;
  }

  /// Record acked bytes; runs and clears the channel's resume callback when
  /// the window has drained below half.
  void acked(int channel, int n) {
    final u = (_unacked[channel] ?? 0) - n;
    final remaining = u < 0 ? 0 : u;
    _unacked[channel] = remaining;
    if (remaining < windowBytes ~/ 2) {
      _paused.remove(channel)?.call();
    }
  }

  void onWindowOpen(int channel, void Function() resume) {
    _paused[channel] = resume;
  }

  void forget(int channel) {
    _unacked.remove(channel);
    _paused.remove(channel);
  }

  void clear() {
    _unacked.clear();
    _paused.clear();
  }
}

Uint8List encodeFrame(int op, int channel, [List<int> payload = const []]) {
  final b = Uint8List(5 + payload.length);
  b[0] = op;
  ByteData.view(b.buffer).setUint32(1, channel);
  b.setRange(5, b.length, payload);
  return b;
}

({int op, int channel, Uint8List payload}) decodeFrame(List<int> raw) {
  final b = raw is Uint8List ? raw : Uint8List.fromList(raw);
  if (b.length < 5)
    throw FormatException('tunnel frame too short: ${b.length}');
  return (
    op: b[0],
    channel: ByteData.view(b.buffer, b.offsetInBytes).getUint32(1),
    payload: Uint8List.sublistView(b, 5),
  );
}
