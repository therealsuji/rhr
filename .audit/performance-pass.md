# Reconnect and restart performance

Authorized scope: local CLI/player improvements and physical Samsung tests through getrhr.dev. Preserve existing changes. No production deployment or release.

Plan:
1. Capture a baseline trace via the driver skill (`run` for CLIs/TUIs, `verify` for UIs).
2. `how` to ground hypotheses. Don't claim a perf ceiling without running it first.
3. Plan the fix from the trace. Capture a post-fix trace.
4. Parse and compare the artifacts. Inconclusive is not a pass.
5. Cite the measurement in the PR. Skip PR: this task requests local fixes and verification.
6. Run Opening a PR. Skip: no publishing requested.

Delegation skipped under repository requirement to ask before invoking another agent. Work remains local to the primary agent.

Throughput checkpoint: use one timestamped log watcher for repeated fault/restart measurements, then test each accepted change before adding another. Test both player and connector routes. Cellular remains deferred.

Ground: developer retry loop reconstructs transport and Flutter attach after failure. Player Restart forwards SIGUSR2 to Flutter attach. Candidate gathering precedes direct negotiation. Native mux connects TCP sockets to the VM service.

Argent update 0.25.2 is available; no update authorized or performed.

Completed the baseline, source trace, implementation, and before/after device checks.
Ground/sketch/implementation were performed locally under the repository's no-agent
rule. No approval checkpoint or architecture replacement was needed.

Data shape: ReconnectBackoff owns consecutive failures and a one-use immediate
retry after Ready. Alternative: lower every retry timeout. Rejected because that
would speed repeated failed attempts without distinguishing a recovered session.
Alternative: keep the existing counter and reset it in several catch branches.
Rejected because exceptions do not indicate whether the session had been healthy.
A readiness callback supplies that fact to both outer retry loops.

Phone alternative: reduce the WebSocket close timeout after direct failure.
Rejected because the signaling connection is still usable. Keep it until real relay
failure and replace the failed direct peer when the new developer hello arrives.

Fix Root Causes shaped the choice to preserve healthy signaling and correct the
backoff state. Model the Domain shaped the shared retry policy. Prove It Works and
Sequence Verifiable Units required testing the CLI-only change first, which exposed
the independent phone delay, then retesting both changes on the physical device.

Results and evidence are in FLOW_VALIDATION.md, September 23 performance section.
Hosted direct-loss recovery improved from 25.919 s to 9.569 and 10.018 s. Connector
direct-loss recovered in 14.918 s. Hot restart has no proven speedup. The orderly
relay-close case still took 35.244 s. CLI replacement sometimes encountered the
previous busy-claim problem; do not describe the overall flow as foolproof.
