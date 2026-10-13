# Security policy

rhr is a development tool that exposes a Flutter Dart VM Service through a
session relay. A session code is a bearer credential: anyone who has it can
reload the app, inspect its state, evaluate expressions, and control the debug
process.

With RHR Agent, the accessibility add-on the player installs on request, the
session also carries device control: screenshots, the element tree of any
window (system dialogs included), taps, swipes and typing anywhere on the
phone. RHR Agent answers only the player signed with its own key, and the
player serves it only while the host is connected. The user can stop it
from the session notification or turn it off in Accessibility settings. A way
to reach device control without a session code, from another app on the
phone, or after the user stopped it is a vulnerability.

`rhr mcp` passes screen text and logs to a coding agent. That text comes from
the user's phone and can be written by anyone whose app or page is on
screen. Treat it as untrusted input to the agent.

## What protects a session

- **Session codes** are minted from a CSPRNG (about 59 bits) and are the only
  credential for a typed session. Relays refuse any other shape.
- **Account devices** wait on a public rendezvous name. The relay admits a
  host to it only with a ticket that the account service issues to
  members and that expires within minutes, and admits the phone only with
  its installation secret.
- **The direct WebRTC path** checks each peer's DTLS certificate against the
  fingerprint in its SDP and authenticates every ICE check, so an attacker
  who can only reach the UDP ports cannot join it.
- **The relay is trusted.** It sees the session code and carries the SDP, so
  a malicious relay can reach the VM service or stand in the middle of the
  direct path. Run a private relay, behind TLS, when that trust is not
  acceptable.
- **The host's LAN relay** (`rhr run` on a private network) speaks TLS
  with a certificate minted per run; the session link carries its SHA-256 and
  the phone accepts nothing else.
- **A link never connects on its own.** The player names the relay and asks
  first.
- **`rhr update` installs only signed releases.** A release tag must carry an
  SSH signature from the release key built into the CLI, and the CLI installs
  the exact commit that signed tag names, so a moved or forged tag is refused.
- **Running rhr in a project trusts that project.** rhr runs the project's
  Flutter SDK (`.fvm`), Gradle build and plugins, as `flutter run` does.

## Reporting a vulnerability

Please do not open a public issue with a live session code, VM Service URL,
access token, private relay URL, or application log containing sensitive data.

Use GitHub's private vulnerability reporting for this repository when it is
available. If it is not enabled, contact the maintainer through the GitHub
profile and ask for a private security channel before sharing details.

Include:

- the affected release or commit;
- the smallest reproduction, with credentials and session codes removed;
- the impact and any required network or device conditions; and
- a suggested mitigation, if known.

## Supported versions

The current beta release line (`0.1.x`) receives security fixes. Older beta
builds may contain known relay, Android, or dependency vulnerabilities; update
the CLI and Player before investigating sensitive applications.

## Response expectations

We will acknowledge a report when we can reproduce or triage it, keep the
report private while a fix is prepared, and credit the reporter only with their
permission. The hosted relay is a beta convenience, not a security boundary
for production data. Use a private relay for sensitive development sessions.
