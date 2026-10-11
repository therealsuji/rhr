// Signature verification for the developer's access token.
//
// Reading a JWT's claims without checking who signed them authenticates
// nobody: anyone can write `{"sub":"<someone else>"}` and base64 it. Every
// claim below is trusted only after the signature, issuer, audience and
// expiry have been checked against the keys WorkOS publishes.

/** Cached JWKS, since fetching per request would add a round trip to every
 *  authenticated call and the keys rotate rarely. */
interface KeyCache {
	keys: Map<string, CryptoKey>;
	fetchedAt: number;
}

let cache: KeyCache | null = null;

/** Long enough to matter, short enough that a rotated key is picked up
 *  without a deploy. A miss on an unknown `kid` refetches immediately. */
const JWKS_TTL_MS = 60 * 60 * 1000;

export interface VerifiedClaims {
	sub: string;
	email?: string;
}

/**
 * Verifies a WorkOS access token and returns its claims, or null.
 *
 * Null covers every failure — wrong signature, unknown key, expired, wrong
 * issuer or audience — deliberately: the caller has no decision to make
 * beyond "this is not a developer", and distinguishing the reasons to an
 * unauthenticated client only helps someone probing.
 */
export async function verifyAccessToken(
	jwt: string,
	clientId: string,
): Promise<VerifiedClaims | null> {
	const parts = jwt.split(".");
	if (parts.length !== 3) return null;
	const [headerPart, payloadPart, signaturePart] = parts;

	const header = decodeJson(headerPart);
	if (header?.alg !== "RS256" || typeof header.kid !== "string") return null;

	const key = await keyFor(header.kid, clientId);
	if (!key) return null;

	const signed = new TextEncoder().encode(`${headerPart}.${payloadPart}`);
	const signature = decodeBase64Url(signaturePart);
	if (!signature) return null;
	const valid = await crypto.subtle.verify(
		"RSASSA-PKCS1-v1_5",
		key,
		signature as BufferSource,
		signed as BufferSource,
	);
	if (!valid) return null;

	const claims = decodeJson(payloadPart);
	if (!claims) return null;

	// A valid signature on a token meant for somebody else, or one issued long
	// ago, is still not authorisation to act here.
	const now = Math.floor(Date.now() / 1000);
	if (typeof claims.exp === "number" && claims.exp < now) return null;
	if (typeof claims.nbf === "number" && claims.nbf > now) return null;
	if (claims.iss !== `https://api.workos.com/user_management/${clientId}`) {
		return null;
	}
	if (claims.client_id !== clientId) return null;
	if (typeof claims.sub !== "string") return null;

	return {
		sub: claims.sub,
		email: typeof claims.email === "string" ? claims.email : undefined,
	};
}

/** The public key for a `kid`, refetching once when it is not yet known. */
async function keyFor(
	kid: string,
	clientId: string,
): Promise<CryptoKey | null> {
	const fresh = cache && Date.now() - cache.fetchedAt < JWKS_TTL_MS;
	if (fresh) {
		const hit = cache?.keys.get(kid);
		if (hit) return hit;
	}
	// An unknown kid means either a rotated key or a forged header. Refetching
	// handles the first; the second fails on the lookup below either way.
	const loaded = await loadKeys(clientId);
	if (!loaded) return null;
	cache = loaded;
	return loaded.keys.get(kid) ?? null;
}

async function loadKeys(clientId: string): Promise<KeyCache | null> {
	const response = await fetch(
		`https://api.workos.com/sso/jwks/${clientId}`,
	).catch(() => null);
	if (!response?.ok) return null;
	const body = (await response.json().catch(() => null)) as {
		keys?: JsonWebKey[];
	} | null;
	if (!body?.keys) return null;

	const keys = new Map<string, CryptoKey>();
	for (const jwk of body.keys) {
		const kid = (jwk as { kid?: string }).kid;
		if (!kid) continue;
		const key = await crypto.subtle
			.importKey(
				"jwk",
				jwk,
				{ name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
				false,
				["verify"],
			)
			.catch(() => null);
		if (key) keys.set(kid, key);
	}
	return { keys, fetchedAt: Date.now() };
}

function decodeJson(part: string): Record<string, unknown> | null {
	const bytes = decodeBase64Url(part);
	if (!bytes) return null;
	try {
		const parsed = JSON.parse(new TextDecoder().decode(bytes));
		return typeof parsed === "object" && parsed !== null ? parsed : null;
	} catch {
		return null;
	}
}

function decodeBase64Url(value: string): Uint8Array | null {
	try {
		const padded = value.replaceAll("-", "+").replaceAll("_", "/");
		const binary = atob(padded + "=".repeat((4 - (padded.length % 4)) % 4));
		return Uint8Array.from(binary, (c) => c.charCodeAt(0));
	} catch {
		return null;
	}
}
