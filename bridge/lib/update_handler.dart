// The device end of the over-the-wire APK update, as an interface.
//
// The bridge itself never installs anything — on a phone the installing is
// PackageInstaller's job and lives in the player's Kotlin
// (`RhrPlayerUpdater`, behind the `RhrUpdateHandler` interface). This is the
// same seam on the Dart side, and it exists for the same reason: the update
// conversation is part of the session protocol, but what you do with the
// bytes at the end of it is not the bridge's business.
//
// Its first implementation is the desktop fake device, which writes the
// payload to a temp file and answers as a phone would. That is what lets the
// CLI's whole update path — the phases, the flow control, the gzip stream,
// the terminal states — run in CI with no phone in the room.

import 'dart:typed_data';

/// Handles the device side of one update transfer.
///
/// Wire protocol, dev → device unless noted (mirrors `player_update.dart`):
///
///   {"t":"update_begin", id, size, sha256, kind, target?}
///   binary opUpdateData frames                  the gzipped payload, flow-controlled
///   {"t":"update_commit", id}                   the stream is complete
///
/// and back, device → dev, as `{"t":"update_status","id":N,"state":…}`:
///
///   "ready"         accepted; chunks may flow
///   "committed"     verified and handed to the installer
///   "pending_user"  the OS is asking the tester to confirm
///   "installed"     confirmed on the device
///   "failure"       with a "message" saying why
///
/// A device that never answers "ready" has no updater; the dev side times
/// out and reports it.
abstract interface class RhrUpdateHandler {
  /// The dev announced a transfer. Answer "ready" to accept it.
  void handleBegin(Map<String, dynamic> message);

  /// One payload frame. Acking is the caller's job — the bridge does it, so
  /// flow control does not depend on an implementation remembering to.
  void handleData(Uint8List payload);

  /// The stream is complete. Frames may still be in flight behind it on the
  /// direct path, so a handler that is short of bytes should wait rather
  /// than fail immediately.
  void handleCommit(Map<String, dynamic> message);
}

/// Builds a handler for a live session, given the socket's send functions.
///
/// Called lazily, on the first update message: a session that never updates
/// never constructs one.
typedef RhrUpdateHandlerFactory =
    RhrUpdateHandler Function({
      required void Function(String message) sendText,
      required void Function(Uint8List frame) sendBinary,
    });
