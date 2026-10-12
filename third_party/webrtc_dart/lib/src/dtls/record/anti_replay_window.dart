/// DTLS replay detection (RFC 6347 Section 4.1.2.6): a sliding window over
/// the record sequence numbers of one epoch.
///
/// Bit `i` of the bitmap records whether sequence number `latest - i` was
/// received. Anything newer than the latest is accepted and slides the window
/// forward, however far it jumps: losing a burst of records must not wedge
/// the connection. Anything older than the window is rejected.
class AntiReplayWindow {
  /// Window size in records.
  static const int width = 64;

  /// Highest sequence number received, or null before the first.
  int? _latest;

  /// Received flags for `_latest - 0` .. `_latest - 63`.
  int _bitmap = 0;

  /// Forgets everything received, as for a new epoch.
  void reset() {
    _latest = null;
    _bitmap = 0;
  }

  /// Whether a record with [seqNum] may be processed: it is newer than any
  /// seen, or inside the window and not seen yet.
  bool mayReceive(int seqNum) {
    final latest = _latest;
    if (latest == null || seqNum > latest) return true;
    final age = latest - seqNum;
    return age < width && (_bitmap >> age) & 1 == 0;
  }

  /// Whether [seqNum] is inside the window and was received.
  bool hasReceived(int seqNum) => !mayReceive(seqNum) && _isInWindow(seqNum);

  /// Marks [seqNum] received. Call only once the record authenticated, or a
  /// forged record could burn a genuine one's sequence number.
  void markAsReceived(int seqNum) {
    final latest = _latest;
    if (latest == null || seqNum > latest) {
      final shift = latest == null ? width : seqNum - latest;
      // Dart ints are 64-bit: bits shifted past the window fall away.
      _bitmap = (shift >= width ? 0 : _bitmap << shift) | 1;
      _latest = seqNum;
    } else if (_isInWindow(seqNum)) {
      _bitmap |= 1 << (latest - seqNum);
    }
  }

  bool _isInWindow(int seqNum) {
    final latest = _latest;
    return latest != null && seqNum <= latest && latest - seqNum < width;
  }

  @override
  String toString() =>
      'AntiReplayWindow(latest=$_latest, bitmap=0x${_bitmap.toRadixString(16)})';
}
