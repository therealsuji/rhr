# Changelog

## 0.1.0-beta.9

- Connect the phone before selecting hosted or separate-app mode.
- Guide connector setup, verify installed APKs, and open the target app automatically.
- Reuse session codes and validated APKs across retries.
- Recover from interrupted transfers and player replacement; reject signing conflicts without deleting app data.
- Add `rhr update` and `rhr update --check` for published CLI releases.

## 0.1.0-beta.4

- Allow patch-level Flutter/Dart skew inside one stable series with a warning;
  cross-minor, non-stable, and unknown-channel pairs keep the exact gate.
- Players report their release channel so the gate can prove series identity.
- Direct mode keeps tunnel payloads off the relay and fails instead of silently
  falling back. `--no-direct` remains only for legacy/private payload relays.
- Cloudflare and self-hosted relays reject binary payloads and oversized
  control messages.

## 0.1.0-beta.3

- Add bounded no-player waiting with an actionable exit status.
- Improve direct WebRTC failure containment and relay fallback.
- Stabilize USB asset synchronization and native session reconnects.

## 0.1.0-beta.2

- Add LAN and USB asset delivery paths.
- Add Flutter compatibility checks and the `rhr doctor` command.
