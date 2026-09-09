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
		env.ACCOUNTS.prepare(
			"INSERT OR IGNORE INTO installations (id, created_at) VALUES (?, ?)",
		).bind(installationId, now),
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
