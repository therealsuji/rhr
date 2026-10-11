import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A refusal from the phone: RHR Agent missing or off, a gesture Android
/// cancelled, a field that would not take text. [code] is stable,
/// [message] is written for whoever reads it.
final class DeviceControlException implements Exception {
  DeviceControlException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

/// The developer end of device control: requests to the RHR Agent on the
/// phone, through the session's device endpoint (see session_control.dart).
///
/// Framing, mirrored by the agent's Frames.kt: a 4-byte big-endian length,
/// then that many bytes of UTF-8 JSON. A request is `{"id", "op", ...}`; its
/// answer echoes the id with a `result` object, or an `error` code and a
/// `message`. An answer with id 0 is the player refusing the whole channel.
final class DeviceControl {
  DeviceControl._(this._socket) {
    _socket.done.catchError((_) {});
    _socket.listen(_receive, onDone: _end, onError: (_) => _end());
  }

  final Socket _socket;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  final _buffer = BytesBuilder(copy: false);
  var _nextId = 1;
  DeviceControlException? _closed;

  /// Connects to the session's device endpoint on [port], presenting the
  /// session [token].
  static Future<DeviceControl> connect(int port, String token) async {
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
    socket.write('$token\n');
    return DeviceControl._(socket);
  }

  bool get isClosed => _closed != null;

  /// Sends [op] with [args] and waits for the phone's result.
  Future<Map<String, dynamic>> request(
    String op, [
    Map<String, Object?> args = const {},
    Duration timeout = const Duration(seconds: 30),
  ]) {
    final closed = _closed;
    if (closed != null) return Future.error(closed);
    final id = _nextId++;
    final answer = _pending[id] = Completer();
    final body = utf8.encode(jsonEncode({...args, 'id': id, 'op': op}));
    _socket.add((ByteData(4)..setUint32(0, body.length)).buffer.asUint8List());
    _socket.add(body);
    return answer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        throw DeviceControlException(
          'timeout',
          'The phone did not answer "$op" within ${timeout.inSeconds} s.',
        );
      },
    );
  }

  void _receive(Uint8List data) {
    _buffer.add(data);
    var bytes = _buffer.takeBytes();
    var offset = 0;
    while (bytes.length - offset >= 4) {
      final length = ByteData.sublistView(bytes, offset).getUint32(0);
      if (bytes.length - offset - 4 < length) break;
      final json = utf8.decode(
        Uint8List.sublistView(bytes, offset + 4, offset + 4 + length),
      );
      offset += 4 + length;
      _answer(jsonDecode(json) as Map<String, dynamic>);
    }
    if (offset < bytes.length)
      _buffer.add(Uint8List.sublistView(bytes, offset));
  }

  void _answer(Map<String, dynamic> message) {
    final id = message['id'];
    final error = message['error'];
    if (id == 0) {
      _end(DeviceControlException('$error', '${message['message']}'));
      return;
    }
    final answer = _pending.remove(id);
    if (answer == null) return;
    if (error != null) {
      answer.completeError(
        DeviceControlException('$error', '${message['message']}'),
      );
    } else {
      answer.complete((message['result'] as Map<String, dynamic>?) ?? const {});
    }
  }

  void _end([DeviceControlException? reason]) {
    _closed ??=
        reason ??
        DeviceControlException(
          'closed',
          'The device-control connection closed. The session may have '
              'ended or reconnected.',
        );
    for (final answer in _pending.values) {
      answer.completeError(_closed!);
    }
    _pending.clear();
    _socket.destroy();
  }

  void close() => _end();
}
