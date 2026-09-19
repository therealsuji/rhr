# Contributing to rhr

Thanks for helping make remote Flutter development reliable. Small,
reproducible fixes are especially useful.

## Before opening an issue

Search existing issues first. Never include a live session code, VM Service
URL, private relay URL, access token, or unredacted application log.

For compatibility reports, include the CLI version, `flutter doctor -v`, phone
model and Android version, relay choice, and the project's plugin/permission
requirements. A short terminal transcript with secrets removed is ideal.

## Development setup

The repository contains independent Dart packages and a Cloudflare Worker:

```bash
cd bridge && dart pub get && dart test
cd ../cli && dart pub get && dart analyze && dart test
cd ../relay && dart pub get && dart analyze && dart test
cd ../relay-worker && pnpm install && pnpm run typecheck && pnpm run check
cd ../player && flutter pub get && flutter analyze && flutter test
```

For Android packaging, also run `./gradlew :app:compileDebugKotlin` from
`player/android` and `dart run tool/check_16kb.dart` from `player`.

## Pull requests

- Keep changes focused and explain the user-visible behavior.
- Add or update a test for protocol, transport, lifecycle, and error changes.
- Do not add real session codes, private relay URLs, APKs, keystores, or
  generated build output.
- Report exactly which checks passed and which require a physical device or
  network condition.

The Android Player is debug-only by design: it needs the Dart VM Service for
hot reload. Changes to native transport or compatibility metadata need both a
unit test and a real-device smoke result when possible.
