import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:rhr_cli/devfs_delta.dart';
import 'package:rhr_cli/devfs_upload.dart';
import 'package:test/test.dart';

/// A DevFS PUT the way dart:io's HttpClient streams one: chunked.
Uint8List chunkedPut(List<int> gzipped, {int chunk = 1000}) {
  final out = BytesBuilder()
    ..add(
      latin1.encode(
        'PUT /abc=/ HTTP/1.1\r\n'
        'host: 127.0.0.1:5000\r\n'
        'transfer-encoding: chunked\r\n'
        'dev_fs_name: app\r\n'
        'dev_fs_uri_b64: ${base64.encode(utf8.encode('lib/main.dart.dill'))}\r\n'
        '\r\n',
      ),
    );
  for (var i = 0; i < gzipped.length; i += chunk) {
    final piece = gzipped.sublist(i, min(i + chunk, gzipped.length));
    out
      ..add(latin1.encode('${piece.length.toRadixString(16)}\r\n'))
      ..add(piece)
      ..add(latin1.encode('\r\n'));
  }
  out.add(latin1.encode('0\r\n\r\n'));
  return out.takeBytes();
}

DevFsPut read(Uint8List bytes, int step) {
  final reader = HttpRequestReader();
  for (var i = 0; i < bytes.length; i += step) {
    final put = reader.add(bytes.sublist(i, min(i + step, bytes.length)));
    if (put != null) return put;
  }
  throw StateError('request never completed');
}

void main() {
  final random = Random(3);
  final kernel = Uint8List.fromList(
    List.generate(400000, (_) => random.nextInt(256)),
  );

  test('reads a chunked upload however the socket splits it', () {
    final gzipped = gzip.encode(kernel);
    for (final step in [1, 7, 4096, 1 << 20]) {
      final put = read(chunkedPut(gzipped), step);
      expect(put.fsName, 'app');
      expect(gzip.decode(put.gzippedBody), kernel);
      expect(put.uncompressedSize, kernel.length);
    }
  });

  test('reads a Content-Length upload', () {
    final body = gzip.encode([1, 2, 3]);
    final put = read(
      Uint8List.fromList([
        ...latin1.encode(
          'PUT / HTTP/1.1\r\ncontent-length: ${body.length}\r\n'
          'dev_fs_name: app\r\n\r\n',
        ),
        ...body,
      ]),
      5,
    );
    expect(gzip.decode(put.gzippedBody), [1, 2, 3]);
  });

  test('a rewritten upload rebuilds to the original on the player', () {
    final next = Uint8List.fromList([
      ...kernel.sublist(0, 200000),
      ...utf8.encode('Text("changed")'),
      ...kernel.sublist(200000),
    ]);
    final put = read(chunkedPut(gzip.encode(next)), 65536);
    final base = (sha: sha256.convert(kernel).toString(), bytes: kernel);

    final rewritten = rewriteDevFsPut(put, base);

    // What the player receives: headers naming the base, and a small body.
    final received = read(rewritten.request, 65536);
    expect(received.headers[rhrDeltaBaseHeader], base.sha);
    expect(received.headers[rhrContentShaHeader], rewritten.sha);
    expect(received.gzippedBody.length, lessThan(20000));
    final rebuilt = applyDevFsDelta(
      kernel,
      Uint8List.fromList(gzip.decode(received.gzippedBody)),
    );
    expect(sha256.convert(rebuilt).toString(), rewritten.sha);
  });

  test('without a base the whole file goes, still named by its hash', () {
    final put = read(chunkedPut(gzip.encode(kernel)), 65536);
    final received = read(rewriteDevFsPut(put, null).request, 65536);
    expect(received.headers.containsKey(rhrDeltaBaseHeader), isFalse);
    expect(
      received.headers[rhrContentShaHeader],
      sha256.convert(kernel).toString(),
    );
    expect(gzip.decode(received.gzippedBody), kernel);
  });

  test('bases prefer the same file, then the most recent', () {
    final dir = Directory.systemTemp.createTempSync('rhr-bases-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final bases = DevFsBases(dir)
      ..confirm('a', 'sha-a', Uint8List(1))
      ..confirm('b', 'sha-b', Uint8List(2));
    expect(bases.baseFor('a')!.sha, 'sha-a');
    expect(bases.baseFor('c')!.sha, 'sha-b');
    bases.forget();
    expect(bases.baseFor('a'), isNull);
  });

  test('a fresh CLI still knows what the phone kept', () {
    final dir = Directory.systemTemp.createTempSync('rhr-bases-');
    addTearDown(() => dir.deleteSync(recursive: true));
    DevFsBases(dir)
      ..confirm('a', 'sha-a', Uint8List.fromList([1]))
      ..confirm('b', 'sha-b', Uint8List.fromList([2]))
      ..confirm('c', 'sha-c', Uint8List.fromList([3]));

    final reloaded = DevFsBases(dir);
    expect(reloaded.baseFor('c')!.bytes, [3]);
    expect(reloaded.baseFor('b')!.sha, 'sha-b');
    // Only the newest two are kept, on disk as in memory.
    expect(reloaded.baseFor('a')!.sha, 'sha-c');
    expect(File('${dir.path}/sha-a').existsSync(), isFalse);
  });

  test('reads a response status', () {
    expect(httpStatus(latin1.encode('HTTP/1.1 409 Conflict\r\n\r\n')), 409);
    expect(httpStatus(latin1.encode('HTT')), isNull);
  });
}
