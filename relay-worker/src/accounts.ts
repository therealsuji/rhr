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

import { verifyAccessToken } from "./verify_token";

export interface AccountsEnv {
	ACCOUNTS: D1Database;
}

/** The client whose tokens this relay accepts. A token signed for a different
 *  WorkOS client is somebody else's and is refused. */
const CLIENT_ID = "client_01M20J8AWHXDECB250NDEB8YYJ";

/** How long a QR stays redeemable. Long enough to walk over, short enough
 *  that a photographed screen is not a standing invitation. */
const INVITE_TTL_MS = 5 * 60 * 1000;

/** 128 bits, so an invite cannot be guessed inside its lifetime. */
const INVITE_BYTES = 16;

/**
 * Cleans a device label supplied by the phone.
 *
 * The label is chosen by whoever holds the phone and then displayed in the
 * developer's device list, so it is attacker-controlled text in someone
 * else's terminal. Control characters could forge extra lines or overwrite
 * what is already on screen, which is how a device picker gets made to
 * suggest something it never said. Strip them, collapse whitespace, and keep
 * it short.
 */
export const cleanLabel = (raw: string | undefined): string => {
	const cleaned = (raw ?? "")
		// biome-ignore lint/suspicious/noControlCharactersInRegex: stripping them is the point
		.replace(/[\u0000-\u001f\u007f-\u009f]/g, " ")
		.replace(/\s+/g, " ")
		.trim()
		.slice(0, 64);
	return cleaned || "phone";
};

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

	// Verified, not merely decoded: an unverified JWT authenticates nobody,
	// since anyone can write a `sub` and base64 it. This route hands out
	// invites to an account, so the signature is what stands between a
	// stranger and someone else's devices.
	const claims = await verifyAccessToken(bearer, CLIENT_ID);
	if (!claims) return null;
	const userId = claims.sub;
	// WorkOS access tokens carry no email claim, so the CLI passes what
	// sign-in told it. It names the account on the phone's consent screen —
	// "join Suji's account?" — and is never an authorisation input; `sub`,
	// which is signed, is what identifies the account.
	const email = claims.email ?? claimedEmail ?? "";

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

/** Hex SHA-256, so a leaked database does not hand over device credentials. */
async function hashSecret(secret: string): Promise<string> {
	const digest = await crypto.subtle.digest(
		"SHA-256",
		new TextEncoder().encode(secret),
	);
	return [...new Uint8Array(digest)]
		.map((b) => b.toString(16).padStart(2, "0"))
		.join("");
}

/**
 * Proves a request really comes from the installation it names.
 *
 * The installation id is public — it appears in device listings and logs —
 * so it identifies a phone but authenticates nothing. Without this, anyone
 * who read an id could see which accounts that phone had joined, and remove
 * it from them. The secret never leaves the phone except as this proof.
 *
 * Comparison is constant-time-ish by construction: both sides are fixed-length
 * hex of a hash, so an early exit leaks nothing about the secret itself.
 */
export async function installationIsGenuine(
	env: AccountsEnv,
	installationId: string,
	secret: string | null,
): Promise<boolean> {
	if (!secret) return false;
	const row = await env.ACCOUNTS.prepare(
		"SELECT secret_hash FROM installations WHERE id = ?",
	)
		.bind(installationId)
		.first<{ secret_hash: string | null }>();
	if (!row?.secret_hash) return false;
	return row.secret_hash === (await hashSecret(secret));
}

/**
 * The session name a phone waits on when it is reached through an account.
 *
 * Derived from the installation id rather than stored, so both ends can
 * compute it without a lookup, and it is stable for the life of the
 * installation. It is not a secret: it names where to meet, and membership is
 * what decides who may. Prefixed and padded to clear the relay's 16-character
 * minimum, which exists because a session code is a bearer token — this is
 * not one, but the route enforces the same floor.
 */
export function rendezvousFor(installationId: string): string {
	const safe = installationId.replace(/[^A-Za-z0-9_-]/g, "");
	return `dev-${safe}`.padEnd(16, "0");
}

/** Whether this account may use this installation. */
export async function hasMembership(
	env: AccountsEnv,
	accountId: string,
	installationId: string,
): Promise<boolean> {
	const row = await env.ACCOUNTS.prepare(
		"SELECT 1 AS ok FROM memberships WHERE account_id = ? AND installation_id = ?",
	)
		.bind(accountId, installationId)
		.first<{ ok: number }>();
	return row !== null;
}

/** The devices on an account, for the developer's list. */
export async function devicesForAccount(
	env: AccountsEnv,
	accountId: string,
): Promise<{ installationId: string; label: string; joinedAt: number }[]> {
	const rows = await env.ACCOUNTS.prepare(
		"SELECT installation_id, label, joined_at FROM memberships " +
			"WHERE account_id = ? ORDER BY joined_at",
	)
		.bind(accountId)
		.all<{ installation_id: string; label: string; joined_at: number }>();
	return (rows.results ?? []).map((row) => ({
		installationId: row.installation_id,
		label: row.label,
		joinedAt: row.joined_at,
	}));
}

/**
 * The accounts a phone has joined.
 *
 * Answers only about the installation asking, and says nothing about the
 * other devices on those accounts: a membership is permission to be used,
 * not a view into somebody's fleet.
 */
export async function accountsForInstallation(
	env: AccountsEnv,
	installationId: string,
): Promise<{ accountId: string; email: string; joinedAt: number }[]> {
	const rows = await env.ACCOUNTS.prepare(
		"SELECT m.account_id, a.email, m.joined_at FROM memberships m " +
			"JOIN accounts a ON a.id = m.account_id " +
			"WHERE m.installation_id = ? ORDER BY m.joined_at",
	)
		.bind(installationId)
		.all<{ account_id: string; email: string; joined_at: number }>();
	return (rows.results ?? []).map((row) => ({
		accountId: row.account_id,
		email: row.email,
		joinedAt: row.joined_at,
	}));
}

/**
 * Ends a membership.
 *
 * Either side may call this and neither needs the other: the developer
 * removes a device they no longer use, and the tester stops lending a phone
 * that is theirs. Deleting the same row from both directions is what makes
 * that symmetry real rather than stated.
 */
export async function endMembership(
	env: AccountsEnv,
	accountId: string,
	installationId: string,
): Promise<boolean> {
	const result = await env.ACCOUNTS.prepare(
		"DELETE FROM memberships WHERE account_id = ? AND installation_id = ?",
	)
		.bind(accountId, installationId)
		.run();
	return (result.meta.changes ?? 0) > 0;
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
	secret: string,
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

	// Claim the invite with a conditional update rather than trusting the read
	// above. Two phones scanning the same QR at once would both see it unspent
	// and both pass that check; only one can win this, because the WHERE
	// clause is evaluated when the write happens.
	if (!already) {
		const claimed = await env.ACCOUNTS.prepare(
			"UPDATE invites SET redeemed_by = ? WHERE token = ? AND redeemed_by IS NULL",
		)
			.bind(installationId, inviteToken)
			.run();
		if (!claimed.meta.changes) {
			return { ok: false, reason: "this invite has already been used" };
		}
	}

	await env.ACCOUNTS.batch([
		// The first join is where a phone registers what it will prove itself
		// with later. An installation that already exists keeps its secret: a
		// second join must not let a stranger overwrite it.
		env.ACCOUNTS.prepare(
			"INSERT OR IGNORE INTO installations (id, secret_hash, created_at) " +
				"VALUES (?, ?, ?)",
		).bind(installationId, await hashSecret(secret), now),
		env.ACCOUNTS.prepare(
			"INSERT OR IGNORE INTO memberships " +
				"(account_id, installation_id, label, joined_at) VALUES (?, ?, ?, ?)",
		).bind(invite.account_id, installationId, label, now),
	]);

	return {
		ok: true,
		accountId: invite.account_id,
		email: account.email,
		alreadyJoined: already,
	};
}
