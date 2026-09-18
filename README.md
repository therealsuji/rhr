# rhr — Expo Go for Flutter, over the internet

<p align="center">
  <img src="assets/brand/rhr-mark-25d-paper-depth.png" alt="rhr logo" width="240" />
</p>

Hot reload a Flutter app on an Android phone **anywhere on the internet** — about 2 seconds, app state intact. No adb, no USB, no shared Wi‑Fi, no VPN.

Install one app on the phone — the **rhr player** — and stream *any* of your Flutter projects into it. One install, no per-project setup, no rebuild when you change code.

```
Your machine                   Relay (Cloudflare or self-hosted)   Remote device
┌──────────────────┐           ┌──────────────────────┐           ┌─────────────────────┐
│ rhr run          │◄──WSS────►│  one session/code    │◄───WSS────│ rhr player          │
│ └ flutter attach │           │  session code        │ (outbound)│ (generic shell app) │
│   --debug-url    │           └──────────────────────┘           │   └► Dart VM Service │
│   localhost:...  │                                              │      (debug build)  │
└──────────────────┘                                              └─────────────────────┘
```

Hot reload is already a network protocol. Flutter compiles on your machine and pushes kernel deltas to the device's VM Service over WebSocket. USB and local Wi‑Fi are only there because the tool needs to *reach* the phone. rhr fixes reachability: the phone dials **out** to a relay (works through NAT and firewalls), and your `flutter attach` talks to a localhost tunnel. Reload, restart, breakpoints, DevTools — all of it. Your source stays on your machine; only compiled kernel bytes go over the wire.

The **player** is a generic debug Flutter app. Lobby, session code, tunnel held open in a native Android foreground service — so it survives hot restarts and backgrounding. Your project needs **zero integration**: no dependency, no code changes.

> **Android only, on purpose.** iOS is technically doable via sideloaded JIT, but every UDID has to be in a provisioning profile (free ones expire in 7 days), you need a Mac to build, and the JIT path breaks with every iOS release. That's a maintenance treadmill — the opposite of "set up once and forget."

## Quick start

**1. Install the player.** Grab the arm64 APK from [Releases](https://github.com/therealsuji/rhr/releases) and sideload it, or build it:

```bash
cd player && flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

Must be a **debug** build — hot reload needs the Dart VM Service (JIT), which release builds don't have.

The beta5 player targets Android `arm64-v8a`, Flutter 3.44.2 stable (Dart 3.12.2, engine `77e2e94772b6eb43759e34ed1ad7da4674e19cab`). The CLI checks framework, engine, Dart, Android plugins, and permissions before streaming. Each release ships `FLUTTER_VERSION.json` and `RELEASE_MANIFEST.txt`.

**2. Pick a relay.** The player defaults to a public relay (`wss://getrhr.dev`) so you can try it with zero setup. For real work, run your own — session codes and traffic stay on infrastructure you control. Easiest option: deploy the same Cloudflare Worker (free tier is fine for personal use):

```bash
cd relay-worker && pnpm install && pnpm run deploy
# → wss://rhr-relay.<account>.workers.dev
```

Pass `--relay` to the CLI, or bake it in with `--dart-define=RHR_RELAY=…`.

```bash
rhr run --relay wss://rhr-relay.<account>.workers.dev
```

Or put `relay: wss://…` in `.rhr.yaml` next to your Flutter project so you don't repeat it. An explicit private relay replaces the shared public one. If the phone and computer are on the same network, the temporary LAN relay wins automatically.

For the Dart bridge experiment, add `direct: true` to `.rhr.yaml` instead of passing `--direct` every time.

The Dart relay in [`relay/`](relay/) is for dev and single-server self-hosting. Plain HTTP/WebSocket — put it behind a TLS reverse proxy before exposing it. The Cloudflare Worker is still the easiest hosted default. Docker and deployment notes: [`relay/README.md`](relay/README.md).

**3. Install the CLI once.**

```bash
dart pub global activate --source git \
  https://github.com/therealsuji/rhr.git \
  --git-path cli \
  --git-ref v0.1.0-beta.5

rhr doctor
```

If `rhr` isn't found, add `$HOME/.pub-cache/bin` to `PATH` (`%LOCALAPPDATA%\Pub\Cache\bin` on Windows).

**4. Run from your project.**

```bash
cd your-flutter-project
rhr run
```

Scan the QR with the player (or type the session code). rhr builds an Android bundle, syncs it, and boots your app. Then `r` to reload, `R` to restart, `q` to quit.

The session code is a bearer credential — anyone with it can control the debug VM. Keep it private; don't use rhr with production data. If no player joins within five minutes, the CLI exits with a clear message instead of hanging.

`--resync` blows away the device-side asset cache and re-uploads everything. `q` leaves the VM running on the phone, so `rhr run --code <same-code>` reconnects later without reopening the player.

**USB asset fast path.** When the phone is on USB, `rhr run` sends the initial bundle and later deltas through `adb`. The session, VM Service, and hot-reload traffic still go through the normal rhr tunnel. The CLI matches the cable to the active player's identity so another connected device can't accidentally get your files. Lose USB mid-sync and it waits for adb to come back; if that keeps failing, it falls back to wireless without you changing anything.

**Same-network LAN.** Phone and computer on the same Wi‑Fi? The player tries a temporary LAN relay first (embedded in the QR), then falls back to the public relay. The CLI races both and tells you which won. No flags, no network config. The LAN listener only lives for the session and uses the same bearer code and tunnel protocol as the public path.

### Direct WebRTC/STUN (opt-in)

The Dart bridge and CLI can try a WebRTC data channel for tunnel payloads. The relay still carries the small offer/answer/ICE messages and remains the fallback — safe to experiment with before relay-free signaling exists:

```dart
RhrBridge.start(
  relayUrl: relay,
  sessionCode: code,
  preferDirect: true,
);
```

Matching attach: `rhr attach --direct`. If ICE or DTLS fails, it keeps going over the normal WebSocket tunnel. The generic player can opt in at build time with `--dart-define=RHR_DIRECT=true`. Cellular and moving signaling off the public relay are still TODO before this becomes default.

It's been exercised on a real Samsung test phone — direct data channel over Wi‑Fi, VM service request went through, relay fallback stayed intact. Still opt-in; cellular and strict NAT aren't proven yet.

```bash
cd player
flutter build apk --debug --dart-define=RHR_DIRECT=true
```

Asset uploads are content-addressed per installed player. Unchanged files stay in the phone's cache. USB archives are SHA-256 verified in chunks; files over 16 MiB use independently retryable 4 MiB ranges. Wireless retries per file; gzip runs in parallel without blocking VM service traffic. `rhr run` prints raw/wire bytes, throughput, and compression time when you want to see where the time goes.

## Measured

Samsung SM-A566B (Android 16, arm64), public Cloudflare relay, stock `flutter create` app:

| | |
|---|---|
| Hot reload | **1.6 s** (compile 132 ms, reload 513 ms, reassemble 443 ms) |
| Hot restart | 11 s warm, 19 s cold |
| Cold asset sync | 12 files, 53 MB, 10 s |
| Warm asset sync | 6 of 12 files skipped via manifest |

App state survives reloads — counter at 3 stayed at 3 after a reload that changed the widget tree.

Velia benchmark (519 files, 421.3 MB raw), same phone:

| Asset route | Cold sync |
|---|---:|
| Public relay | 173.4 s |
| Initial LAN path | 161.6 s |
| Optimized LAN pipeline (350.1 MB wire) | 143.4 s |
| **USB fast path, forced adb reset (491.7 MB wire)** | **42.3 s** |

Fault-injected USB run recovered without falling back to wireless; independent inventory matched all 519 phone files to host SHA-256. Warm runs skip unchanged files — touch one generated asset and only that file uploads.

## Installing the CLI

Same one-liner as above — locked to the beta tag:

```bash
dart pub global activate --source git \
  https://github.com/therealsuji/rhr.git \
  --git-path cli \
  --git-ref v0.1.0-beta.5
```

One-time setup. After that, `rhr run` from any Flutter project. `rhr doctor` checks Flutter and whether the USB asset fast path is available.

## Repo layout

- `player/` — generic Flutter shell + native Android session service
- `cli/` — `rhr run`: build, attach, sync assets, compatibility checks
- `relay-worker/` — Cloudflare Worker relay, one Durable Object per session
- `relay/` — single-instance Dart relay for dev/self-hosting
- `bridge/` — device-side Dart package + shared tunnel protocol

## Constraints

- **Android only.** Debug builds only (JIT) — release has no VM service, by design.
- Flutter framework, engine, and Dart SDK must match the player APK. `rhr` checks before streaming.
- Every Android plugin and permission your project needs must be in the installed player. `rhr` blocks and lists what's missing. Custom Android source or native libs need a project-specific player (below).
- Hot reload is fast; hot *restart* re-syncs the whole kernel.
- Android freezes backgrounded apps — tunnel reconnects within ~30 s of coming back to foreground.
- Before shipping a player APK: `dart run tool/check_16kb.dart` from `player/` (16 KB page alignment).

## Security

Session code = **bearer token**. Anyone with it can attach to the relayed VM service — that's arbitrary code execution inside your running app. Treat codes like passwords. Use your own relay for real work; on a shared relay the code is your only isolation.

The automatic LAN path is unencrypted `ws://` on the local network. Compiled debug artifacts only, not source — still needs the random session code. Don't use it on untrusted networks; stick to `wss://` if local observers matter.

The relay sees compiled kernel bytes, not source. Logs don't record session codes, VM Service URIs, or frame contents. See [SECURITY.md](SECURITY.md) before reporting issues.

## Alternatives to the generic player

**Bridge in your own app.** Skip the player — add `rhr_bridge` as a path dep, call `RhrBridge.start(relayUrl: …, sessionCode: …)` in `main()` under `kDebugMode`, then `rhr attach`. Add `preferDirect: true` + `rhr attach --direct` for the WebRTC experiment. Older path, less exercised than the player. Hot *restart* kills the Dart-side bridge until the app relaunches.

**Project-specific player.** Unusual native deps? `rhr player build --project .` builds a matching player APK — pins your Android plugins, merges permissions, leaves app source alone. Custom Android source, native libraries, and Firebase config aren't covered yet. Prototype, not the normal flow.

## Development

```bash
# End-to-end smoke test on the desktop, no device:
cd relay  && dart run bin/relay.dart 8123 &
cd bridge && dart run --enable-vm-service=0 example/fake_device.dart ws://127.0.0.1:8123 rhr-test-2345-6789-abcd &
cd cli    && dart run bin/rhr.dart attach --relay ws://127.0.0.1:8123 --code rhr-test-2345-6789-abcd --no-flutter
```

Before a release:

```bash
cd cli            && dart analyze && dart test
cd relay-worker   && pnpm run typecheck && pnpm run check
cd player/android && ./gradlew :app:compileDebugKotlin
cd player         && dart analyze && flutter test && dart run tool/check_16kb.dart
```

## License

MIT — [LICENSE](LICENSE).

Contributions and bug reports: [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md). Use the issue forms for compatibility reports; keep session codes out of public threads.
