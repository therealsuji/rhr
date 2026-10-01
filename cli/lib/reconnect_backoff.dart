import 'direct_session_transport.dart';

/// Retry immediately after a healthy session; pace consecutive failed attempts.
final class ReconnectBackoff {
  int _failures = 0;
  int _noPath = 0;
  bool _wasReady = false;

  /// Consecutive attempts where no direct route opened before RHR says the
  /// two networks cannot connect directly and stops.
  static const noPathLimit = 3;

  void markReady() {
    _failures = 0;
    _noPath = 0;
    _wasReady = true;
  }

  /// Records a failed direct attempt; true once [noPathLimit] in a row found
  /// no direct route. Any other direct failure breaks the run.
  bool directPathImpossible(DirectTransportFailure failure) {
    _noPath = failure.noPath ? _noPath + 1 : 0;
    return _noPath >= noPathLimit;
  }

  Duration nextDelay() {
    if (_wasReady) {
      _wasReady = false;
      return Duration.zero;
    }
    return Duration(seconds: (2 * ++_failures).clamp(2, 15));
  }
}
