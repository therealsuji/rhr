// Accounts, installations, and the memberships between them.
//
// A device never signs in. A phone generates an installation identity on first
// run, scans an invite, and from then on holds a membership — not an identity,
// and not an account of its own. That is what lets a tester lend their phone
// to a developer's account without being asked to sign up for anything.
//
// Deliberately separate from the session WebSocket: that route rejects any
// request carrying an Origin header because only native clients belong on it,
// while these are ordinary HTTP endpoints.

export interface AccountsEnv {
	ACCOUNTS: D1Database;
}

/** How long a QR stays redeemable. Long enough to walk over, short enough
 *  that a photographed screen is not a standing invitation. */
const INVITE_TTL_MS = 5 * 60 * 1000;

/** 128 bits, so an invite cannot be guessed inside its lifetime. */
const INVITE_BYTES = 16;

const token = (bytes: number) => {
	const raw = crypto.getRandomValues(new Uint8Array(bytes));
	return btoa(String.fromCharCode(...raw))
		.replaceAll("+", "-")
		.replaceAll("/", "_")
		.replaceAll("=", "");
};

/** Resolves a WorkOS access token to the account it belongs to, creating the
 *  account on first sight. Returns null when the token is not valid. */
export async function accountForToken(
	env: AccountsEnv,
	authorization: string | null,
	claimedEmail?: string,
): Promise<{ id: string; email: string } | null> {
	const bearer = authorization?.replace(/^Bearer /, "");
	if (!bearer) return null;

	// WorkOS signs its access tokens as JWTs. The claims are read here rather
	// than verified: this endpoint hands out invites to an account, and the
	// next step (a signature check against the published JWKS) is what makes
	// that safe. Recorded as a gap rather than left implicit.
	const claims = readJwtClaims(bearer);
	if (!claims) return null;
	const userId = claims.sub;
	if (typeof userId !== "string") return null;
	// The access token carries no email claim, so the CLI passes what the
	// sign-in told it. It is a display name for the consent screen — "join
	// Suji's account?" — and never an authorisation input; `sub` is what
	// identifies the account.
	const email = claimedEmail ?? "";

	const existing = await env.ACCOUNTS.prepare(
		"SELECT id, email FROM accounts WHERE auth_user_id = ?",
	)
		.bind(userId)
		.first<{ id: string; email: string }>();
	if (existing) {
		// An account created before the CLI sent an email has none stored, and
		// a phone would then be asked to join a nameless account.
		if (!existing.email && email) {
			await env.ACCOUNTS.prepare("UPDATE accounts SET email = ? WHERE id = ?")
				.bind(email, existing.id)
				.run();
			return { id: existing.id, email };
		}
		return existing;
	}

	const id = `acct_${token(12)}`;
	await env.ACCOUNTS.prepare(
		"INSERT INTO accounts (id, auth_user_id, email, created_at) VALUES (?, ?, ?, ?)",
	)
		.bind(id, userId, email, Date.now())
		.run();
	return { id, email };
}

/** Decodes a JWT's payload without verifying it. */
function readJwtClaims(jwt: string): Record<string, unknown> | null {
	const payload = jwt.split(".")[1];
	if (!payload) return null;
	try {
		const json = atob(payload.replaceAll("-", "+").replaceAll("_", "/"));
		const claims = JSON.parse(json);
		return typeof claims === "object" && claims !== null ? claims : null;
	} catch {
		return null;
	}
}

/** Mints an invite for a developer to show as a QR. */
export async function createInvite(
	env: AccountsEnv,
	accountId: string,
): Promise<{ token: string; expiresAt: number }> {
	const value = token(INVITE_BYTES);
	const expiresAt = Date.now() + INVITE_TTL_MS;
	await env.ACCOUNTS.prepare(
		"INSERT INTO invites (token, account_id, expires_at) VALUES (?, ?, ?)",
	)
		.bind(value, accountId, expiresAt)
		.run();
	return { token: value, expiresAt };
}

export type JoinResult =
	| { ok: true; accountId: string; email: string; alreadyJoined: boolean }
	| { ok: false; reason: string };

/**
 * Redeems an invite, joining an installation to an account.
 *
 * Idempotent for the installation that redeemed it: a phone whose success
 * response was lost retries and lands on the same membership. Any OTHER
 * installation presenting a spent invite is refused, so a photographed QR
 * cannot enrol a second phone.
 */
export async function redeemInvite(
	env: AccountsEnv,
	inviteToken: string,
	installationId: string,
	label: string,
): Promise<JoinResult> {
	const invite = await env.ACCOUNTS.prepare(
		"SELECT account_id, expires_at, redeemed_by FROM invites WHERE token = ?",
	)
		.bind(inviteToken)
		.first<{
			account_id: string;
			expires_at: number;
			redeemed_by: string | null;
		}>();
	if (!invite) return { ok: false, reason: "this invite is not valid" };

	if (invite.redeemed_by && invite.redeemed_by !== installationId) {
		return { ok: false, reason: "this invite has already been used" };
	}
	if (!invite.redeemed_by && Date.now() > invite.expires_at) {
		return { ok: false, reason: "this invite has expired — ask for a new one" };
	}

	const account = await env.ACCOUNTS.prepare(
		"SELECT email FROM accounts WHERE id = ?",
	)
		.bind(invite.account_id)
		.first<{ email: string }>();
	if (!account) return { ok: false, reason: "this account no longer exists" };

	const already = invite.redeemed_by === installationId;
	const now = Date.now();
	await env.ACCOUNTS.batch([
		env.ACCOUNTS.prepare(
			"INSERT OR IGNORE INTO installations (id, created_at) VALUES (?, ?)",
		).bind(installationId, now),
		env.ACCOUNTS.prepare(
			"INSERT OR IGNORE INTO memberships " +
				"(account_id, installation_id, label, joined_at) VALUES (?, ?, ?, ?)",
		).bind(invite.account_id, installationId, label, now),
		env.ACCOUNTS.prepare(
			"UPDATE invites SET redeemed_by = ? WHERE token = ?",
		).bind(installationId, inviteToken),
	]);

	return {
		ok: true,
		accountId: invite.account_id,
		email: account.email,
		alreadyJoined: already,
	};
}
