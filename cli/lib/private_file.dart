import 'dart:io';

/// Writes [contents] to [file] so that only this user can read it.
///
/// For session codes, claims, control tokens and the account token. Dart
/// cannot create a file with a mode, so writing first and chmod-ing after
/// leaves the file readable under the default umask until chmod runs, and
/// for good if chmod fails. The parent directory is locked to this user
/// before anything is written, which keeps every file in it private no
/// matter what mode the file itself gets.
void writePrivateFile(File file, String contents) {
  ensurePrivateDirectory(file.parent);
  file.writeAsStringSync(contents, flush: true);
  // Files written by older releases may still carry the umask's mode.
  if (!Platform.isWindows) _chmod('600', file.path);
}

/// Creates [directory] if needed and makes it accessible to this user only.
void ensurePrivateDirectory(Directory directory) {
  directory.createSync(recursive: true);
  if (!Platform.isWindows) _chmod('700', directory.path);
}

void _chmod(String mode, String path) {
  final result = Process.runSync('chmod', [mode, path]);
  if (result.exitCode != 0) {
    throw FileSystemException(
      'could not restrict permissions: ${result.stderr}'.trim(),
      path,
    );
  }
}
