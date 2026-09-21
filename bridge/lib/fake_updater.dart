// A phone's update behaviour, minus the phone.
//
// The real device end of an update is `RhrPlayerUpdater` in the player's
// Kotlin: it writes the stream to disk, gunzips it if it asked for gzip,
// checks the size and SHA-256, and hands the file to PackageInstaller. Only
// that last step needs Android. This does everything up to it and then
// reports the terminal state a phone would report, which is enough to run
// the CLI's entire update path — the phases, the flow-control window, the
// gzip negotiation, every terminal message — with nothing plugged in.
//
// It is deliberately strict about verification. A stand-in that accepted
// anything would let a corrupted transfer pass CI and fail on hardware,
// which is the one thing it exists to prevent.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'update_handler.dart';

/// What the fake device should do once a transfer has verified.
enum FakeInstallOutcome {
  /// Report "committed": the installer took it, as a silent self-update does.
  committed,

  /// Report "pending_user", then "installed" after a beat — Android showing
  /// its confirmation sheet and the tester tapping through it.
  pendingUser,

  /// Report "installed" directly: a foreign package that needed no sheet.
  installed,

  /// Report "failure" instead. Exercises the CLI's update_failed path.
  fail,
}

/// The device half of one update transfer.
class FakeUpdater implements RhrUpdateHandler {
  FakeUpdater({
    required this.sendText,
    required this.outcome,
    required this.acceptGzip,
    this.confirmDelay = const Duration(milliseconds: 250),
    this.onEvent,
  });

  final void Function(String message) sendText;
  final FakeInstallOutcome outcome;

  /// Whether to accept the dev's gzip offer. False exercises the raw path
  /// and the negotiation's "a device that chooses nothing gets the stream
  /// exactly as before" branch.
  final bool acceptGzip;

  /// How long Android's confirmation sheet "stays up" for
  /// [FakeInstallOutcome.pendingUser].
  final Duration confirmDelay;

  /// Called for each step, so a test can assert the sequence.
  final void Function(String event)? onEvent;

  int _transferId = 0;
  int _expectedSize = 0;
  String _expectedSha = '';
  bool _gzip = false;
  bool _finished = false;
  bool _commitRequested = false;

  /// The decoded payload. Held in memory on purpose: it is bounded by the
  /// APK size, and a test that wants to check the bytes should not have to
  /// go looking on disk for them.
  final _decoded = BytesBuilder(copy: false);

  /// Raw wire bytes, before any gunzip. Counted separately because the
  /// bar's honesty depends on which of the two the dev is measuring.
  int _wireBytes = 0;

  /// Gunzip is a stream transform, so the compressed frames are fed through
  /// a sink rather than decoded one frame at a time.
  StreamController<List<int>>? _inflateInput;
  Future<void>? _inflateDone;

  int get wireBytes => _wireBytes;

  /// How many bytes the payload came to once decoded. Recorded when the
  /// transfer finishes, because verifying it drains the buffer.
  int get decodedBytes => _finished ? _verifiedBytes : _decoded.length;
  int _verifiedBytes = 0;

  @override
  void handleBegin(Map<String, dynamic> message) {
    // A handler outlives its transfer: the bridge builds one per session and
    // a session can carry several updates — a player update, then the
    // project's own APK. Without this reset the second transfer inherited
    // `_finished` from the first, handleData discarded every byte it was
    // given, and the commit waited for a stream that was being thrown away.
    _finished = false;
    _commitRequested = false;
    _wireBytes = 0;
    _verifiedBytes = 0;
    _decoded.clear();
    _inflateInput = null;
    _inflateDone = null;

    _transferId = message['id'] as int? ?? 0;
    _expectedSize = message['size'] as int? ?? 0;
    _expectedSha = message['sha256'] as String? ?? '';
    final offered =
        (message['encodings'] as List?)?.cast<String>() ?? const <String>[];
    _gzip = acceptGzip && offered.contains('gzip');
    _onEvent('begin id=$_transferId size=$_expectedSize gzip=$_gzip');

    if (_gzip) {
      final input = _inflateInput = StreamController<List<int>>();
      _inflateDone = input.stream
          .transform(gzip.decoder)
          .forEach(_decoded.add)
          .catchError((Object error) {
            _fail('gunzip failed: $error');
          });
    }

    _status('ready', extra: {if (_gzip) 'encoding': 'gzip'});
  }

  @override
  void handleData(Uint8List payload) {
    if (_finished) return;
    _wireBytes += payload.length;
    if (_gzip) {
      _inflateInput?.add(payload);
    } else {
      _decoded.add(payload);
    }
    // The dev may commit before the tail arrives on the direct path, so the
    // completion check lives here too, not only in handleCommit.
    if (_commitRequested) unawaited(_finishIfComplete());
  }

  @override
  void handleCommit(Map<String, dynamic> message) {
    if (_finished) return;
    _commitRequested = true;
    _onEvent('commit');
    unawaited(_finishIfComplete());
  }

  /// Verifies and installs once every byte has arrived.
  ///
  /// With gzip the arrival test has to be on the DECODED length: the wire
  /// length is whatever the compressor produced and says nothing about
  /// whether the stream is complete.
  Future<void> _finishIfComplete() async {
    if (_finished) return;
    if (_gzip) {
      // Closing the sink flushes the inflater's tail; only then is the
      // decoded length authoritative.
      await _inflateInput?.close();
      await _inflateDone;
      _inflateInput = null;
    }
    if (_decoded.length < _expectedSize) {
      if (!_gzip) return; // more frames still coming
      _fail('transfer incomplete: ${_decoded.length} of $_expectedSize bytes');
      return;
    }
    _finished = true;

    final bytes = _decoded.takeBytes();
    _verifiedBytes = bytes.length;
    if (bytes.length != _expectedSize) {
      _fail('size mismatch: got ${bytes.length}, expected $_expectedSize');
      return;
    }
    final actual = sha256.convert(bytes).toString();
    if (actual != _expectedSha) {
      _fail('sha256 mismatch: transfer corrupted');
      return;
    }
    _onEvent('verified wire=$_wireBytes decoded=${bytes.length}');

    switch (outcome) {
      case FakeInstallOutcome.committed:
        _status('committed');
      case FakeInstallOutcome.installed:
        _status('installed');
      case FakeInstallOutcome.pendingUser:
        _status('pending_user');
        await Future<void>.delayed(confirmDelay);
        _status('installed');
      case FakeInstallOutcome.fail:
        _fail('PackageInstaller rejected the update (simulated)');
    }
  }

  void _fail(String message) {
    _finished = true;
    _onEvent('failure: $message');
    _status('failure', extra: {'message': message});
  }

  void _status(String state, {Map<String, Object?> extra = const {}}) {
    _onEvent('status $state');
    sendText(
      jsonEncode({
        't': 'update_status',
        'id': _transferId,
        'state': state,
        ...extra,
      }),
    );
  }

  void _onEvent(String event) => onEvent?.call(event);
}
