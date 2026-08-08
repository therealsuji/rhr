import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

Future<void> main(List<String> args) async {
  final apk = File(
    args.firstOrNull ?? 'build/app/outputs/flutter-apk/app-debug.apk',
  ).absolute;
  if (!apk.existsSync()) {
    stderr.writeln('APK not found: ${apk.path}');
    exitCode = 64;
    return;
  }

  final zipalign = _findZipalign();
  final zipCheck = await Process.run(zipalign.path, [
    '-c',
    '-P',
    '16',
    '4',
    apk.path,
  ]);
  if (zipCheck.exitCode != 0) {
    stderr.writeln('ZIP_FAIL: native libraries are not 16 KB zip-aligned');
  }

  final listing = await Process.run('unzip', ['-Z1', apk.path]);
  if (listing.exitCode != 0) {
    stderr.writeln(listing.stderr);
    exitCode = 1;
    return;
  }
  final libraries = const LineSplitter()
      .convert(listing.stdout as String)
      .where(
        (entry) =>
            RegExp(r'^lib/(arm64-v8a|x86_64)/[^/]+\.so$').hasMatch(entry),
      )
      .toList();

  var elfFailures = 0;
  for (final library in libraries) {
    final extracted = await Process.run('unzip', [
      '-p',
      apk.path,
      library,
    ], stdoutEncoding: null);
    if (extracted.exitCode != 0) {
      stderr.writeln('READ_FAIL: $library');
      elfFailures++;
      continue;
    }
    final bytes = extracted.stdout as List<int>;
    final badAlignments = _loadAlignments(
      bytes,
    ).where((align) => align < 16384);
    if (badAlignments.isNotEmpty) {
      stderr.writeln(
        'ELF_FAIL: $library LOAD alignment '
        '${badAlignments.map((value) => '0x${value.toRadixString(16)}').join(', ')}',
      );
      elfFailures++;
    }
  }

  if (zipCheck.exitCode == 0 && elfFailures == 0) {
    stdout.writeln('16 KB compatible: ${libraries.length} native libraries');
    return;
  }
  stderr.writeln(
    '16 KB incompatible: $elfFailures/${libraries.length} ELF libraries failed',
  );
  exitCode = 1;
}

Iterable<int> _loadAlignments(List<int> bytes) sync* {
  final data = ByteData.sublistView(Uint8List.fromList(bytes));
  if (data.lengthInBytes < 64 ||
      data.getUint32(0, Endian.big) != 0x7f454c46 ||
      data.getUint8(5) != 1) {
    throw const FormatException('expected a little-endian ELF library');
  }
  final elfClass = data.getUint8(4);
  final is64Bit = elfClass == 2;
  if (!is64Bit && elfClass != 1) {
    throw FormatException('unsupported ELF class $elfClass');
  }
  final programOffset = is64Bit
      ? data.getUint64(32, Endian.little)
      : data.getUint32(28, Endian.little);
  final entrySize = data.getUint16(is64Bit ? 54 : 42, Endian.little);
  final entryCount = data.getUint16(is64Bit ? 56 : 44, Endian.little);
  for (var index = 0; index < entryCount; index++) {
    final offset = programOffset + index * entrySize;
    if (data.getUint32(offset, Endian.little) == 1) {
      yield is64Bit
          ? data.getUint64(offset + 48, Endian.little)
          : data.getUint32(offset + 28, Endian.little);
    }
  }
}

File _findZipalign() {
  final roots = [
    Platform.environment['ANDROID_SDK_ROOT'],
    Platform.environment['ANDROID_HOME'],
    '${Platform.environment['HOME']}/Library/Android/sdk',
  ].nonNulls;
  for (final root in roots) {
    final buildTools = Directory('$root/build-tools');
    if (!buildTools.existsSync()) continue;
    final candidates =
        buildTools
            .listSync()
            .whereType<Directory>()
            .map((directory) => File('${directory.path}/zipalign'))
            .where((file) => file.existsSync())
            .toList()
          ..sort((a, b) => b.path.compareTo(a.path));
    if (candidates.isNotEmpty) return candidates.first;
  }
  throw StateError('zipalign not found; set ANDROID_SDK_ROOT');
}
