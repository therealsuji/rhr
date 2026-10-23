import 'direct_session_transport.dart';

/// Retry immediately after a healthy session; pace consecutive failed attempts.
final class ReconnectBackoff {
  int _failures = 0;
  int _noPath = 0;
  bool _wasReady = false;
  DateTime? _busySince;

  /// Consecutive attempts where no direct route opened before RHR says the
  /// two networks cannot connect directly and stops.
  static const noPathLimit = 3;

  /// How long a phone held by another host is waited for: past the relay's
  /// 45 s claim grace for a run that quit, and past the minute of silence
  /// after which it lets go of a host that was killed outright. A host still
  /// using the phone holds it past this.
  static const busyLimit = Duration(minutes: 2);

  void markReady() {
    _failures = 0;
    _noPath = 0;
    _busySince = null;
    _wasReady = true;
  }

  /// Records a failed direct attempt; true once [noPathLimit] in a row found
  /// no direct route. Any other direct failure breaks the run.
  bool directPathImpossible(DirectTransportFailure failure) {
    _noPath = failure.noPath ? _noPath + 1 : 0;
    return _noPath >= noPathLimit;
  }

  /// Records that the phone was held by another host; true once it has been
  /// held for longer than [busyLimit] in a row.
  bool busyTooLong([DateTime? now]) {
    final at = now ?? DateTime.now();
    return at.difference(_busySince ??= at) > busyLimit;
  }

  Duration nextDelay() {
    if (_wasReady) {
      _wasReady = false;
      return Duration.zero;
    }
    return Duration(seconds: (2 * ++_failures).clamp(2, 15));
  }
}
