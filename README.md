# rhr — Expo Go for Flutter, over the internet

Hot reload a Flutter app running on a phone **anywhere on the internet**, in ~2 seconds, with app state preserved. No adb, no USB, no shared network, no VPN on the tester's side.

Install one app on the tester's phone — the **rhr player** — and stream *any* of your Flutter projects into it. Nothing to install per project, nothing to rebuild and re-send when you change code. The tester holds the phone; you hot reload from your machine.

```
Dev machine                    Cloudflare (Durable Object)         Tester's phone
┌──────────────────┐           ┌──────────────────────┐           ┌─────────────────────┐
│ rhr attach       │◄──WSS────►│  RelaySession per    │◄───WSS────│ rhr player          │
│ └ flutter attach │           │  session code        │ (outbound)│ (generic shell app) │
│   --debug-url    │           └──────────────────────┘           │   └► Dart VM Service │
│   localhost:...  │                                              │      (debug build)  │
└──────────────────┘                                              └─────────────────────┘
```

Hot reload is already a network protocol — the Flutter tool compiles on your machine and pushes kernel deltas to the device's Dart VM Service over WebSocket. The only reason it normally needs USB or local Wi-Fi is *reachability*. rhr fixes reachability: the phone dials **out** to a relay (firewall/NAT-proof), and your `flutter attach` connects to a localhost tunnel. Reload, restart, breakpoints, and DevTools all work. Source never leaves your machine — only compiled kernel bytes travel.

> **Android only, deliberately.** Not because iOS is impossible — the sideloaded-JIT path (StikDebug/StikJIT) does work on iOS 17.4–26.3 — but because it can't be made *frictionless*: every tester's UDID must sit in a provisioning profile (free ones expire after 7 days), wireless VM-service attach is still unreliable, a Mac is required to produce the debug build, and the JIT path breaks and gets re-patched with each iOS release. That trades rhr's whole premise — hand a tester a phone, anywhere, and forget about it — for a maintenance treadmill. No comparable tool supports remote iOS either. The AOT "code push" path (Shorebird-style, restart-based) is a possible future track, not this tool.

## How it works: the player

The **rhr player** is a generic debug Flutter app — a shell. It boots to a lobby, takes a session code, and opens the tunnel from a native Android foreground service (so it survives the guest app's hot restarts and Android backgrounding). When you `rhr attach` from your project, the Flutter tool pushes your app's kernel and assets into the running player, and a hot restart boots *your* app in place of the lobby.

Because the tunnel lives in the player's native layer, your project needs **zero integration** — no dependency, no code change. Any debug-compatible Flutter project works.

## Quick start

### 1. Get the player onto the tester's phone

Download the latest `rhr-player.apk` from [**Releases**](../../releases) and sideload it (enable "install from unknown sources"). Or build it yourself:

```bash
cd player && flutter build apk --debug
# → build/app/outputs/flutter-apk/app-debug.apk
```

> The player must be a **debug** build — it needs the Dart VM Service (JIT) to accept hot reloads. Release builds have no VM service by design.

### 2. Pick a relay

The relay is the only always-on piece. Two options:

- **Instant trial — use the public relay.** The player ships pointed at
  `wss://rhr-relay.codeforge007.workers.dev`, so you can try rhr with zero
  setup. Pick a long, unique session code (it's the only thing separating your
  session from anyone else's on a shared relay).
- **Your own relay (recommended for real use).** Deploy your own in a minute.
  It runs on the Cloudflare **free tier** — Durable Objects are included,
  WebSocket traffic barely touches the request quota, so the realistic cost is
  **$0/mo**.

  ```bash
  cd relay-worker && pnpm install && pnpm run deploy
  # → https://rhr-relay.<account>.workers.dev
  ```

  Then either rebuild the player with your URL baked in
  (`flutter build apk --debug --dart-define=RHR_RELAY=wss://rhr-relay.<account>.workers.dev`)
  or pass `--relay` to the CLI (below) — the player discovers the relay from the session handshake.

### 3. Connect the phone

Open the player, type a session code (generated codes look like
`rhr-k7m3-p9qx-w2b4`), then tap **Connect**. The phone is now waiting.

### 4. Run from your project and iterate

```bash
cd your-flutter-project
dart run <path-to>/rhr/cli/bin/rhr.dart run
# scan the QR; the first launch is automatic
# type r to reload, R to restart, q to quit
```

Use `rhr run --resync` to deliberately ignore the local phone-asset manifest
and upload the complete bundle again.
`q` detaches the local Flutter tool but leaves the phone VM available, so a
later `rhr run --code <same-code>` can reconnect without reopening the player.

### Post-V1 prototype: development builds

The V1 product uses the generic player. A later Expo development-build-style
workflow is prototyped behind:

```bash
rhr player build --project .
# → build/rhr-player-debug.apk
# → build/rhr-player-debug.apk.profile.json
```

The generator works in an isolated temporary workspace, pins the project's
resolved Android plugins, merges its required permissions, and leaves the app
source and repository template untouched. Install/distribute the APK as a
separate deliberate step. Custom Android source/native libraries and Firebase
configuration are post-V1 concerns; this command is not part of V1 onboarding
or the normal `rhr run` flow.

`rhr run` builds an Android-target bundle and drives Flutter's supported attach
flow, so it can wait for the generic player's kernel and asset sync and then
launch the app automatically. This also supports packages with Dart
native-assets hooks without patching Flutter or changing the app project.
Subsequent reloads use Flutter's normal fast path. The older `rhr attach` and
Cursor/VS Code custom-device paths remain available for manual workflows.

The phone may remain connected over USB. `rhr` explicitly selects its relay
target, so Flutter does not mistake the cable for the attach transport.

## Installing the CLI

You can run the CLI straight from the repo (`dart run cli/bin/rhr.dart …`) or install it globally:

```bash
dart pub global activate --source git https://github.com/<you>/rhr --git-path cli
rhr run
```

## Bridge-in-your-own-app (alternative to the player)

If you'd rather not use the generic player, you can embed the tunnel directly in *your* debug app. This is the original mode — it needs a one-line integration but no separate player install.

```yaml
# your pubspec.yaml
dependencies:
  rhr_bridge:
    path: <path-to>/rhr/bridge
```

```dart
// main()
if (kDebugMode) {
  RhrBridge.start(
    relayUrl: const String.fromEnvironment('RHR_RELAY',
        defaultValue: 'wss://rhr-relay.<account>.workers.dev'),
    sessionCode: const String.fromEnvironment('RHR_CODE', defaultValue: 'mysession'),
  );
}
```

Build a debug APK, get it on the phone, then `rhr attach` (no `--sync-assets` — your assets ship in the APK). Note: a hot *restart* of your own app tears down the Dart-side bridge until the app relaunches; the player avoids this by living in the native layer.

## Repo layout

- `player/` — the **rhr player**: generic Flutter shell + native Android session service. This is the product.
- `relay-worker/` — production relay: Cloudflare Worker, one Durable Object per session, WebSocket Hibernation. TypeScript.
- `relay/` — the same protocol as a local Dart server, for development (`dart run bin/relay.dart 8123`).
- `bridge/` — device-side Dart package (`RhrBridge.start()`) for the bridge-in-your-own-app mode, plus the shared tunnel protocol (`lib/tunnel.dart`).
- `cli/` — `rhr run`: builds for Android, attaches Flutter through the relayed VM service, and syncs assets.

## Constraints to know

- **Android only** (see the note up top).
- Your machine's Flutter framework revision, engine revision, and Dart SDK must
  match the player APK. `rhr` checks these before streaming and tells you to
  rebuild the player when they differ.
- Every resolved Android platform plugin required by the target project must be
  covered by the player's tested capability set. For stable plugins, V1 accepts
  the same major version when the player version is at least the app's version;
  pre-1.0 plugins currently require an exact version. A player may advertise
  additional plugins.
- Every Android permission required by the app or its plugins must be declared
  by the installed player. Custom Android source/native libraries require a
  later development-build workflow; `rhr` blocks and lists these inputs before
  streaming. The mere presence of `google-services.json` does not block V1.
- Before distributing a player APK, run `dart run tool/check_16kb.dart` from
  `player/` to verify Android 16 KB ZIP and 64-bit ELF alignment.
- Hot reload is ~2 s; a hot *restart* re-syncs the full kernel. The reload loop is the fast path.
- Android freezes backgrounded apps: the tunnel drops and reconnects within ~30 s of the phone being foregrounded again. A tester actively using the app is unaffected.
- Debug builds only (JIT). Release builds have no VM service — that's a feature.
- On a **shared** (public) relay, the session code is your only isolation. Use a long, unguessable one, or self-host.

## Security

- A session code is a **bearer token**: anyone who knows it can attach to the
  relayed VM service, which is arbitrary code execution inside the tester's
  app. Treat codes like credentials — don't share them publicly, don't reuse
  a public-relay code for sensitive apps, and prefer your own relay for
  real work.
- The relay carries **compiled kernel bytes only** — your source never leaves
  your machine. It does not log session traffic.
- The phone must run a **debug** build for the VM service to exist at all;
  that's inherent to hot reload (JIT) and is why the player is debug-only.

## Development

```bash
# Desktop end-to-end smoke test, no phone required:
cd relay  && dart run bin/relay.dart 8123 &
cd bridge && dart run --enable-vm-service=0 example/fake_device.dart ws://127.0.0.1:8123 test &
cd cli    && dart run bin/rhr.dart attach --relay ws://127.0.0.1:8123 --code test --no-flutter
# curl / open DevTools against the printed tunneled URI
```

Checks before a release:

```bash
cd cli          && dart analyze && dart test        # 19 tests incl. session state machine
cd relay-worker && pnpm run typecheck && pnpm run check
cd player/android && ./gradlew :app:compileDebugKotlin
cd player       && dart analyze && dart run tool/check_16kb.dart
```

## License

MIT — see [LICENSE](LICENSE).
