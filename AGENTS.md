# AGENTS.md

This file provides guidance to coding agents when working with code in this repository.

If a local `notes/` directory is present, check it for working notes.

## Project Overview

Remote hot reload for Flutter — "Expo Go for Flutter over the internet." A tester anywhere holds a phone running a debug Flutter app; the dev hot reloads from their machine in ~2 s with app state preserved. Works by tunneling the Dart VM Service protocol through a relay: the app dials out (no NAT/firewall issues), the dev's `flutter attach` connects to a localhost tunnel. No adb, no USB, no shared network.

See `README.md` for the full concept and the platform analysis (iOS is the hard part).

## Components

| Dir | What | Language |
|---|---|---|
| `relay-worker/` | Production relay — Cloudflare Worker + Durable Object per session (WebSocket Hibernation API) | TypeScript |
| `relay/` | Local-dev relay, same protocol, runs on a port | Dart |
| `bridge/` | Device-side package. Apps call `RhrBridge.start()` in `main()` under `kDebugMode`. Also exports `tunnel.dart` (shared mux protocol) | Dart |
| `cli/` | `rhr attach` — connects to relay, exposes tunneled VM service on localhost, wraps `flutter attach --debug-url` | Dart |

## Commands

```bash
# Relay worker (in relay-worker/)
pnpm install
pnpm run dev              # wrangler dev on port 8788 (NOT 8787 — workerd default collides)
pnpm run deploy           # deploy to Cloudflare
pnpm run typecheck        # tsc --noEmit
pnpm run check            # biome lint + format check

# Local Dart relay (in relay/)
dart run bin/relay.dart 8123   # NOT 8787/8788

# CLI — attach to a device session (run from the Flutter project dir)
dart run <this-repo>/cli/bin/rhr.dart attach \
  --relay wss://rhr-relay.<account>.workers.dev --code <session> \
  [--pid-file /tmp/rhr.pid] [--no-flutter]

# Desktop smoke test of the whole tunnel (no phone needed; in bridge/)
dart run --enable-vm-service=0 example/fake_device.dart ws://127.0.0.1:8123 <code>

# All Dart packages: dart analyze / dart pub get per directory
```

## Architecture

Tunnel protocol (`bridge/lib/tunnel.dart`, mirrored in both relays which never parse it):
- TEXT WebSocket frames = JSON control messages. Device→dev `{"t":"info","vm":"<uri>"}` announces the VM service URI; the relay caches the latest one and replays it to a late-joining dev, clearing it when the device disconnects.
- BINARY frames = multiplexed TCP: `[1B op][4B channel BE][payload]`, op 0=open 1=data 2=close. The dev CLI opens a channel per local TCP connection from the Flutter tool; the bridge answers each open with a TCP connection to the local VM service.

Session flow: bridge dials `wss://relay/s/<code>/device` (outbound, firewall-proof) → CLI dials `/s/<code>/dev`, gets the info message, binds a localhost listener, rewrites the VM URI to it, and spawns `flutter attach --debug-url`. Hot reload/restart/DevTools all ride the same tunnel.

App integration: add `rhr_bridge` as a path dep, call `RhrBridge.start(relayUrl: …, sessionCode: …)` in `main()` guarded by `kDebugMode`. Configurable via `--dart-define=RHR_RELAY=…` / `RHR_CODE=…`.

## Hard-won invariants (violating any of these cost a debugging session)

- **Buffer data frames racing a channel open.** The bridge connects to the VM service asynchronously; data frames arriving before the socket is ready must be buffered, not dropped (`_pending` in `rhr_bridge.dart`).
- **Handle `Socket.done` errors.** Peer resets during DevFS sync surface there and crash the process if unhandled (both CLI and bridge do `sock.done.catchError`).
- **Never mutate socket maps while iterating.** `destroy()` fires `onDone` handlers that remove entries — iterate a `.toList()` snapshot. A `ConcurrentModificationError` here permanently kills the bridge's reconnect loop.
- **The dev machine must have NO adb devices connected during `flutter attach`.** If any adb device is visible, the tool "helpfully" rewrites the debug-url through `adb forward` to that device and the attach fails with `Connection closed before full header`.
- **DO WebSocket messages cap at 1 MiB.** Tunnel frames are TCP-read-sized (≤64 KB) so this holds today; keep it true if the framing changes.
- **Durable Object in-memory state dies on hibernation.** Anything that must survive (the cached device info) lives in `ctx.storage`.
- **Android freezes backgrounded apps** — the bridge socket and its retry loop stop until the app is foregrounded again (reconnects within ~30 s of unfreeze). A tester actively using the app is unaffected.
- **Hot restart into a guest app kills the player's Dart bridge.** The bridge is code in the lobby kernel; the restart swaps in the guest's kernel and re-runs `main()`, so the tunnel's device end dies the moment a guest boots (and can't come back — guests are zero-integration by design). The player's bridge must move to the native layer (Kotlin service in the player APK), which DevFS kernel swaps can't touch. The pure-Dart bridge remains correct for bridge-in-your-own-app use.
- `flutter run` reinstalls the whole APK every session start (Gradle output is never byte-identical); the attach flow is the product for a reason. `adb tcpip 5555` does not survive phone reboots.

## Conventions

- Biome for TS (tabs, double quotes), `wrangler.jsonc` with schema line, pnpm scripts.
- Dart packages: `publish_to: none`, minimal deps (`web_socket_channel`, `shelf` only where needed). The bridge stays pure Dart (no Flutter dependency) so it can run in a desktop `dart run` for smoke tests.
- Port allocation on this machine: 8787 is taken by a workerd instance; the local relay uses 8123, `wrangler dev` uses 8788.
