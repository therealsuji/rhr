# rhr — Expo Go for Flutter, over the internet

<p align="center">
  <img src="assets/brand/rhr-mark-25d-paper-depth.png" alt="rhr logo" width="240" />
</p>

Hot reload a Flutter app running on an Android device **anywhere on the internet**, in ~2 seconds, with app state preserved. No adb, no USB, no shared network, no VPN.

Install one app on the device — the **rhr player** — and stream *any* of your Flutter projects into it. Nothing to install per project, nothing to rebuild when you change code.

```
Your machine                   Relay (Cloudflare or self-hosted)   Remote device
┌──────────────────┐           ┌──────────────────────┐           ┌─────────────────────┐
│ rhr run          │◄──WSS────►│  one session/code    │◄───WSS────│ rhr player          │
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

The beta3 Player artifact is built for Android `arm64-v8a` with Flutter
3.44.2 stable (Dart 3.12.2, engine revision
`77e2e94772b6eb43759e34ed1ad7da4674e19cab`). The CLI compares framework,
engine, Dart, Android plugin, and permission metadata before it streams. The
matching release includes `FLUTTER_VERSION.json` and `RELEASE_MANIFEST.txt`.

**2. Pick a relay.** The player ships pointed at a public relay (`wss://rhr-relay.codeforge007.workers.dev`) so you can try it with zero setup. For real work, use your own relay so the session bearer codes and traffic stay within infrastructure you control. The supported private option is another deployment of the same Cloudflare Worker, which runs on Cloudflare's **free tier** for small personal use:

```bash
cd relay-worker && pnpm install && pnpm run deploy
# → wss://rhr-relay.<account>.workers.dev
```

Then pass `--relay` to the CLI, or bake it in with `--dart-define=RHR_RELAY=…`.

For the product flow, pass the private relay directly to `rhr run`:

```bash
rhr run --relay wss://rhr-relay.<account>.workers.dev
```

You can avoid repeating it by putting `relay: wss://…` in `.rhr.yaml` next to
the Flutter project. An explicit private relay replaces the shared public
fallback; the temporary LAN relay is still preferred when the phone and
computer share a network. For the Dart bridge experiment, add `direct: true`
to the same file instead of passing `--direct` each time.

The Dart relay in [`relay/`](relay/) is a development/self-hosting building
block for a single-server deployment. It is plain HTTP/WebSocket and should be
placed behind a TLS reverse proxy before exposing it to the internet; the
Cloudflare Worker remains the easiest hosted default while this path is being
hardened. A Docker image and deployment notes are in [`relay/README.md`](relay/README.md).

**3. Install the CLI once.**

```bash
dart pub global activate --source git \
  https://github.com/therealsuji/rhr.git \
  --git-path cli \
  --git-ref v0.1.0-beta.3

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

The session code is a bearer credential: anyone who has it can control the
debug VM. Keep it private and never use rhr with production data. If no Player
joins an `attach` session within five minutes, the CLI exits with an actionable
message instead of retrying forever.

`--resync` ignores the device-side asset cache and re-uploads everything. `q` leaves the device VM alive, so `rhr run --code <same-code>` reconnects later without reopening the player.

When the phone is connected over USB, `rhr run` automatically sends the initial
asset bundle and later asset deltas through `adb`; the session, VM Service, and
hot-reload protocol still use the normal rhr tunnel. The CLI matches the cable
to the active Player's private store identity, so another connected Android
device cannot receive the files accidentally. If USB disappears, the same
range waits for adb to recover and retries automatically; repeated failures
fall back to the wireless tunnel without changing the command.

Without USB, a phone on the same network can use the temporary LAN relay carried
in the QR. The player tries that first and falls back to the public relay, while
the CLI races both paths and reports which one won. No flag or network setup is
required. The LAN listener exists only for the session and uses the same bearer
code and tunnel protocol as the public path.

### Direct WebRTC/STUN payloads (opt-in)

The Dart bridge and CLI can now try an ordered, reliable WebRTC data channel for
the tunnel payload. The existing relay carries the small offer/answer and ICE
messages and remains the automatic fallback, so this is safe to try before a
full relay-free signaling service exists:

```dart
RhrBridge.start(
  relayUrl: relay,
  sessionCode: code,
  preferDirect: true,
);
```

Run the matching attach with `rhr attach --direct`. If ICE or DTLS cannot
complete, the command continues over the normal WebSocket tunnel. The generic
Player can opt into the same native path when built with
`--dart-define=RHR_DIRECT=true`; cellular validation and moving signaling off
the public relay are the next gates for making this the default.

The native Android path has now been exercised on the real Samsung test phone:
the direct data channel negotiated over Wi-Fi and carried a VM-service request
without dropping the relay fallback. This is still an opt-in experiment; the
cellular and strict-NAT matrix is not proven yet.

For a development APK with native direct transport enabled:

```bash
cd player
flutter build apk --debug --dart-define=RHR_DIRECT=true
```

Asset uploads are content-addressed per installed player. Unchanged files stay
in the phone's persistent cache. USB archives are SHA-256 verified in bounded
chunks, while files larger than 16 MiB use independently retryable 4 MiB byte
ranges. Wireless retries at file granularity, and gzip work runs in parallel
without blocking VM-service traffic. `rhr run` prints raw/wire bytes,
throughput, and compression time so slow projects can be measured directly.

## Measured

On a Samsung SM-A566B (Android 16, arm64) over the public Cloudflare relay, streaming a stock `flutter create` app:

| | |
|---|---|
| Hot reload | **1.6 s** (compile 132 ms, reload 513 ms, reassemble 443 ms) |
| Hot restart | 11 s warm, 19 s cold |
| Cold asset sync | 12 files, 53 MB, 10 s |
| Warm asset sync | 6 of 12 files skipped via manifest |

App state survives reloads — a counter at 3 stayed at 3 across a reload that changed the widget tree.

The larger Velia benchmark (519 files, 421.3 MB raw) on the same phone measured:

| Asset route | Cold sync |
|---|---:|
| Public relay | 173.4 s |
| Initial LAN path | 161.6 s |
| Optimized LAN pipeline (350.1 MB wire) | 143.4 s |
| **USB fast path, forced adb reset (491.7 MB wire)** | **42.3 s** |

The fault-injected USB run recovered without wireless fallback, then an
independent inventory matched all 519 phone files to the host SHA-256 digests.
A warm run skips unchanged files; changing one generated asset uploads only
that file.

## Installing the CLI

The beta is installed directly from its locked Git tag:

```bash
dart pub global activate --source git \
  https://github.com/therealsuji/rhr.git \
  --git-path cli \
  --git-ref v0.1.0-beta.3
```

This is a one-time setup. Afterward, use `rhr run` from any Flutter project.
Run `rhr doctor` to check Flutter and see whether the optional USB asset fast
path is available.

## Repo layout

- `player/` — the rhr player: generic Flutter shell + native Android session service.
- `cli/` — `rhr run`: builds, attaches, syncs assets, gates compatibility.
- `relay-worker/` — hosted relay: Cloudflare Worker, one Durable Object per session.
- `relay/` — single-instance Dart relay for development and self-hosting.
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

The automatic LAN path is an unencrypted `ws://` connection inside the local
network. It carries compiled debug artifacts, not source, and still requires
the random session bearer code. Disable untrusted local networks or use the
public `wss://` path when local-network observers are in scope.

The relay carries compiled kernel bytes only; your source never leaves your machine. Its application logs do not record session codes, VM Service URIs, or frame contents. See [SECURITY.md](SECURITY.md) before reporting a problem.

## Alternatives to the generic player

**Bridge-in-your-own-app.** Instead of the player, embed the tunnel in your own debug app — add `rhr_bridge` as a path dependency and call `RhrBridge.start(relayUrl: …, sessionCode: …)` in `main()` under `kDebugMode`, then `rhr attach`. Add `preferDirect: true` and use `rhr attach --direct` to exercise the opt-in WebRTC/STUN payload path. This is the older path and less exercised than the player; note that a hot *restart* tears down the Dart-side bridge until the app relaunches.

**Project-specific player.** For apps with uncommon native dependencies, `rhr player build --project .` generates a matching player APK. It pins your resolved Android plugins and merges required permissions, leaving your app source untouched. Custom Android source, native libraries, and Firebase config aren't covered yet — this is a prototype, not part of the normal flow.

## Development

```bash
# End-to-end smoke test on the desktop, no device required:
cd relay  && dart run bin/relay.dart 8123 &
cd bridge && dart run --enable-vm-service=0 example/fake_device.dart ws://127.0.0.1:8123 rhr-test-2345-6789-abcd &
cd cli    && dart run bin/rhr.dart attach --relay ws://127.0.0.1:8123 --code rhr-test-2345-6789-abcd --no-flutter
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

Contributions and safe bug reports are covered by [CONTRIBUTING.md](CONTRIBUTING.md)
and [SECURITY.md](SECURITY.md). Please use the issue forms for reproducible
compatibility reports and keep bearer session codes out of public discussions.
