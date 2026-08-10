# rhr — Expo Go for Flutter, over the internet

<p align="center">
  <img src="assets/brand/rhr-mark-25d-paper-depth.png" alt="rhr logo" width="240" />
</p>

Hot reload a Flutter app running on an Android device **anywhere on the internet**, in ~2 seconds, with app state preserved. No adb, no USB, no shared network, no VPN.

Install one app on the device — the **rhr player** — and stream *any* of your Flutter projects into it. Nothing to install per project, nothing to rebuild when you change code.

```
Your machine                   Cloudflare (Durable Object)         Remote device
┌──────────────────┐           ┌──────────────────────┐           ┌─────────────────────┐
│ rhr run          │◄──WSS────►│  RelaySession per    │◄───WSS────│ rhr player          │
│ └ flutter attach │           │  session code        │ (outbound)│ (generic shell app) │
│   --debug-url    │           └──────────────────────┘           │   └► Dart VM Service │
│   localhost:...  │                                              │      (debug build)  │
└──────────────────┘                                              └─────────────────────┘
```

Hot reload is already a network protocol — the Flutter tool compiles on your machine and pushes kernel deltas to the device's Dart VM Service over WebSocket. The only reason it normally needs USB or local Wi-Fi is *reachability*. rhr fixes that: the device dials **out** to a relay (firewall/NAT-proof), and your `flutter attach` connects to a localhost tunnel. Reload, restart, breakpoints, and DevTools all work. Source never leaves your machine — only compiled kernel bytes travel.

The **player** is a generic debug Flutter app. It boots to a lobby, takes a session code, and holds the tunnel in a native Android foreground service — so it survives your app's hot restarts and Android backgrounding. Your project needs **zero integration**: no dependency, no code change.

> **Android only, deliberately.** iOS is technically possible via sideloaded JIT, but every device's UDID must sit in a provisioning profile (free ones expire after 7 days), a Mac is required to build, and the JIT path breaks with each iOS release. That trades rhr's premise — set a device up once and forget about it — for a maintenance treadmill.

## Quick start

**1. Install the player.** Grab the arm64 Player APK from
[Releases](https://github.com/therealsuji/rhr/releases) and sideload it, or
build it:

```bash
cd player && flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

It must be a **debug** build — hot reload needs the Dart VM Service (JIT), which release builds don't have.

**2. Pick a relay.** The player ships pointed at a public relay (`wss://rhr-relay.codeforge007.workers.dev`) so you can try it with zero setup. For real work, deploy your own — it runs on Cloudflare's **free tier**, realistically $0/mo:

```bash
cd relay-worker && pnpm install && pnpm run deploy
# → wss://rhr-relay.<account>.workers.dev
```

Then pass `--relay` to the CLI, or bake it in with `--dart-define=RHR_RELAY=…`.

**3. Install the CLI once.**

```bash
dart pub global activate --source git \
  https://github.com/therealsuji/rhr.git \
  --git-path cli \
  --git-ref v0.1.0-beta.1

rhr doctor
```

If your shell cannot find `rhr`, add `$HOME/.pub-cache/bin` to `PATH`
(`%LOCALAPPDATA%\Pub\Cache\bin` on Windows).

**4. Run from your project.**

```bash
cd your-flutter-project
rhr run
```

Scan the printed QR with the player (or type the session code). rhr builds an Android bundle, syncs it to the device, and boots your app automatically. Then `r` to reload, `R` to restart, `q` to quit.

`--resync` ignores the device-side asset cache and re-uploads everything. `q` leaves the device VM alive, so `rhr run --code <same-code>` reconnects later without reopening the player.

## Measured

On a Samsung SM-A566B (Android 16, arm64) over the public Cloudflare relay, streaming a stock `flutter create` app:

| | |
|---|---|
| Hot reload | **1.6 s** (compile 132 ms, reload 513 ms, reassemble 443 ms) |
| Hot restart | 11 s warm, 19 s cold |
| Cold asset sync | 12 files, 53 MB, 10 s |
| Warm asset sync | 6 of 12 files skipped via manifest |

App state survives reloads — a counter at 3 stayed at 3 across a reload that changed the widget tree.

## Installing the CLI

The beta is installed directly from its locked Git tag:

```bash
dart pub global activate --source git \
  https://github.com/therealsuji/rhr.git \
  --git-path cli \
  --git-ref v0.1.0-beta.1
```

This is a one-time setup. Afterward, use `rhr run` from any Flutter project.
Run `rhr doctor` to check Flutter and make sure no adb device will interfere
with the remote attach flow.

## Repo layout

- `player/` — the rhr player: generic Flutter shell + native Android session service.
- `cli/` — `rhr run`: builds, attaches, syncs assets, gates compatibility.
- `relay-worker/` — production relay: Cloudflare Worker, one Durable Object per session.
- `relay/` — the same protocol as a local Dart server, for development.
- `bridge/` — device-side Dart package plus the shared tunnel protocol.

## Constraints

- **Android only.** Debug builds only (JIT) — release builds have no VM service, by design.
- Your Flutter framework revision, engine revision, and Dart SDK must match the player APK. `rhr` checks this before streaming.
- Every Android plugin and permission your project needs must be covered by the installed player. `rhr` blocks and lists anything missing. Custom Android source or native libraries need a project-specific player (see below).
- Hot reload is the fast path; a hot *restart* re-syncs the whole kernel.
- Android freezes backgrounded apps — the tunnel reconnects within ~30 s of the app returning to the foreground.
- Before distributing a player APK, run `dart run tool/check_16kb.dart` from `player/` to verify Android 16 KB alignment.

## Security

A session code is a **bearer token**: anyone who knows it can attach to the relayed VM service, which is arbitrary code execution inside the running app. Treat codes like credentials, and prefer your own relay for real work — on a shared relay the code is your only isolation.

The relay carries compiled kernel bytes only; your source never leaves your machine. Its application logs do not record session codes, VM Service URIs, or frame contents.

## Alternatives to the generic player

**Bridge-in-your-own-app.** Instead of the player, embed the tunnel in your own debug app — add `rhr_bridge` as a path dependency and call `RhrBridge.start(relayUrl: …, sessionCode: …)` in `main()` under `kDebugMode`, then `rhr attach`. This is the older path and less exercised than the player; note that a hot *restart* tears down the Dart-side bridge until the app relaunches.

**Project-specific player.** For apps with uncommon native dependencies, `rhr player build --project .` generates a matching player APK. It pins your resolved Android plugins and merges required permissions, leaving your app source untouched. Custom Android source, native libraries, and Firebase config aren't covered yet — this is a prototype, not part of the normal flow.

## Development

```bash
# End-to-end smoke test on the desktop, no device required:
cd relay  && dart run bin/relay.dart 8123 &
cd bridge && dart run --enable-vm-service=0 example/fake_device.dart ws://127.0.0.1:8123 test &
cd cli    && dart run bin/rhr.dart attach --relay ws://127.0.0.1:8123 --code test --no-flutter
```

Checks before a release:

```bash
cd cli            && dart analyze && dart test
cd relay-worker   && pnpm run typecheck && pnpm run check
cd player/android && ./gradlew :app:compileDebugKotlin
cd player         && dart analyze && flutter test && dart run tool/check_16kb.dart
```

## License

MIT — see [LICENSE](LICENSE).
