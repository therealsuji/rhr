import 'dart:typed_data';

import 'package:rhr_bridge/tunnel.dart';
import 'package:test/test.dart';

void main() {
  test('encodes and decodes a multiplexed frame', () {
    final frame = encodeFrame(opData, 0x01020304, [5, 6, 7]);
    final decoded = decodeFrame(frame);

    expect(decoded.op, opData);
    expect(decoded.channel, 0x01020304);
    expect(decoded.payload, [5, 6, 7]);
  });

  test('rejects frames without the five-byte header', () {
    expect(() => decodeFrame([opData, 0, 0, 0]), throwsFormatException);
  });

  test('encodes and decodes acknowledgement counts', () {
    final ack = encodeAck(42, 0x01020304);
    expect(ack.length, 9);
    expect(ack[0], opAck);
    expect(decodeAckCount(Uint8List.sublistView(ack, 5)), 0x01020304);
  });

  test('rejects truncated acknowledgement payloads', () {
    expect(() => decodeAckCount(Uint8List(3)), throwsFormatException);
  });

  test('flow control pauses at the window and resumes below half', () {
    final flow = FlowControl();
    var resumed = 0;

    expect(flow.sent(7, windowBytes - 1), isFalse);
    flow.onWindowOpen(7, () => resumed++);
    expect(flow.sent(7, 1), isTrue);
    flow.acked(7, windowBytes ~/ 2);
    expect(resumed, 0);
    flow.acked(7, 1);
    expect(resumed, 1);
  });

  test('flow control clamps over-acknowledgements and clears channels', () {
    final flow = FlowControl();
    var resumed = 0;
    flow.sent(3, 10);
    flow.onWindowOpen(3, () => resumed++);
    flow.acked(3, 100);
    expect(resumed, 1);

    flow.sent(4, windowBytes);
    flow.onWindowOpen(4, () => resumed++);
    flow.clear();
    flow.acked(4, 1);
    expect(resumed, 1);
  });
}
