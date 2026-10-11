import 'dart:math';
import 'dart:typed_data';

/// Binary delta between two versions of a DevFS file, so a hot restart sends
/// what changed instead of the whole program.
///
/// Flutter resets its compiler on every hot restart and uploads the complete
/// kernel: about 42 MB, 12.6 MB gzipped, for a small app. Between two restarts
/// almost all of it is byte-identical but shifted, so a content-defined
/// chunking delta against the previous upload is a few tens of kilobytes.
///
/// Wire format, all integers big-endian:
///
///     "RHRD" 0x01                         magic and version
///     0x01 offset:u64 length:u32          copy a range of the base
///     0x02 length:u32 bytes[length]       insert literal bytes
///
/// Only the encoder needs the chunker. The player applies the operations in
/// order against its stored base, which keeps that side trivial.
const devFsDeltaMagic = [0x52, 0x48, 0x52, 0x44, 0x01];
const _opCopy = 0x01;
const _opInsert = 0x02;

// Content-defined chunks average 2 KiB: measured on two debug kernels that
// differ by one string, that gave 18 KB of literals in 108 operations.
const _chunkBits = 11;
const _minChunk = 512;
const _maxChunk = 8192;

final List<int> _gear = () {
  final random = Random(7);
  return List<int>.generate(
    256,
    (_) => (random.nextInt(1 << 32) << 32) | random.nextInt(1 << 32),
  );
}();

/// Chunk boundaries of [bytes] as (offset, length) pairs, cut where a gear
/// hash of the preceding bytes has its top [_chunkBits] bits clear. The cut
/// depends only on nearby content, so an insertion moves only nearby cuts.
List<(int, int)> _chunks(Uint8List bytes) {
  final chunks = <(int, int)>[];
  var start = 0;
  var hash = 0;
  for (var i = 0; i < bytes.length; i++) {
    hash = (hash << 1) + _gear[bytes[i]];
    final length = i + 1 - start;
    if ((length >= _minChunk && hash >>> (64 - _chunkBits) == 0) ||
        length >= _maxChunk) {
      chunks.add((start, length));
      start = i + 1;
      hash = 0;
    }
  }
  if (start < bytes.length) chunks.add((start, bytes.length - start));
  return chunks;
}

int _fnv1a(Uint8List bytes, int start, int length) {
  var hash = 0xcbf29ce484222325;
  for (var i = start; i < start + length; i++) {
    hash = (hash ^ bytes[i]) * 0x100000001b3;
  }
  return hash;
}

bool _same(Uint8List a, int aStart, Uint8List b, int bStart, int length) {
  for (var i = 0; i < length; i++) {
    if (a[aStart + i] != b[bStart + i]) return false;
  }
  return true;
}

/// Operations that turn [base] into [next].
Uint8List encodeDevFsDelta(Uint8List base, Uint8List next) {
  final index = <int, List<(int, int)>>{};
  for (final (offset, length) in _chunks(base)) {
    (index[_fnv1a(base, offset, length)] ??= []).add((offset, length));
  }

  final out = BytesBuilder(copy: false)..add(devFsDeltaMagic);
  final header = ByteData(13);
  int? copyOffset;
  var copyLength = 0;
  int? insertStart;
  var insertLength = 0;

  void flushCopy() {
    if (copyOffset == null) return;
    header
      ..setUint8(0, _opCopy)
      ..setUint64(1, copyOffset!)
      ..setUint32(9, copyLength);
    out.add(Uint8List.fromList(header.buffer.asUint8List(0, 13)));
    copyOffset = null;
  }

  void flushInsert() {
    if (insertStart == null) return;
    header
      ..setUint8(0, _opInsert)
      ..setUint32(1, insertLength);
    out
      ..add(Uint8List.fromList(header.buffer.asUint8List(0, 5)))
      ..add(
        Uint8List.sublistView(next, insertStart!, insertStart! + insertLength),
      );
    insertStart = null;
  }

  for (final (start, length) in _chunks(next)) {
    final candidates = index[_fnv1a(next, start, length)];
    final match = candidates?.where(
      (c) => c.$2 == length && _same(base, c.$1, next, start, length),
    );
    final found = match == null || match.isEmpty ? null : match.first;
    if (found == null) {
      flushCopy();
      if (insertStart == null) {
        insertStart = start;
        insertLength = 0;
      }
      insertLength += length;
    } else {
      flushInsert();
      if (copyOffset != null && copyOffset! + copyLength == found.$1) {
        copyLength += length;
      } else {
        flushCopy();
        copyOffset = found.$1;
        copyLength = length;
      }
    }
  }
  flushCopy();
  flushInsert();
  return out.takeBytes();
}

/// Rebuilds the file [encodeDevFsDelta] described. The player carries its
/// own implementation; this one exists so the format has a Dart reference
/// that the tests hold the encoder to.
Uint8List applyDevFsDelta(Uint8List base, Uint8List delta) {
  for (var i = 0; i < devFsDeltaMagic.length; i++) {
    if (delta.length <= i || delta[i] != devFsDeltaMagic[i]) {
      throw const FormatException('not an RHR DevFS delta');
    }
  }
  final data = ByteData.sublistView(delta);
  final out = BytesBuilder(copy: false);
  var at = devFsDeltaMagic.length;
  while (at < delta.length) {
    switch (delta[at]) {
      case _opCopy:
        final offset = data.getUint64(at + 1);
        final length = data.getUint32(at + 9);
        out.add(Uint8List.sublistView(base, offset, offset + length));
        at += 13;
      case _opInsert:
        final length = data.getUint32(at + 1);
        out.add(Uint8List.sublistView(delta, at + 5, at + 5 + length));
        at += 5 + length;
      default:
        throw FormatException('unknown DevFS delta op ${delta[at]}');
    }
  }
  return out.takeBytes();
}
