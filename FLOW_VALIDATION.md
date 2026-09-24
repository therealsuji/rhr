# Connection-first RHR validation

Validated locally on September 21–22, 2026, using a Samsung SM-A566B on
Android 16. This records observed behavior, not a release approval.

## Implemented flow

`rhr` connects the phone before selecting a target VM or building an artifact.
It chooses hosted or separate-app mode, waits for required phone setup, obtains
build/install approval, prepares the artifact, and verifies the running project
before reporting Ready. `rhr run --yes` supplies approval for an agent; Android
permission and installation confirmations remain on the phone.

Hosted mode checks the player's Flutter runtime. Separate-app mode checks the
target APK and does not require the player's Flutter version to match.

The implementation also saves the session code, validates cached APK inputs and
bytes, checks signing identities before transfer, and reconnects after player
replacement. An installation request is no longer reported as a completed
installation. Preparation failures release the prior transport so a retry can
connect immediately.

## Device evidence

Tests used the separate package `dev.rhr.rhr_player.qa` and an owned Flutter
fixture, `dev.rhrqa.flow_guest`. The original installed player and its data were
preserved. USB supported UI control and inspection; target APK deliveries and
Flutter attachment used RHR's WebRTC path through a local development relay.
The initial QA player was bootstrapped locally.

| Case | Observed result |
| --- | --- |
| Compatible hosted project | Code entry connected; project became visible; VM root identified the guest project. |
| Hosted hot reload | Visible label changed while Count: 2 survived; one reload took 1,004 ms. |
| Missing connector setup | CLI waited before building while Wireless debugging was off; pairing and overlay setup completed through Android UI without losing the session. |
| Missing separate app | APK transferred through RHR; Android installation confirmation led to automatic launch and attachment. |
| Installation declined | CLI exited 78, no app installed, no repeated installer prompt. |
| Retry after declined installation | Same code and cached APK reused without scanning or rebuilding. |
| Correct app already installed | App reused and brought to the foreground automatically. |
| Separate-app Flutter mismatch | Player 3.44.0 controlled the 3.44.2 app without rebuilding or updating the player. |
| Hot reload compilation error | Existing UI and Count: 2 survived; correcting the error allowed another successful reload. |
| QA player process loss | Force-stop and reopen reconnected automatically; separate app retained Count: 2. |
| Custom Kotlin source | Automatic selection chose separate-app mode, rebuilt and delivered the APK, then reopened it after confirmation. |
| Interrupted transfer | No partial app installed; retry reused the artifact. Transfer acknowledgment stalls now trigger bounded retries. |
| Signing conflict | CLI rejected a replacement for the original player before transfer; no uninstall or data clearing. |
| Hosted update approval declined | Answering no exited 78 before build or installation. |
| Hosted Flutter mismatch | Built a compatible QA player, recovered from connection loss using the cache, delivered the update, and displayed Android's update confirmation. |
| Player replacement | After confirming and reopening RHR QA, the saved session resumed without another code; the 3.44.2 project ran inside the updated player. |
| Preparation failure followed by retry | Forced incompatible hosted mode failed clearly; immediate retry connected and reused the running hosted app without restart. |

Local evidence is under `/tmp/rhr-flow-review/` on the validation Mac:

- `hosted-reload.png`, `app-reload.png`, `hosted-after-player-update.png`
- `app-retry.log`, `app-reconnect.log`, `app-auto-native-final.log`
- `signing-conflict.log`, `hosted-update-decline.log`, `hosted-update.log`
- `preparation-failure-cleanup.log`, `preparation-retry.log`

These logs are temporary and may contain session details. They are not committed.

## Automated verification

- CLI: `dart analyze` clean; 108 tests passed.
- Player: 21 Flutter tests passed; debug arm64 APK built successfully.
- Android: 14 `SessionBannerTest` tests passed.
- `git diff --check` passed.

Focused regressions cover the relay announcement cache, relay-close/send race,
APK cache invalidation, install cancellation after commit, project VM identity,
route selection, setup gating, and character-by-character full-code entry.
The final native change preserving a failure banner after developer departure
compiled successfully but was not installed for a separate device retest.

## Remaining release gates and limits

1. **Signing continuity is unresolved.** The existing GitHub-installed player
   and local debug builds have different signing identities. Successful QA
   self-update used the same signing key on both versions. It does not prove
   that a GitHub player accepts local runtime updates. Decide the distribution
   and signing approach before calling that experience complete.
2. **Old players need a bootstrap update.** Players without the preparation
   protocol receive an actionable error. They cannot use the new run flow
   until a compatible player is installed.
3. **Native compatibility detection is incomplete.** Automatic selection covers
   plugin versions, permissions, and custom native sources. It cannot establish
   compatibility for arbitrary Gradle/manifest changes or edited plugin source
   with an unchanged version. Such projects must use `--mode app` for now.
4. **Build scope is narrow.** The flow targets arm64 Android, `lib/main.dart`,
   and the default debug variant. Flavor/entrypoint selection is not implemented.
   Rerun after native or SDK changes; those changes are not continuously watched.
5. **Some paths remain unobserved.** Physical camera QR scanning, a remote
   internet/NAT deployment, storage exhaustion, camera denial, wrong-phone
   handling, corrupted transfers, and target startup crashes were not exercised
   on this phone. Code entry and a local relay with WebRTC were exercised.
6. **Agent interaction is terminal-based.** Help and `--yes` are available;
   a structured session/status/approval API is not implemented.

No production service or release was changed.

## Session-link follow-up, September 22

The CLI and player changes are local and are not in beta.9. The CLI prints a web connection
link alongside its code and QR, and writes machine-readable connection details
to `.dart_tool/rhr/connection.json`. The web page hands off to
`rhr://connect`; it is not a verified Android App Link.

Observed on the Samsung with the QA package:

- A cold-start session deep link took precedence over the previously saved
  session, connected to the CLI, and launched the hosted test app.
- The connection page opened in Samsung Internet. Tapping Open RHR and choosing
  RHR QA launched the player and connected successfully.
- Opening a link while a hosted guest was running initially stalled because
  the guest had no lobby channel handler. The native acknowledgment timeout now
  offers to reopen RHR. Stay here preserved the guest; Open RHR restarted into
  the lobby and resumed the requested connection.
- An already-open lobby asked before switching to a different session.
- The browser page rejected an invalid URL instead of exposing an Open button.

The installed T3 Code desktop bundle filters custom URL schemes in its Markdown
renderer. The HTTPS wrapper addresses that constraint, but an actual tap from
the phone's T3 chat has not been observed. The page was tested on a local Worker;
USB forwarding carried only the page request. RHR connections used the LAN
relay and WebRTC. Original player data was preserved.

Checks: CLI 115 tests passed, player 22 tests passed, shared-link round-trip and
invalid-input tests passed, Android QA APK built, Worker typecheck/lint and
deployment dry run passed.

With user approval, GET https://getrhr.dev/connect was deployed to `rhr-relay`
as version `f78c29bc-884c-46f6-90dd-18dbaf0d847a`. The live page returned HTTP
200 with the expected security headers; the browser displayed the session code
and correct Open RHR deep link for a test URL. The relay's `/healthz` returned
HTTP 200 and `ok`. The CLI and player still need a new release.


## Live public-relay retest, September 22

Tested the Samsung QA player against `wss://getrhr.dev`. The phone received
only the public relay URL. CLI logs confirmed selection of the internet
transport, and phone logs confirmed dialing getrhr.dev. Payloads used direct
WebRTC. USB was used for UI observation and link delivery; Flutter used an
isolated empty ADB server. Both devices were still on the same network, so
this does not establish cellular or cross-NAT reliability.

- Hosted startup passed. Hot reload changed the visible label to LIVE RELAY
  VERIFIED while preserving Count: 1.
- CLI restart reused the pairing and found the phone without another link.
  Full recovery failed during the subsequent asset sync/hot restart. Android
  reported `data channel rejected a payload`; Flutter reported `Lost connection
  to device`. RHR then printed that the project was running and exited instead
  of recovering. This is an outstanding defect, not a reconnect pass.
- Separate-app mode correctly gated on disabled Wireless debugging. Enabling
  it through phone setup resumed the build automatically. The APK transferred,
  Android installation was confirmed, and the separate app opened. Play Protect
  also required an installer choice for this test APK.
- Separate-app hot reload changed the label to LIVE CONNECTOR VERIFIED in
  757 ms while preserving Count: 1. That CLI session was left running.

Evidence: `/tmp/rhr-live-hosted.log`, `/tmp/rhr-live-reconnect.log`,
`/tmp/rhr-live-connector.log`, and `/tmp/rhr-live-device.log`.
Player self-update and different-network operation were not repeated in this run.


## Reconnect correction, September 22

Flutter can print `Lost connection to device.` and exit with code zero. The CLI
previously inherited its output and treated that exit as an intentional quit.
It now forwards and observes Flutter output, reconnects on that verdict, and
preserves interactive keyboard input across attempts. Preparation prompts share
the same input stream. Terminal modes are restored on exit, and termination
signals stop the attach child. The inner asset-sync success message was removed
so only the active session can report Ready.

Device-reported direct failures and ICE failure now use the existing bounded
retry path even after a channel was established. Protocol violations remain
fatal. Native rejected-send diagnostics include frame size, buffered bytes,
and data-channel state. The original low-level send rejection did not recur;
its specific cause remains unconfirmed.

Verified on Samsung QA using only the public relay URL on the phone:

- CLI stop/restart reused the session without a new link and reached Ready.
- Keyboard hot restart succeeded in 20.797 seconds. Normal `q` exited zero
  without starting a reconnect loop.
- The existing relay-loss fault recovered automatically.
- Added QA `tunnel-loss` closes live tunnel sockets while retaining signaling.
  Flutter printed Lost connection; the CLI retried and reached Ready.
- Added QA `direct-loss` exercises the device's direct-failure reporting path.
  The CLI reported the failure, retried, and reached Ready.
- After both faults, keyboard hot reload changed the visible text to LIVE
  RECONNECT VERIFIED in 717 ms, preserving Count: 1. Session left running.

CLI analysis passed and all 117 tests passed, including split-output detection
and normal-quit coverage. The updated Android QA APK built and was installed.
Evidence: `/tmp/rhr-reconnect-restart.log`, `/tmp/rhr-reconnect-faults.log`,
`/tmp/rhr-reconnect-device-final.log`, and
`/tmp/rhr-reconnect-cli-tests-final.log`. Changes are local and unreleased.


## Additional lifecycle scenarios, September 22

Hosted QA player on Samsung, paired only to getrhr.dev:

- Force-stop player, reopen from launcher without a link: restored saved
  pairing, relaunched the project, then accepted a visible hot reload.
  Counter reset from 1 to 0 because the app process was killed.
- SIGKILL the CLI, restart it with the saved session: reached Ready without
  rescanning. The old attach child did not remain running.
- Home/background for 30 seconds, return to player: app remained available;
  a fresh visible hot reload passed.
- Repeated real QA transport faults reached Ready automatically: relay-loss
  48.2 seconds, tunnel-loss 18.1 seconds, direct-loss 27.1 seconds. The relay
  test resent a changed asset and hot restarted; the other two skipped restart.
  A fresh visible hot reload passed after the fault sequence.
- Normal q quit exited. With CLI stopped, reopening the player showed Waiting
  for your developer.
- Disconnect/reset in the lobby, force-stop and reopen: stayed unpaired.
  Restarting the CLI and opening the same session link restored the project.
  Final visible hot reload to DISCONNECT REJOIN PASSED took 1,286 ms.

No new failure observed in this batch. The final session was left running.
This does not cover killing a separate connector target, cellular switching,
phone reboot, or hours of Android background suspension.
Evidence: /tmp/rhr-scenarios.log, /tmp/rhr-scenarios-final.log,
/tmp/rhr-scenarios-device.log, and the continued /tmp/rhr-reconnect-faults.log.

## Reload feedback, September 22

Tested the updated QA player on Samsung RFCY80LPLEJ in hosted mode through
the live wss://getrhr.dev session. Flutter output now drives reload and restart
progress, completion, and failure messages. Native screenshots confirmed:

- CLI hot reload shows Reloading, then App updated, then hides the card.
- CLI hot restart shows Restarting your app and completed in 20,769 ms.
- An intentional fixture compile error shows Could not update the app.
- Restoring the fixture and reloading succeeds in 769 ms and clears the error.

All 118 CLI tests pass and dart analyze reports no issues. The QA APK built
and installed successfully. The native SessionBannerTest suite also passes.
Screenshots are /tmp/rhr-feedback-reloading.png,
/tmp/rhr-feedback-restarting.png, /tmp/rhr-feedback-failure.png,
/tmp/rhr-feedback-success.png, and /tmp/rhr-feedback-cleared.png.
CLI evidence is /tmp/rhr-feedback.log. Accessibility text probes missed the
native card; screenshots were used to verify its actual visibility.

One restart attempt lost its direct connection and automatically reattached;
the subsequent restart completed. The connection interruption remains a
separate unresolved observation. Player-button feedback and duplicate-tap
protection still need a physical sheet interaction. Connector-mode feedback
has not been retested. These changes are local and unreleased.

### Player button follow-up

The first physical tap exposed a stale timeout flag: a new restart immediately
displayed the taking-a-while message. Resetting phaseStalled when fresh progress
arrives fixes the stale state. The QA APK was rebuilt and installed.

On the live getrhr.dev session, two taps about 194 ms apart produced exactly
one CLI restart request. The normal Restarting your app banner appeared
immediately. Reopening the sheet during the operation showed no Restart row.
Flutter completed the restart in 14,707 ms, and the progress card disappeared.
This completes the pending hosted player-button interaction check.

Evidence: /tmp/rhr-player-button-start.png captures the initial stale message;
/tmp/rhr-player-button-start-fixed.png and /tmp/rhr-player-button-done.png
capture the fixed run. /tmp/rhr-feedback.log records the single request and
completion. An earlier connection interruption prevented the first request
from reaching the CLI; the session recovered without rescanning before this
successful test. Connector mode remains untested for this feedback change.

## Connector feedback and lifecycle retest, September 22

Ran --mode app against wss://getrhr.dev on the same Samsung. Android confirmed
dev.rhrqa.flow_guest as the foreground activity, separate from the QA player.
APK delivery used RHR, and Android Update and Play Protect prompts were
completed for the local QA fixture. No production service was changed.

| Check | Observed result |
| --- | --- |
| Build, transfer, install, open, attach | Passed; app build 10.9 s, 71.9 MB compressed to 39.1 MB for transfer. |
| CLI hot reload | Passed in 1,009 ms; visible label changed and Count: 1 survived. |
| CLI hot restart | Passed in 13,071 ms; counter reset. |
| Compile error and recovery | CLI reported the error; restoring the fixture and using the player restart recovered. |
| Player Restart, double tap | One request for two taps 183 ms apart; restart completed in 15,616 ms. |
| Phone feedback | FAILED: no progress, completion, or failure card in the separate app. The sheet still showed connected after a compile failure. Native logs confirm receipt of the progress messages. |
| Kill target after Dart changes | Recovered via updated APK installation, then attached. |
| Kill unchanged target | Reused installed app and reopened it; an ICE failure required another automatic attempt before Ready. |
| Relay loss | Recovered without a scan and preserved Count: 1; subsequent reload passed in 738 ms. |
| Home and return | Counter preserved; reload passed in 606 ms. |
| Force-stop QA player and reopen | Separate app kept running; restored pairing and attachment preserved Count: 1. |
| Quit CLI and start again | Reattached without scanning; final reload passed in 696 ms with Count: 1. |

Feedback failure is explained by DevOverlay.showCard returning immediately
for SystemOverlayHost. The sheet displays connection status and session only,
despite the comment claiming it presents operation progress. This retest did
not change that behavior. Intermittent ICE failures remain unresolved.

Evidence: /tmp/rhr-connector-feedback.log,
/tmp/rhr-connector-feedback-resume.log,
/tmp/rhr-connector-feedback-device.log, and screenshots
/tmp/rhr-connector-reload.png, /tmp/rhr-connector-restart.png,
/tmp/rhr-connector-failure.png, /tmp/rhr-connector-button.png.
The final connector session remains running. This does not prove cellular,
cross-NAT, phone reboot, long suspension, or mismatched Flutter versions.

## Connector fixes and unattended verification, September 22

The missing feedback and observed stale-peer reconnect failures above are now
fixed locally. The QA player displays progress and errors over the separate
app in a window that passes touches through. The open sheet updates its
operation message too. A debuggable-build DEBUG_MENU broadcast opens the real
sheet, so these checks no longer require a physical shake.

Each RelayRace sends a stable connectionId in its repeated hellos. A fresh
attempt gets a new ID, causing the phone to replace the previous WebRTC peer
instead of waiting for its ICE failure. Logs from the failed pre-fix runs
showed new hellos with no fresh offer followed by the old peer failing.

A hard CLI kill exposed a second issue: the new process lost its relay claim,
and the refused live candidate was hidden by an empty local candidate. Claims
now survive process death in a relay-and-session-bound project cache with
0600 permissions. Normal release removes the cache. A refused relay now
reports DeviceBusyException instead of silently waiting on another candidate.

Verified on Samsung RFCY80LPLEJ, separate app dev.rhrqa.flow_guest, through
wss://getrhr.dev with direct WebRTC payloads:

- Player Restart showed feedback immediately and completed in 14,084 ms.
  Two taps produced one request; reopening the sheet during restart showed
  progress and no Restart action.
- A real compile error appeared in both the card and sheet. Restoring the
  fixture and reloading cleared the error and showed App updated, then hid it.
- A temporary button underneath the card received a tap and changed Count: 0
  to Count: 1. The normal fixture was restored afterward.
- Five consecutive target force-stops reused the installed app and reached
  Ready in 21.0, 27.5, 25.1, 26.6, and 28.5 seconds. No ICE failure, build,
  installation prompt, or rescan occurred in those five runs.
- After adding persistent claims, SIGKILL of the CLI followed by a fresh CLI
  process restored the session without scanning and preserved Count: 1.
- A final relay-loss injection recovered, then hot reload passed in 542 ms.
- All 121 CLI tests passed, including connection identity, claim persistence,
  relay binding, release cleanup, and refusal with an empty local candidate.
  CLI analysis and native SessionBannerTest passed; the QA APK built and was
  installed. The original player package was not replaced.

Evidence: /tmp/rhr-connector-fixed.log,
/tmp/rhr-connector-recovery-results.json,
/tmp/rhr-connector-claim-live.log, /tmp/rhr-connector-claim-resume.log,
/tmp/rhr-connector-final-device.log, /tmp/rhr-connector-final-tests.log,
/tmp/rhr-connector-native-tests.log. Screenshots:
/tmp/rhr-connector-fixed-restart.png, /tmp/rhr-connector-fixed-error.png,
/tmp/rhr-connector-fixed-reloading.png, /tmp/rhr-connector-fixed-complete.png.
The first recovery polling script mixed byte offsets and decoded text offsets;
its timeout was a test-script error. The corrected script used byte offsets
and produced the five results above.

The connector session is left running. These changes are unreleased. This
fix addresses the observed stale-peer and lost-claim failures, not every
possible network failure; cellular, phone reboot, and long suspension remain
outside this verification.


## Return verification, September 22

This pass tested the existing local changes on Samsung RFCY80LPLEJ through
wss://getrhr.dev. USB provided device control and observation, not RHR payload
transport. No product code was changed during this pass. These results qualify
the earlier successful checks; the complete flow is not yet reliable.

Observed failures:

- The previously running connector session had exited with "device did not
  offer a direct WebRTC payload path" after being left running. Device logs
  contain repeated reconnects. This is an observed longevity failure, not a
  controlled hours-long background test.
- Hosted startup needed two failed direct-transport attempts before succeeding.
- Progress text repeats in the lobby. Switching from connector to hosted mode
  also left the connector system overlay alongside the activity overlay,
  producing two native cards. Duplicate cards also appeared when returning
  from a Wi-Fi outage to connector setup.
- During phone reboot, the hosted CLI exhausted its retries and exited with
  TURN-server guidance. Reboot is not evidence that this network needs TURN.
  Automatic recovery of that existing CLI failed.

Hosted operations after startup succeeded: a visible hot reload took 720 ms
and preserved Count: 1; CLI hot restart took 15,846 ms; the player Restart
button took 19,141 ms and two taps produced one request. A deliberate compile
error appeared, and restoring the fixture allowed a reload in 785 ms. The
operations passed, but duplicate feedback failed the UI check.

After reboot and unlock, the player retained its session code. A fresh
connector CLI connected without scanning and correctly requested enabling
Wireless debugging, which Android had switched off. Using the phone's setup
flow restored the existing pairing, reused the installed app, and reached
Ready. A subsequent reload completed in 651 ms.

A Wi-Fi off/on test also disabled Wireless debugging. The CLI remained running
and reconnected to getrhr.dev. After returning to RHR and enabling Wireless
debugging through its setup flow, it reused the installed app and reached
Ready without pairing or scanning again. This required manual setup recovery;
it was not a seamless network-switch pass. The phone has no SIM, so cellular
and cross-network tests were unavailable.

A separate fixture pinned to Flutter 3.35.7 was built, transferred, installed
through Android's installer and Play Protect prompt, and launched via RHR.
The player remained on Flutter 3.44.2. The tunneled app VM reported Dart 3.9.2.
No player replacement was requested. A visible hot reload preserved Count: 1
but took 61,795 ms. A second visible change preserved the same count and took
987 ms. Cross-version connector operation is proven for this pair, with an
unexplained first-reload delay that still needs diagnosis. Hot restart then
completed in 18,699 ms.

Evidence: /tmp/rhr-return-cli.log, /tmp/rhr-return-device.log,
/tmp/rhr-final-hosted.log, /tmp/rhr-post-reboot-connector.log,
/tmp/rhr-mismatch-live.log, /tmp/rhr-mismatch-vm.json,
/tmp/rhr-return-verification-device.log. Screenshots include
/tmp/rhr-hosted-retest-error.png, /tmp/rhr-duplicate-progress.png,
/tmp/rhr-reboot-current.png, /tmp/rhr-wifi-return.png,
/tmp/rhr-mismatch-launch.png, /tmp/rhr-mismatch-second-reload.png.

A real GitHub release update containing these local changes remains untested
because the changes are unreleased. Controlled long suspension and cellular
coverage remain unverified. No release or production deployment was performed.


## Recovery fixes and device verification, September 23

Changes remain local and unreleased. The Samsung QA package was rebuilt and
installed, with getrhr.dev selected for every live session. Binary payloads
still use direct WebRTC. USB was used for installation and device observation.

Fixed mechanisms:

- Missing offers and send timeouts are recoverable. Temporary transport
  failures no longer exhaust a three-attempt limit. `rhr run` keeps waiting
  for an absent phone after its initial five-minute wait. Failed attempts
  clean up transports and signal listeners. Invalid signaling remains fatal.
- Device info arriving after an offer no longer starts an offer timeout on
  an already negotiated connection. The direct transport test exercises this
  ordering and confirms subsequent payload sends still work.
- Activity and system overlays have separate foreground ownership. The
  system overlay stops when switching back to the hosted VM. Detached
  overlays ignore queued redraws. Progress appears once, including inside
  an open menu. Restart reappears when an operation ends while the menu
  remains open. Lobby connection summaries no longer repeat operation text.
- Incoming tunnel bytes now share the lock used to flush the pending buffer
  and publish a newly connected socket. Previously data could be acknowledged
  while falling between those steps. This is a concrete data-loss race;
  attributing the earlier 61.8-second stall specifically to it remains an
  inference, since that run did not capture individual channel frames.
- A live install test exposed another failure: confirming an old mismatch_guest
  installation completed the active flow_guest transfer. Installer callbacks
  now match the Android session ID, and a replacement transfer abandons this
  installer's unfinished sessions. The physical retry showed the correct
  flow_guest prompt, installed it, and reached Ready.

Verified results:

- Four consecutive forced direct-transport failures recovered in 34.3, 26.2,
  26.2, and 35.3 seconds. The same CLI stayed alive beyond the old retry cap,
  reused the installed app, and needed no rescan or rebuild.
- Connector Restart completed in 12,281 ms and visible reload in 780 ms.
- Hosted startup succeeded on its first attempt. Startup restart took
  9,789 ms; visible reload took 841 ms and preserved Count: 1. The player
  Restart button completed in 13,015 ms.
- Flutter 3.35.7 connector app with the Flutter 3.44.2 player reported Dart
  3.9.2 from its tunneled VM. Its first visible reload took 1,175 ms and its
  second took 1,094 ms, both preserving Count: 1. The 61.8-second stall did
  not recur in those checks. CLI restart took 15,910 ms; player Restart took
  27,192 ms.
- The open connector menu showed one restart message and hid Restart while
  busy, then restored the action without closing the menu.
- Replacing the QA player while the CLI remained running recovered to Ready.
- Switching from the separate app back to hosted mode on the same player
  process reached Ready. Android's service listing showed no OverlayService;
  the screenshot showed one native progress card. Startup restart took
  17,485 ms.
- All 121 CLI tests, all 22 Flutter player tests, CLI/player analysis, native
  unit tests, APK builds, and git diff --check passed. Later menu-only edits
  were rebuilt and exercised on the phone; the native unit suite predates
  those final menu lifecycle edits.

Evidence: /tmp/rhr-fixed-final-live2.log,
/tmp/rhr-fixed-final-recovery-cycles.json, /tmp/rhr-fixed-hosted-live.log,
/tmp/rhr-fixed-mismatch-live.log, /tmp/rhr-fixed-mismatch-vm.json,
/tmp/rhr-fixed-mode-switch.log, /tmp/rhr-recovery-final-cli-tests.log,
/tmp/rhr-recovery-player-tests.log, /tmp/rhr-final-native-tests.log,
/tmp/rhr-recovery-final-player-analyze.log, /tmp/rhr-final-menu-build.log.
Screenshots include /tmp/rhr-session-bound-confirm.png,
/tmp/rhr-fixed-hosted-reload.png, /tmp/rhr-fixed-mismatch-reload.png,
/tmp/rhr-fixed-menu-busy.png, /tmp/rhr-fixed-menu-ready.png,
/tmp/rhr-fixed-mode-switch-progress.png.

Cellular is deferred at the user's request. This pass does not establish
hours-long or overnight stability. Physical reboot passed on the final QA build. USB/boot returned after 30.5
seconds; the driver dismissed the keyguard and reopened RHR. The original CLI
remained running, reconnected to the saved session without a scan, reused all
12 assets, restarted in 19,356 ms, and reached Ready. Screenshot:
/tmp/rhr-fixed-reboot-ready.png. Device log: /tmp/rhr-final-reboot-device.log.
The hosted session is left running for follow-up.

## Reconnect and restart performance, September 23

This pass improved recovery after a direct-transport failure. It did not establish
a hot-restart speedup or fix every source of reconnect delay.

The CLI now tracks consecutive failed attempts with `ReconnectBackoff`. Reaching
Ready resets the history and permits an immediate retry on the next disconnect.
Subsequent unsuccessful attempts wait 2, 4, 6 seconds, capped at 15 seconds.
Both `run` and `attach` use this policy. Flutter readiness polling now checks the
PID file every 100 ms instead of adding up to 1 or 2 seconds after attach completes.

The native player keeps a healthy signaling WebSocket when its direct peer fails.
The next developer hello replaces that peer. Previously it closed the signaling
connection too, paying the close-handshake delay and relay backoff. The phone also
records whether each relay attempt ever connected. Previously the failure callback
cleared the flag before the retry loop checked it, so backoff grew across successful
connections. A previously connected relay now retries immediately.

The CLI CPU profile showed packet hex formatting in the vendored WebRTC library.
DTLS and SCTP constructed full packet dumps even with debug logging disabled.
Those dumps were removed and retained metadata logging is lazy. Encryption,
checksums, packet sizes, and congestion control were not changed. Physical restart
results remained variable, so this change has no claimed wall-clock speedup.

All RHR measurements below selected `wss://getrhr.dev` for signaling and direct
WebRTC for payloads. The Samsung and Mac were on the same Wi-Fi. Flutter attach
used an empty ADB server. A separate USB-forwarded run provided only the comparison
baseline; it was not counted as an RHR verification.

| Test | Observed time |
| --- | --- |
| Hosted direct-loss baseline with accumulated CLI backoff | 25.919 s |
| CLI retry fix alone, before phone fix | 35.587 s, phone backoff dominated |
| Both retry fixes, before faster readiness polling | 12.132 s |
| Final hosted direct-loss recovery, run 1 | 9.569 s |
| Final hosted direct-loss recovery, run 2 | 10.018 s |
| Final connector direct-loss recovery | 14.918 s |
| Connector orderly relay-close recovery | 35.244 s |
| Hosted hot restart before packet-log changes | 11.247, 13.584, 9.564, 12.045 s |
| Hosted hot restart after both packet-log changes | 12.662, 15.167 s |
| Connector CLI hot restart after changes | 13.724 s |
| Connector physical player Restart button | 16.515 s, Flutter-reported duration |
| Connector unchanged-code hot reload | 0.387 s |
| Hosted USB-forwarded hot restart comparison | 1.300 s |
| Experimental native CLI, connector hot restart | 13.624 s |

The two final hosted recovery runs averaged 9.794 s, 62.2% below the measured
25.919 s baseline. The second run included opening Android settings during recovery.
Direct WebRTC was ready after 1.7 to 2.1 seconds in the final recovery runs.
The remaining time included project checks and a new Flutter attach. No rescan or
APK rebuild was needed for the direct-loss recovery tests. Connector setup required
re-enabling Samsung Wireless debugging before the initial connector run.

Flutter's verbose trace places most restart time in DevFS synchronization of the
42.4 MB kernel. One baseline recorded 237 ms before upload, 11,371 ms in file
transfer, 1,531 ms waiting on VM operations, and 273 ms launching the app.
This is a trace of the tool's stages, not a network-only throughput measurement.

Remaining findings:

- The orderly `relay-loss` fault waited about 20 seconds for the phone's socket
  teardown before reconnecting. The live relay's close-handshake behavior needs
  separate verification. No relay code or production service was changed in this pass.
- Replacing a benchmark CLI after detach sometimes left the existing session
  reported as busy. A fresh QA session was used for the later restart comparisons.
  Repeated direct-loss tests stayed within one session and did not need this reset.
- Hot restart remains slow. Removing packet dumps did not prove a latency win.
- Cellular, separate NATs, and overnight stability remain untested.

Verification: 123 CLI tests passed on the final source. CLI analysis passed. The
QA player built and installed without clearing its data. Native unit tests passed.
The connector app was visible after recovery, and its counter remained at 1 after
hot reload. The physical Restart action completed and returned the app to a clean
start. Only the QA player was replaced; the original player was untouched.

Evidence:

- `/tmp/rhr-perf-watch.py` timestamps fault, restart, and reload log events.
- `/tmp/rhr-perf-baseline-reconnect.json` and `/tmp/rhr-perf-final-hosted-reconnect1.json`.
- `/tmp/rhr-perf-final-hosted-reconnect2.json` and `/tmp/rhr-perf-connector-reconnect1.json`.
- `/tmp/rhr-perf-connector-relay-reconnect.json`.
- `/tmp/rhr-perf-profile.log`, `/tmp/rhr-perf-cpu.json`, and `/tmp/rhr-perf-cpu-after-warm.json`.
- `/tmp/rhr-perf-final-hosted.log`, `/tmp/rhr-perf-connector.log`, and `/tmp/rhr-perf-usb.log`.
- `/tmp/rhr-perf-final-cli-tests.log`, `/tmp/rhr-perf-native-tests.log`, and `/tmp/rhr-perf-player-build.log`.
- `/tmp/rhr-perf-hosted-ready.png` and `/tmp/rhr-perf-connector-ready.png`.

The fixes are local and unreleased. The final connector session is left running.

The standalone native CLI experiment used `dart compile exe` and an explicit
`FLUTTER_ROOT`. Without that environment variable, SDK discovery failed before
pairing. The actual installation path uses `dart pub global activate`; the native
executable is not the published distribution. Its restart result did not establish
a speedup. The regular source CLI was restored afterward.

Analysis of the two changed vendored WebRTC files passed after resolving that
package's dependencies. The initial standalone analysis lacked package resolution
and was not a valid code check.
