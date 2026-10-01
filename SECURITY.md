# Security policy

rhr is a developer tool that exposes a Flutter Dart VM Service through a
session relay. A session code is a bearer credential: anyone who has it can
reload the app, inspect its state, evaluate expressions, and control the debug
process.

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
