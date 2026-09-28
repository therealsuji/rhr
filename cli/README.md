# rhr CLI

Run `rhr` from a Flutter project, then scan the QR or enter the printed code
in RHR Player. The phone connects first. The CLI checks the phone and chooses
whether to host the project in the player or run a separate debug app.

```bash
rhr                 # inspect, pair, and ask before required builds/installations
rhr run --yes       # approve required builds/installations, including from an agent
rhr --help          # available commands and options
```

If the project can run inside the player, their Flutter runtimes must match.
Native plugin or permission differences, custom Android sources, and plugins
from a local path or pub workspace select the separate-app route. That route uses the project's own Flutter runtime. The
player's Flutter version does not need to match it.

The separate app is built with a small RHR beacon that reports its debug
address to the player, so it needs no Wireless debugging, USB, or computer on
the phone's network. Complete any setup requested on the phone: permission to
show the session controls over other apps, and permission to install apps.
Android can still require confirmation for each installation. The CLI verifies
the installed APK, opens the target app, and attaches Flutter. Use `r` to
reload, `R` to restart, and `q` to quit.

A cached APK is reusable only while its native inputs and bytes still match.
Dart-only edits reuse it and reach the phone by hot restart. A native change
during a session (a new plugin, an edited Android source) ends the session with
a message and prepares the right build again, moving a hosted project to its own
app when it needs one. A recent session code is retained in
`.dart_tool/rhr/session.json`, so retries can reconnect without scanning again.
`--code` overrides that saved code.

Two explicit commands install a build and end:

```bash
rhr persist   # install a debug build of the current code, so the app keeps it
              # after it is killed and reopened (separate-app projects only)
rhr release   # build a release APK, with nothing of RHR in it, and install it
```

Both ask a running `rhr run` for the project to do the work, since it holds the
phone, or connect to the phone themselves when nothing is running. A release
build with the same package and signing key replaces the debug app; the next
`rhr run` puts the debug app back.

Use `--mode app` to require a separate app. `--mode player` rejects detected
native differences. Automatic native detection currently covers plugin versions,
permissions, and custom native sources. It does not establish compatibility for
arbitrary Gradle or manifest changes. Use `--mode app` for those projects.
The build currently uses `lib/main.dart`, the default debug variant, and arm64.

An existing app with a different signing key cannot be updated in place.
RHR reports the conflict without uninstalling the app or erasing its data.
GitHub player builds and local runtime updates need the same signing identity.
The CLI and the player are released together; update both to the same version.
`rhr attach` remains available for a project the player can host.

## Install the beta

From the repository's tagged release:

```bash
dart pub global activate --source git \
  https://github.com/therealsuji/rhr.git \
  --git-path cli \
  --git-ref v0.1.0-beta.9
```

Then run `rhr doctor` from a shell where the Dart global executable directory
is on `PATH`.

## Share a connection from an agent

`rhr run` prints a connection link, session code, and terminal QR for the same
session. On Android, open the link and tap **Open RHR**. It carries the relay
addresses as well as the code. Switching to another active session asks first.

Agents can read `.dart_tool/rhr/connection.json` in the Flutter project. Share
its `url` as a Markdown link and include `code` as a fallback. `deepLink` is the
direct `rhr://connect` URL for clients that permit custom schemes. `qrPayload`
contains the data encoded by the terminal QR. Treat this file as session access
information and do not commit it.

The HTTPS connection page is `/connect` on `getrhr.dev`. It reads the session
from the URL fragment in the browser and passes it to RHR; it does not send that
fragment to the server. This is a browser handoff, not a verified Android App
Link. A player containing the session deep-link handler is required.

## Update the CLI

```bash
rhr update --check   # report whether a newer release is available
rhr update           # install the newest published release, including betas
```

The update command activates the release's Git tag through Dart. It needs Dart,
Git, and access to GitHub and the package registry. It does not downgrade a newer
CLI. The next global `rhr` invocation uses the update; `rhr --version` verifies
which version your PATH selects. Running this command from a source checkout
updates the global installation, not the checkout.

Older CLI releases without `update` need one manual activation using the
installation command above and the desired release tag. After installing a
release containing this command, subsequent updates use `rhr update`.

## Development

```bash
dart pub get
dart analyze
dart test
dart run bin/rhr.dart --help
```

The package is intentionally kept as a Git-installed beta while the shared
bridge and vendored WebRTC transport settle. The supported hosted relay is a
convenience for development, not a production security boundary.
