# Security policy

## Supported versions

rhr is an early public beta. Security fixes are applied to the latest commit on
`main` and the newest GitHub prerelease only.

## Reporting a vulnerability

Please use [GitHub private vulnerability reporting](https://github.com/therealsuji/rhr/security/advisories/new).
Do not open a public issue for a suspected vulnerability.

We aim to acknowledge reports within 72 hours and will coordinate disclosure
after a fix is available. This is a best-effort open-source project, not a
commercial support commitment.

## Sensitive information

A session code is a bearer token that grants control of the relayed Dart VM
Service, including code execution inside the debug app. Treat session codes and
VM Service URIs as credentials.

Never include any of the following in an issue, discussion, screenshot, or log
attachment:

- a live or recently used session code;
- a VM Service or DevTools URI;
- source code, app data, tokens, or personal information from the debug app;
- unsanitized relay, CLI, or device logs.

If a code may have been exposed, disconnect both ends and start a new session
with a new code before continuing.
