# rhr — Expo Go for Flutter, over the internet

<p align="center">
  <img src="assets/brand/rhr-mark-25d-paper-depth.png" alt="rhr logo" width="240" />
</p>

Hot reload a Flutter app on your Android phone, wherever it is **on the internet** — about 2 seconds, app state intact. No adb, no USB, no shared Wi‑Fi, no VPN.

Install one app on the phone — the **rhr player** — and stream *any* of your Flutter projects into it. One install, no per-project setup, no rebuild when you change code.

```
Your machine                                        RHR relay (signaling only)   Remote device
┌──────────────────────────────┐                    ┌─────────────────────┐      ┌─────────────────────┐
│ rhr run                      │  offer/answer/ICE  │                     │      │ rhr player          │
│ └ flutter attach --debug-url │◄──and handshake──► │  one rendezvous per │◄───► │ (player or app mode)│
│                              │                    │  device/session     │      │   └► Dart VM Service│
│   └──── payload: direct WebRTC data channel ───────────────────────────────┘      │      (debug build)  │
└──────────────────────────────┘                                                    └─────────────────────┘
```

Hot reload is already a network protocol. Flutter compiles on your machine and pushes kernel deltas to the device's VM Service. USB and local Wi‑Fi are only there because the tool needs to *reach* the phone. rhr fixes reachability: the phone dials **out** to a relay (works through NAT and firewalls), the two ends exchange a WebRTC handshake over it, and all tunnel traffic then rides a **direct WebRTC data channel** between your machine and the phone — not through the relay, not through TURN. Reload, restart, breakpoints, DevTools — all of it. Your source stays on your machine; only compiled kernel bytes go over the wire.

The relay carries signaling and small control messages only. It closes any binary frame — it has no way to see, slow, or stop a session once the data channel is up.

> **Android only, on purpose.** iOS is technically doable via sideloaded JIT, but every UDID has to be in a provisioning profile (free ones expire in 7 days), you need a Mac to build, and the JIT path breaks with every iOS release. That's a maintenance treadmill — the opposite of "set up once and forget."

## Two ways to run your code

`rhr run` picks the route automatically; force one with `--mode player|app`:

- **player mode** — the generic player hosts your project. rhr builds a bundle, streams Dart kernel + assets into the player over the data channel, and boots your app inside it. Zero project integration: no dependency, no code changes.
- **app mode** — for projects the generic player can't host (custom Android code, plugin-version drift). rhr installs a debug build of *your own app* on the phone — one install sheet you confirm — and tunnels its VM the same way. Newer Dart-only changes still hot-reload into it without reinstalling.

## Quick start

**1. Install the player.** Grab the arm64 APK from [Releases](https://github.com/therealsuji/rhr/releases) and sideload it. Must be a **debug** build — hot reload needs the Dart VM Service (JIT), which release builds don't have.

The player targets Android `arm64-v8a`, Flutter 3.44.2 stable (Dart 3.12.2, engine `77e2e94772b6eb43759e34ed1ad7da4674e19cab`). The CLI checks framework, engine, Dart, Android plugins, and permissions before streaming. Each release ships `FLUTTER_VERSION.json` and `RELEASE_MANIFEST.txt`.

**2. Introduce the phone to your account (once).**

```bash
rhr invite
```

Scan the QR with the player. The phone joins your account as a *device*: no sign-up, no password on the phone — it holds a membership, not an identity. `rhr devices` lists it. From then on the phone waits for your account's computers; `rhr run` finds it without QRs or codes, wherever it is. Disconnect on the phone goes back to waiting, and reconnecting never needs the QR again. Either side can end the membership.

Works without an account too: a plain session code and QR is still the setup path (for a LAN with no account service, or a phone nobody wants joined to anything). `rhr run` without an account prints its QR and guides you through it.

**3. Install the CLI once.**

```bash
dart pub global activate --source git \
  https://github.com/therealsuji/rhr.git \
  --git-path cli \
  --git-ref v0.1.0-beta.26

~/.pub-cache/bin/rhr setup
```

Run `rhr setup` once, from a terminal where `flutter` works. It writes `/usr/local/bin/rhr` (asking for sudo), a small launcher that carries this terminal's Flutter, Java and Android SDK, and registers the `rhr` Flutter device and the `rhr mcp` server with Claude Code, Codex and OpenCode. After that `rhr` works from any shell, including SSH commands and coding agents, which read no shell config. `rhr doctor` checks all of it. On Windows, add `%LOCALAPPDATA%\Pub\Cache\bin` to `PATH` instead.

If this machine will use account devices, `rhr login` signs in once (`rhr whoami` prints who you are).

**4. Run from your project.**

```bash
cd your-flutter-project
rhr run
```

That's the whole session: pair, compatibility check, prepare, install or boot, run. Then `r` to reload, `R` to restart, `q` to quit. The phone shows the route it took.

Android may still ask you to confirm an installation on the phone. With `rhr mcp`, your coding agent can see and answer those prompts while the app is prepared — the session text tells it what's on screen.

The CLI re-pairs with the phone when it comes back — crash, force-stop, player relaunch, network change: the phone re-announces itself, the session re-dials, and your asset cache skips everything you didn't touch. What doesn't survive today is Dart heap on a Wi‑Fi ↔ cellular switch: recovery takes ~70–80 s and app state is lost. Know that before you demo it.

`--resync` blows away the device-side asset cache and re-uploads everything. `q` leaves the VM running on the phone, so the next run reconnects without reinstalling.

### Session selection

For `rhr run` and `rhr attach`: `--device <id>` first, else `--code <session>`, else `code:` in `.rhr.yaml`, then a saved recent code or a fresh one. Passing both `--device` and `--code` is refused rather than one quietly winning. A session code is bearer credential for the phone's debug VM — treat it like a password.

## Relay

The player defaults to the public relay (`wss://getrhr.dev`). It carries only signaling, presence, and small control frames — never tunnel payload. For real work you can run the same Cloudflare Worker yourself; session codes and then-current traffic stay on infrastructure you control:

```bash
cd relay-worker && pnpm install && pnpm run deploy
# → wss://rhr-relay.<account>.workers.dev
```

Pass `--relay` to the CLI, or bake it in with `--relay` / `.rhr.yaml` (`relay:`). The Dart relay in [`relay/`](relay/) is for dev and single-server self-hosting — put it behind a TLS reverse proxy before exposing it. Deployment notes: [`relay/README.md`](relay/README.md).

### Same-network LAN

Phone and computer on the same Wi‑Fi? `rhr run` still spins up a temporary LAN relay embedded in the QR, races it against the internet path, and tells you which won. No flags, no network config. The LAN listener only lives for the session and uses the same bearer code and tunnel protocol as the public one.

### USB asset fast path

When the phone is on USB, `rhr run` sends the initial bundle and later deltas (`adb push`/`exec-in`) through the cable — SHA-256-verified in chunks, 16 MiB groups with independently retryable 4 MiB ranges for oversized files. The session, VM Service, and hot-reload traffic still go over the direct channel; a cable can't accidentally win your session. Lose USB mid-sync and it waits for adb; if that keeps failing, it falls back to wireless without you changing anything.

### Fine-grained under the hood

Asset uploads are content-addressed per installed player on your account — unchanged files stay in the phone's cache. `rhr run` prints raw/wire bytes, throughput, and compression time when you want to see where the time went.

## Measured

Samsung SM-A566B (Android 16, arm64), stock `flutter create` app:

| | |
|---|---|
| Hot reload | **1.6 s** (compile 132 ms, reload 513 ms, reassemble 443 ms) |
| Hot restart | 11 s warm, 19 s cold |
| Cold asset sync | 12 files, 53 MB, 10 s |
| Warm asset sync | 6 of 12 files skipped via manifest |

App state survives reloads — counter at 3 stayed at 3 after a reload that changed the widget tree.

**Mobile data.** Samsung S918B on cellular only, from a Linux machine: direct path came up, a 61.6 MB debug app installed over it, and hot reload took about **1.5 s**.

Velia benchmark (519 files, 421.3 MB raw), same phone. The relay and LAN rows are August measurements from before direct-first (payload then crossed the relay); the USB row is current:

| Asset route | Cold sync |
|---|---:|
| Public relay path | 173.4 s |
| Optimized LAN pipeline (350.1 MB wire) | 143.4 s |
| **USB fast path, forced adb reset (491.7 MB wire)** | **42.3 s** |

Fault-injected USB run recovered without falling back to wireless; independent inventory matched all 519 phone files to host SHA-256. Warm runs skip unchanged files — touch one generated asset and only that file uploads.

## Let a coding agent drive the phone

`rhr mcp` is an MCP server that lets an agent see and debug the app on your phone through your running `rhr run`: screenshots, the screen's element tree (Flutter, native views and system dialogs), taps, swipes, typing, system buttons, the app's native log, `evaluate`, and hot reload or restart with Flutter's output. Coordinates are fractions of the screen. `rhr setup` registers it in the user config of Claude Code, Codex and OpenCode, whichever are installed, so it is there in every project. Another MCP client can run `/usr/local/bin/rhr mcp` from the project directory.

Seeing and tapping need RHR Agent, a small accessibility add-on. Play Protect blocks browser installs of any APK with an accessibility service, so it's separate from the player, and the player installs it. The phone shows **Install RHR Agent** once: the player downloads the agent APK published alongside its own version, installs only if it is signed with the player's own key, and opens it so you can flip the accessibility switch once. It only answers the player signed with its own key, and only during a session. While it acts, the phone says so, and the session notification offers "Stop agent control". After a stop, every device request fails until you tap "Allow agent control" or connect again.

Logs, evaluate and hot reload work without it.

## Installing the CLI

Same as above, locked to the beta tag:

```bash
dart pub global activate --source git \
  https://github.com/therealsuji/rhr.git \
  --git-path cli \
  --git-ref v0.1.0-beta.26
~/.pub-cache/bin/rhr setup
```

`rhr update` moves to a newer release and verifies the tag's signature; run `rhr setup` again only after moving Flutter, Java or the Android SDK. `rhr doctor` checks that rhr runs from a bare shell, Flutter, and whether the USB asset fast path is available.

## Repo layout

- `player/` — generic Flutter shell + native Android session service
- `cli/` — `rhr run` / `rhr attach` / `rhr persist` / `rhr invite` / `rhr mcp`
- `relay-worker/` — Cloudflare Worker relay: rendezvous + signaling, one Durable Object per session/device
- `relay/` — single-instance Dart relay for dev/self-hosting (signaling only, same protocol)
- `bridge/` — device-side Dart package (app mode) + shared tunnel protocol

## Constraints

- **Android only.** Debug builds only (JIT) — release has no VM service, by design.
- Flutter framework, engine, and Dart SDK must match the player APK. `rhr` checks before streaming, with a small same-series tolerance.
- Every Android plugin and permission your project needs must be in whatever hosts it. In player mode `rhr` blocks and lists what's missing; in app mode it builds your own APK instead.
- Hot reload is fast; hot *restart* re-syncs the whole kernel.
- Network changes: the session detects them and re-dials, but that takes ~70–80 s and Dart heap state is lost.
- Direct WebRTC means there is no TURN server: if two ends can't reach each other (carrier-grade NAT being the usual suspect), the session fails with a clear message rather than degrading. `--no-direct`, which tries to put payload on the relay, only works against a *private relay that predates this rule* — current relays close binary frames (it exits with a clear error, not silent).
- Before shipping a player APK: `dart run tool/check_16kb.dart` from `player/` (16 KB page alignment).

## Security

A session code is a **bearer token** for the phone's VM Service — anyone who has it can reload, inspect, evaluate, and control the debug app. Treat codes like passwords. Don't use rhr with production data.

Account devices are harder to take over than codes: a computer reaches the phone only with a ticket the account service issues to members, which expires within minutes, and the phone waits on a rendezvous only its installation secret can join. A joined phone listens to your account's machines and to nobody else's.

The tunnel payload rides a DTLS-authenticated WebRTC channel. The relay is not in the data path: it cannot observe or intercept payload even if it wanted to.

The LAN path is unencrypted `ws://` on the local network. Compiled debug artifacts only, not source — still needs the random session code. Don't use it on untrusted networks.

With RHR Agent turned on, the session code (or your account) also lets your agent see the whole screen and tap anywhere on the phone, system dialogs included. That reaches past the app, so you can stop it from the session notification or turn RHR Agent off in Accessibility settings. The agent reads the phone's screen and logs, and they can show any app or web page. `rhr mcp` tells the agent to treat that text as data, but a prompt injection on screen is still text your agent reads. Keep the agent's other permissions narrow while it drives your phone.

Logs (yours and the relay's) don't record session codes, VM Service URIs, or frame contents. See [SECURITY.md](SECURITY.md) before reporting issues.

## Alternatives

**Bridge in your own app.** Skip the player — add `rhr_bridge` as a path dep, call `RhrBridge.start(relayUrl: …, sessionCode: …)` in `main()` under `kDebugMode`, then `rhr attach`. It's the same tunnel protocol with the device side living in your Dart code, which is the cost: hot *restart* runs `main()` again and kills the bridge until the app relaunches, and there's no native service to survive backgrounding. Best for a quick try from your own code, not the everyday flow.

**Project-specific player.** Unusual native deps? `rhr player build --project .` builds a matching player APK — pins your Android plugins, merges permissions, leaves app source alone. In most cases app mode above is the simpler answer; use this when you specifically need the rhr player as the process.

## Development

```bash
# End-to-end smoke test on the desktop, no device:
cd bridge && dart run --enable-vm-service=0 example/fake_device.dart ws://127.0.0.1:8123 rhr-test-2345-6789-abcd &
cd cli    && dart run bin/rhr.dart attach --relay ws://127.0.0.1:8123 --code rhr-test-2345-6789-abcd --no-flutter
```

(Start the relay first: `cd relay && dart run bin/relay.dart 8123`.)

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
