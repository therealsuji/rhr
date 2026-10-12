// Accounts, installations, and the memberships between them.
//
// A device never signs in. A phone generates an installation identity on first
// run, scans an invite, and from then on holds a membership — not an identity,
// and not an account of its own. That is what lets the user add their phone
// to their own account without signing in on the phone.
//
// Deliberately separate from the session WebSocket: that route rejects any
// request carrying an Origin header because only native clients belong on it,
// while these are ordinary HTTP endpoints.

import { decodeBase64Url, verifyAccessToken } from "./verify_token";

export interface AccountsEnv {
	ACCOUNTS: D1Database;
	/** Signs rendezvous tickets. A Worker secret, never sent to a client. */
	TICKET_KEY: string;
	/** Reads a developer's verified email from WorkOS. A Worker secret. */
	WORKOS_API_KEY: string;
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
 * user's device list, so it is attacker-controlled text in a terminal on
 * another machine. Control characters could forge extra lines or overwrite
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

const base64Url = (bytes: Uint8Array) =>
	btoa(String.fromCharCode(...bytes))
		.replaceAll("+", "-")
		.replaceAll("/", "_")
		.replaceAll("=", "");

const token = (bytes: number) =>
	base64Url(crypto.getRandomValues(new Uint8Array(bytes)));

export interface Account {
	id: string;
	email: string;
	/** The WorkOS user, from the token's signed `sub`. */
	authUserId: string;
}

/** Resolves a WorkOS access token to the account it belongs to, creating the
 *  account on first sight. Returns null when the token is not valid. */
export async function accountForToken(
	env: AccountsEnv,
	authorization: string | null,
): Promise<Account | null> {
	const bearer = authorization?.replace(/^Bearer /, "");
	if (!bearer) return null;

	// Verified, not merely decoded: an unverified JWT authenticates nobody,
	// since anyone can write a `sub` and base64 it. This route hands out
	// invites to an account, so the signature is what stands between a
	// stranger and someone else's devices.
	const claims = await verifyAccessToken(bearer, CLIENT_ID);
	if (!claims) return null;
	const userId = claims.sub;

	const existing = await env.ACCOUNTS.prepare(
		"SELECT id, email FROM accounts WHERE auth_user_id = ?",
	)
		.bind(userId)
		.first<{ id: string; email: string }>();
	if (existing) return { ...existing, authUserId: userId };

	const id = `acct_${token(12)}`;
	const email = (await verifiedEmail(env, userId)) ?? "";
	await env.ACCOUNTS.prepare(
		"INSERT INTO accounts (id, auth_user_id, email, created_at) VALUES (?, ?, ?, ?)",
	)
		.bind(id, userId, email, Date.now())
		.run();
	return { id, email, authUserId: userId };
}

/**
 * The developer's email as WorkOS knows it, or null when WorkOS cannot say.
 *
 * WorkOS access tokens carry no email claim, and the address names the
 * account on the phone's consent screen ("join Suji's account?"). Taking it
 * from the CLI let a developer call themselves anyone, so it comes from
 * WorkOS, keyed by the signed `sub`.
 */
async function verifiedEmail(
	env: AccountsEnv,
	userId: string,
): Promise<string | null> {
	const response = await fetch(
		`https://api.workos.com/user_management/users/${encodeURIComponent(userId)}`,
		{ headers: { Authorization: `Bearer ${env.WORKOS_API_KEY}` } },
	).catch(() => null);
	if (!response?.ok) return null;
	const user = (await response.json().catch(() => null)) as {
		email?: unknown;
		email_verified?: unknown;
	} | null;
	return user?.email_verified === true && typeof user.email === "string"
		? user.email
		: null;
}

/**
 * Refreshes an account's email from WorkOS, keeping the stored one when
 * WorkOS cannot answer. Called before an invite shows the address to a
 * tester, so accounts named by the CLI's own claim in older releases are
 * corrected the next time they invite anyone.
 */
export async function refreshAccountEmail(
	env: AccountsEnv,
	account: Account,
): Promise<Account> {
	const email = await verifiedEmail(env, account.authUserId);
	if (email === null || email === account.email) return account;
	await env.ACCOUNTS.prepare("UPDATE accounts SET email = ? WHERE id = ?")
		.bind(email, account.id)
		.run();
	return { ...account, email };
}

/** Mints an invite for the user to show as a QR. */
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

/**
 * Whose account an unexpired invite joins, or null.
 *
 * The phone asks before it shows the consent screen, so the address the
 * tester reads comes from here rather than from a QR anyone can print.
 */
export async function inviteAccount(
	env: AccountsEnv,
	inviteToken: string,
): Promise<string | null> {
	const row = await env.ACCOUNTS.prepare(
		"SELECT a.email, i.expires_at FROM invites i " +
			"JOIN accounts a ON a.id = i.account_id " +
			"WHERE i.token = ? AND i.redeemed_by IS NULL",
	)
		.bind(inviteToken)
		.first<{ email: string; expires_at: number }>();
	return row && Date.now() <= row.expires_at ? row.email : null;
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
 * it from them. The phone sends the secret only to the account service baked
 * into its build, never to a relay or to a service an invite names.
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

/** Installation ids are 16 random bytes, base64url without padding. */
const INSTALLATION_ID = /^[A-Za-z0-9_-]{22}$/;

const RENDEZVOUS_PREFIX = "dev-";

/**
 * The session name a phone waits on when it is reached through an account.
 *
 * Derived from the installation id rather than stored, so both ends can
 * compute it without a lookup. It is not a secret and grants nothing: the
 * relay admits a developer to it only with a ticket from [mintTicket], and
 * the phone only with its installation secret.
 */
export function rendezvousFor(installationId: string): string | null {
	return INSTALLATION_ID.test(installationId)
		? `${RENDEZVOUS_PREFIX}${installationId}`
		: null;
}

/** The installation a rendezvous names, or null when it is not one. */
export function installationOf(code: string): string | null {
	if (!code.startsWith(RENDEZVOUS_PREFIX)) return null;
	const id = code.slice(RENDEZVOUS_PREFIX.length);
	return INSTALLATION_ID.test(id) ? id : null;
}

/**
 * How long a ticket admits its holder. The CLI asks for a fresh one on every
 * dial, so this only has to outlast one connect, and a ticket that leaks out
 * of a log is dead almost at once.
 */
const TICKET_TTL_MS = 2 * 60 * 1000;

interface TicketClaims {
	/** The rendezvous this ticket opens. */
	r: string;
	/** The account it was issued to. */
	a: string;
	/** Expiry, epoch milliseconds. */
	e: number;
}

const ticketKey = (secret: string) =>
	crypto.subtle.importKey(
		"raw",
		new TextEncoder().encode(secret),
		{ name: "HMAC", hash: "SHA-256" },
		false,
		["sign", "verify"],
	);

/**
 * Signs permission for one account to meet one device.
 *
 * Membership is checked when the ticket is issued, and the ticket is what the
 * relay checks at the socket. Without it the rendezvous name, which travels
 * in device listings and session hellos, was all anyone needed to reach the
 * phone, and removing a membership revoked nothing.
 */
export async function mintTicket(
	env: AccountsEnv,
	rendezvous: string,
	accountId: string,
): Promise<{ ticket: string; expiresAt: number }> {
	const expiresAt = Date.now() + TICKET_TTL_MS;
	const claims: TicketClaims = { r: rendezvous, a: accountId, e: expiresAt };
	const payload = base64Url(new TextEncoder().encode(JSON.stringify(claims)));
	const signature = await crypto.subtle.sign(
		"HMAC",
		await ticketKey(env.TICKET_KEY),
		new TextEncoder().encode(payload),
	);
	return {
		ticket: `${payload}.${base64Url(new Uint8Array(signature))}`,
		expiresAt,
	};
}

/** Whether [ticket] was signed here, is unexpired, and opens [rendezvous]. */
export async function ticketOpens(
	env: AccountsEnv,
	ticket: string | null,
	rendezvous: string,
): Promise<boolean> {
	const [payload, signaturePart, ...rest] = (ticket ?? "").split(".");
	if (!payload || !signaturePart || rest.length > 0) return false;
	const signature = decodeBase64Url(signaturePart);
	if (!signature) return false;
	const valid = await crypto.subtle.verify(
		"HMAC",
		await ticketKey(env.TICKET_KEY),
		signature as BufferSource,
		new TextEncoder().encode(payload) as BufferSource,
	);
	if (!valid) return false;
	const bytes = decodeBase64Url(payload);
	if (!bytes) return false;
	let claims: Partial<TicketClaims>;
	try {
		claims = JSON.parse(new TextDecoder().decode(bytes));
	} catch {
		return false;
	}
	return (
		claims.r === rendezvous &&
		typeof claims.e === "number" &&
		Date.now() < claims.e
	);
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

/** The devices on an account, for the user's list. */
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
 * Either side may call this and neither needs the other: the computer
 * removes a device the user no longer uses, and the phone leaves an account
 * it no longer wants to be on. Deleting the same row from both directions is what makes
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

	// An installation that already exists has registered its secret, and
	// only the phone holding it may join it to anything more. Without this,
	// anyone who read an installation id could redeem their own invite with
	// it and enrol someone else's phone into their account.
	const registered = await env.ACCOUNTS.prepare(
		"SELECT 1 AS ok FROM installations WHERE id = ?",
	)
		.bind(installationId)
		.first<{ ok: number }>();
	if (
		registered &&
		!(await installationIsGenuine(env, installationId, secret))
	) {
		return { ok: false, reason: "this phone could not prove itself" };
	}

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
		// with later. An installation that already exists keeps its secret,
		// which the check above has just proved.
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
