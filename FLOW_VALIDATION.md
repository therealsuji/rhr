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
