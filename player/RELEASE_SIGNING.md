# Player release signing

Published player APKs are debug builds, but they use a persistent private signing
key. Android requires the same signing identity when updating an installed app.
Generating a new debug keystore on each CI runner breaks that requirement.

The release workflow requires these repository Actions secrets:

- `RHR_PLAYER_KEYSTORE_BASE64`: base64-encoded JKS keystore, alias `rhr-player`.
- `RHR_PLAYER_KEY_PASSWORD`: password for both the keystore and its private key.

Keep a secure backup of the keystore and password outside GitHub. Never commit
either file. Do not regenerate the key for a release, a runner change, or a
password reset. Losing the key prevents updates to existing installations.

Gradle selects this identity when `RHR_PLAYER_KEYSTORE` names the keystore and
`RHR_PLAYER_KEY_PASSWORD` supplies its password. Local builds without these
variables retain the developer's normal debug signing identity. CI refuses to
publish without the secrets and verifies the resulting APK against the public
certificate fingerprint in `tool/release-signing.sha256`.

Android version codes are `1000 + GITHUB_RUN_NUMBER`. Keep this workflow's run
sequence when renaming or replacing it, or choose an offset above every published
version code. Re-running the same workflow run keeps the same version code.

## Moving from older releases

Beta.10 and earlier did not preserve a release signing key. If the installed
APK's signing identity differs, the first persistently signed release requires
uninstalling the old player and installing the new APK. Uninstalling clears app
data, including pairing and setup. This is a one-time migration for installations
that subsequently use only releases signed with the persistent key.

CLI-built custom players still use the developer's local key. They cannot replace
a GitHub-signed player in place unless they use the same signing identity. Do not
distribute the release private key to solve this. Use a separate debug app through
connector mode when the project's runtime or native plugins require it.
