# Changelog

## 0.1.0-beta.4

- Allow patch-level Flutter/Dart skew inside one stable series with a warning;
  cross-minor, non-stable, and unknown-channel pairs keep the exact gate.
- Players report their release channel so the gate can prove series identity.

## 0.1.0-beta.3

- Add bounded no-player waiting with an actionable exit status.
- Improve direct WebRTC failure containment and relay fallback.
- Stabilize USB asset synchronization and native session reconnects.

## 0.1.0-beta.2

- Add LAN and USB asset delivery paths.
- Add Flutter compatibility checks and the `rhr doctor` command.
