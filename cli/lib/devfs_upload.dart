import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'devfs_delta.dart';

/// Header naming the SHA-256 of the file a rewritten DevFS upload carries.
/// Its presence is what tells the player the request is RHR's, not Flutter's.
const rhrContentShaHeader = 'rhr-content-sha256';

/// Header naming the base the body is a delta against. Absent means the body
/// is the whole file, gzipped, which the player also keeps as a future base.
const rhrDeltaBaseHeader = 'rhr-delta-base';

/// Smaller files are cheaper to send whole than to index.
const devFsDeltaMinimumBytes = 256 * 1024;

/// One HTTP/1.1 request read from a local socket.
final class DevFsPut {
  DevFsPut(this.target, this.headers, this.gzippedBody);

  final String target;

  /// Lower-cased names.
  final Map<String, String> headers;
  final Uint8List gzippedBody;

  String? get fsName => headers['dev_fs_name'];

  /// The size gzip records in its trailer (RFC 1952: ISIZE, modulo 2^32).
  int get uncompressedSize => gzippedBody.length < 4
      ? 0
      : ByteData.sublistView(
          gzippedBody,
          gzippedBody.length - 4,
        ).getUint32(0, Endian.little);
  String? get uriBase64 => headers['dev_fs_uri_b64'];
}

/// Reads one request from a byte stream: the head, then a body framed by
/// Content-Length or chunked encoding (what dart:io's HttpClient sends when
/// it streams). Bytes after the request are ignored; RHR answers with
/// `connection: close`, so the client does not send another.
///
/// Parsing resumes where the last read stopped, so a 12 MB upload arriving
/// in socket-sized pieces is scanned once rather than once per piece.
final class HttpRequestReader {
  var _bytes = Uint8List(64 * 1024);
  var _length = 0;
  var _scanned = 0;
  String? _method;
  String? _target;
  Map<String, String>? _headers;
  int? _contentLength;
  int _bodyStart = 0;
  final _chunkedBody = BytesBuilder(copy: false);

  /// The request line's method once the head is in, otherwise null.
  String? get method => _method;
  Map<String, String>? get headers => _headers;

  /// Everything received so far, for handing to a raw tunnel unchanged.
  Uint8List get received => Uint8List.sublistView(_bytes, 0, _length);

  /// Feeds [data]; returns the request once its body is complete.
  DevFsPut? add(List<int> data) {
    if (_length + data.length > _bytes.length) {
      var capacity = _bytes.length * 2;
      while (capacity < _length + data.length) {
        capacity *= 2;
      }
      _bytes = Uint8List(capacity)..setRange(0, _length, _bytes);
    }
    _bytes.setRange(_length, _length + data.length, data);
    _length += data.length;
    if (_headers == null && !_readHead()) return null;
    final body = _contentLength != null ? _fixedBody() : _chunkedBodyDone();
    return body == null ? null : DevFsPut(_target!, _headers!, body);
  }

  bool _readHead() {
    final end = _find(const [13, 10, 13, 10], max(0, _scanned - 3));
    if (end < 0) {
      _scanned = _length;
      return false;
    }
    final lines = latin1.decode(_bytes.sublist(0, end)).split('\r\n');
    final requestLine = lines.first.split(' ');
    if (requestLine.length < 2) throw const FormatException('bad request line');
    _method = requestLine[0];
    _target = requestLine[1];
    _headers = {
      for (final line in lines.skip(1))
        if (line.contains(':'))
          line.substring(0, line.indexOf(':')).trim().toLowerCase(): line
              .substring(line.indexOf(':') + 1)
              .trim(),
    };
    _bodyStart = _scanned = end + 4;
    _contentLength = int.tryParse(_headers!['content-length'] ?? '');
    if (_contentLength == null &&
        _headers!['transfer-encoding']?.toLowerCase() != 'chunked') {
      throw const FormatException('upload without a body length');
    }
    return true;
  }

  Uint8List? _fixedBody() {
    final length = _contentLength!;
    if (_length - _bodyStart < length) return null;
    return Uint8List.fromList(
      Uint8List.sublistView(_bytes, _bodyStart, _bodyStart + length),
    );
  }

  /// [_scanned] marks the start of the next chunk-size line.
  Uint8List? _chunkedBodyDone() {
    while (true) {
      final lineEnd = _find(const [13, 10], _scanned);
      if (lineEnd < 0) return null;
      final size = int.parse(
        latin1
            .decode(_bytes.sublist(_scanned, lineEnd))
            .split(';')
            .first
            .trim(),
        radix: 16,
      );
      final dataStart = lineEnd + 2;
      if (size == 0) return _chunkedBody.takeBytes();
      if (_length < dataStart + size + 2) return null;
      _chunkedBody.add(
        Uint8List.fromList(
          Uint8List.sublistView(_bytes, dataStart, dataStart + size),
        ),
      );
      _scanned = dataStart + size + 2;
    }
  }

  int _find(List<int> pattern, int from) {
    outer:
    for (var i = from; i + pattern.length <= _length; i++) {
      for (var j = 0; j < pattern.length; j++) {
        if (_bytes[i + j] != pattern[j]) continue outer;
      }
      return i;
    }
    return -1;
  }
}

/// Files the player has confirmed storing, most recent first, so a later
/// upload can be sent as a delta against one of them.
///
/// Kept on disk under [directory] (the project's `.dart_tool/rhr`), because
/// the player keeps its copies across restarts too: a fresh CLI, after a
/// reconnect or a new `rhr run`, still sends its first restart as a delta.
/// A copy the phone has lost costs one whole upload (see [forget]).
final class DevFsBases {
  DevFsBases(this.directory) {
    final index = _index;
    if (!index.existsSync()) return;
    try {
      for (final entry
          in (jsonDecode(index.readAsStringSync()) as List)
              .cast<Map<String, dynamic>>()) {
        final sha = entry['sha'] as String;
        final file = File('${directory.path}/$sha');
        if (file.existsSync()) {
          _bases.add((
            uri: entry['uri'] as String,
            sha: sha,
            bytes: file.readAsBytesSync(),
          ));
        }
      }
    } on Object {
      forget();
    }
  }

  final Directory directory;
  // Room for the newest kernel alongside a couple of large assets; the
  // player keeps as many (DevFsDelta.KEPT_BASES).
  static const _kept = 3;
  final _bases = <({String uri, String sha, Uint8List bytes})>[];

  File get _index => File('${directory.path}/bases.json');

  /// The best base for [uri]: the most recent file of the same kind.
  ///
  /// Kernels are the uploads worth a delta, and each is nearly the same as
  /// the one before it. Flutter alternates a restart's kernel between two
  /// file names, so "the same file" would be two restarts old; the newest
  /// `.dill` is the previous restart's. A large asset is only compared with
  /// other assets.
  ({String sha, Uint8List bytes})? baseFor(String uri) {
    final kind = _isKernel(uri);
    for (final base in _bases) {
      if (_isKernel(base.uri) == kind)
        return (sha: base.sha, bytes: base.bytes);
    }
    return null;
  }

  static bool _isKernel(String uriBase64) {
    try {
      return utf8.decode(base64.decode(uriBase64)).endsWith('.dill');
    } on FormatException {
      return false;
    }
  }

  void confirm(String uri, String sha, Uint8List bytes) {
    _bases.removeWhere((b) => b.sha == sha || b.uri == uri);
    _bases.insert(0, (uri: uri, sha: sha, bytes: bytes));
    if (_bases.length > _kept) _bases.removeLast();
    _save();
  }

  /// The player no longer holds what we thought (it was reinstalled, or its
  /// cache was cleared): send whole files until it confirms new ones.
  void forget() {
    _bases.clear();
    _save();
  }

  void _save() {
    try {
      directory.createSync(recursive: true);
      final kept = {for (final base in _bases) base.sha};
      for (final base in _bases) {
        final file = File('${directory.path}/${base.sha}');
        if (!file.existsSync()) file.writeAsBytesSync(base.bytes);
      }
      for (final file in directory.listSync().whereType<File>()) {
        final name = file.uri.pathSegments.last;
        if (name != 'bases.json' && !kept.contains(name)) file.deleteSync();
      }
      _index.writeAsStringSync(
        jsonEncode([
          for (final base in _bases) {'uri': base.uri, 'sha': base.sha},
        ]),
      );
    } on FileSystemException {
      // A read-only project still works; it just sends whole files later.
    }
  }
}

/// The request RHR sends the player in place of [put]: the whole file, or a
/// delta against [base], either way gzipped and named by its SHA-256.
({Uint8List request, String sha, Uint8List content}) rewriteDevFsPut(
  DevFsPut put,
  ({String sha, Uint8List bytes})? base,
) {
  final content = Uint8List.fromList(gzip.decode(put.gzippedBody));
  final sha = sha256.convert(content).toString();
  final body = base != null
      ? Uint8List.fromList(gzip.encode(encodeDevFsDelta(base.bytes, content)))
      : put.gzippedBody;
  return (
    request: _devFsRequest(put, body, {
      rhrContentShaHeader: sha,
      rhrDeltaBaseHeader: ?base?.sha,
    }),
    sha: sha,
    content: content,
  );
}

/// [put] as Flutter sent it, except that it closes the connection after the
/// answer. A small upload is not worth a delta, but its connection must not
/// be reused: the next request on it could be a restart kernel.
Uint8List plainDevFsPut(DevFsPut put) =>
    _devFsRequest(put, put.gzippedBody, const {});

Uint8List _devFsRequest(
  DevFsPut put,
  Uint8List body,
  Map<String, String> extra,
) {
  final head = StringBuffer()
    ..write('PUT ${put.target} HTTP/1.1\r\n')
    ..write('host: ${put.headers['host'] ?? '127.0.0.1'}\r\n')
    ..write('dev_fs_name: ${put.fsName}\r\n')
    ..write('dev_fs_uri_b64: ${put.uriBase64}\r\n');
  extra.forEach((name, value) => head.write('$name: $value\r\n'));
  head
    ..write('content-length: ${body.length}\r\n')
    ..write('connection: close\r\n\r\n');
  return Uint8List.fromList([...latin1.encode(head.toString()), ...body]);
}

/// The status code of a raw HTTP response, or null if it has none yet.
int? httpStatus(List<int> response) {
  final line = latin1.decode(response.take(64).toList()).split('\r\n').first;
  final parts = line.split(' ');
  return parts.length > 1 && parts[0].startsWith('HTTP/')
      ? int.tryParse(parts[1])
      : null;
}
