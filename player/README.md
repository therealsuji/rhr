# rhr player

The generic Flutter shell for [rhr](../README.md) — "Expo Go for Flutter." Install
this one debug app on a tester's phone and stream *any* of your Flutter projects
into it over the internet. No per-project install, no code change in your app.

It boots to a lobby, takes a session code, and opens the tunnel from a **native
Android foreground service** (`RhrSessionService`). The service owns the tunnel
because it must outlive the guest app's hot restarts (which swap the entire Dart
kernel) and survive Android freezing a backgrounded app.

## Build

```bash
flutter build apk --debug
# → build/app/outputs/flutter-apk/app-debug.apk
```

Must be a **debug** build: it needs the Dart VM Service (JIT) to accept hot
reloads. Release builds have no VM service.

Point it at your own relay by baking the URL in at build time:

```bash
flutter build apk --debug --dart-define=RHR_RELAY=wss://rhr-relay.<account>.workers.dev
```

Without the define it uses the default relay in `lib/main.dart`.

## How a session runs

1. Tester opens the player, enters a session code, taps **Connect**.
2. Dev runs `rhr attach --sync-assets --code <same-code>` from their project.
3. The kernel and assets sync into the player; a hot restart boots the guest app
   in place of the lobby. Reload from the dev machine as usual (~2 s).

See the [top-level README](../README.md) for the full flow.
