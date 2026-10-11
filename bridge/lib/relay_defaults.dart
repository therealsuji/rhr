/// The relay baked into the debug player and used by the CLI when no private
/// relay is supplied. Deployments can override it at runtime.
const defaultPublicRelay = 'wss://getrhr.dev';

/// Where `rhr login` sends the developer to approve a device code.
///
/// WorkOS issues its URL on an auto-generated environment domain
/// (`bright-dandelion-45.authkit.app`), which is what anyone signing in would
/// otherwise see. A custom AuthKit domain is a paid feature; the relay's
/// /login route forwards to the same destination for free, so this is the
/// address the CLI hands out.
///
/// Override with RHR_LOGIN_BASE to point at a self-hosted relay.
const defaultLoginBase = 'https://getrhr.dev/login';
