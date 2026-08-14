# rhr CLI

The `rhr` command connects a Flutter developer to an Android RHR Player over
a relay and exposes the phone's Dart VM Service on localhost. It is a debug
tool: the Flutter project and Player must use matching Flutter framework,
engine, Dart, plugin, and permission inputs.

## Install the beta

From the repository's tagged release:

```bash
dart pub global activate --source git \
  https://github.com/therealsuji/rhr.git \
  --git-path cli \
  --git-ref v0.1.0-beta.3
```

Then run `rhr doctor` from a shell where the Dart global executable directory
is on `PATH`.

## Development

```bash
dart pub get
dart analyze
dart test
dart run bin/rhr.dart --help
```

The package is intentionally kept as a Git-installed beta while the shared
bridge and vendored WebRTC transport settle. The supported hosted relay is a
convenience for development, not a production security boundary.
