/// Retry immediately after a healthy session; pace consecutive failed attempts.
final class ReconnectBackoff {
  int _failures = 0;
  bool _wasReady = false;

  void markReady() {
    _failures = 0;
    _wasReady = true;
  }

  Duration nextDelay() {
    if (_wasReady) {
      _wasReady = false;
      return Duration.zero;
    }
    return Duration(seconds: (2 * ++_failures).clamp(2, 15));
  }
}
