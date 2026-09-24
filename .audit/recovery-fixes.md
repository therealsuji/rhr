# Recovery fixes, September 23

Scope: fix the failures recorded in FLOW_VALIDATION.md, then verify on Samsung using getrhr.dev. Cellular deferred by user.

- [x] Reproduce on the matching surface. September 22 captures establish duplicate overlays, retry exhaustion, longevity failure, and a 61.8 second reload.
- [x] Trace causes. Retry classification/cap, overlay lifecycle, and unsynchronized pending-channel handoff.
- [x] Plan and implement. Keep transient failure classification; remove fatal retry cap. System overlay owns separate-app screens only; activity overlay owns player screens. Serialize pending-to-socket handoff with incoming bytes.
- [x] Verify on the same surface. Live connector, hosted, mode switches, repeated outages, old Flutter reloads.
- [x] Record final checks. No new commit or release requested.
- [ ] PR. Skip: local fix and device validation requested, no publishing requested.

Data ownership: watchOwnVm remains the VM selection authority. usesExternalVm exposes its value to the overlay service. The foreground activity suppresses the system overlay. No second transport or binary relay fallback.

Alternatives rejected: hiding repeated text alone would retain two native overlays; raising the retry limit would still abandon a recovering phone.

Throughput: use the existing QA package and fixture projects, direct device controls, bounded log polling, and existing unit suites. No delegation because repository instructions require user permission before another agent.

Argent reports version 0.25.2 available. No update performed.

The physical install test exposed stale PackageInstaller callbacks completing a different transfer. The receiver now matches the Android session ID, and a replacement install abandons only this installer's unfinished sessions. Existing stale mismatch_guest prompts were replaced with the correct flow_guest prompt on device.

Observed checks so far: 121 CLI tests, 22 Flutter player tests, native unit suite and QA APK build passed. Connector Restart 12,281 ms; visible reload 780 ms. Full repeated-loss and final mode-switch checks are still running.

Final device results are in FLOW_VALIDATION.md. Four direct-loss cycles passed; hosted/connector reloads and restarts passed; mode switching stopped the system overlay; old-SDK first reload took 1.175 seconds; physical reboot preserved the running CLI and recovered without rescanning. Cellular deferred by user, overnight duration not claimed.

Fix Root Causes drove removal of retry exhaustion and repair of native ownership and channel handoff. Model the Domain kept watchOwnVm as the target authority and Android installation session IDs as callback identity. Prove It Works required the same Samsung/live-relay paths, including a real reboot, instead of stopping at unit tests.
