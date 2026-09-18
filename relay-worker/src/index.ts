// rhr relay on Cloudflare Workers.
//
// ONE Durable Object for every session. It holds two WebSockets per session —
// the device bridge (dials out from the phone) and the dev CLI — and forwards
// text control messages between them, keyed by session code.
//
// A Durable Object earns its place here for exactly one reason: a phone
// waiting for a developer holds an idle socket for hours, and a plain Worker
// cannot hold a socket at all. Hibernation makes that wait free; polling
// instead would cost millions of requests a day once there are more than a
// handful of phones. Everything else the relay does is a few kilobytes of
// signaling.
//
// That reason does not scale with sessions, so neither does the object count.
// A single instance handles tens of thousands of concurrent sockets, far more
// than this will see; if it ever stops being enough, hashing the code across a
// fixed handful of shards is a one-line change. Binary tunnel payloads are
// rejected: they belong on the direct WebRTC data channel.
//
// Routes:
//   GET /s/<code>/device  — device bridge end
//   GET /s/<code>/dev     — dev CLI end
//   GET /healthz
//
// The relay never parses tunnel frames. The one exception: the most recent
// TEXT frame from the device (the bridge's "info" hello carrying the VM
// service URI) is cached and replayed to a dev that connects later, so
// connection order doesn't matter. The cache lives in DO storage (hibernation
// wipes in-memory state) and is cleared when the device disconnects — a dead
// device's info would tunnel the dev into nothing.
//
// Every accepted socket carries a generation: the count of sockets accepted
// for its role so far. A replaced socket keeps running until its close event
// arrives, which can be long after its replacement is live, so anything that
// mutates shared session state first checks that the socket is still the
// current one for its role. Without that check a predecessor's close event
// tears down its own successor.

import {
	accountForToken,
	accountsForInstallation,
	cleanLabel,
	createInvite,
	devicesForAccount,
	endMembership,
	hasMembership,
	installationIsGenuine,
	rendezvousFor,
	redeemInvite,
} from "./accounts";

export interface Env {
	SESSIONS: DurableObjectNamespace;
	ACCOUNTS: D1Database;
}

// This deployment's own WorkOS environment. The /login redirect forwards only
// here, because authkit.app is shared across every WorkOS tenant.
const AUTHKIT_HOST = "bright-dandelion-45.authkit.app";

type Role = "device" | "dev";

// The tunnel grants VM-service access (arbitrary code execution in the app),
// so the session code is a bearer token. Codes must be unguessable, and a
// cached device info older than this is assumed stale (device WS died without
// a close event, e.g. eviction).
const MIN_CODE_LENGTH = 16;

/** The single relay object's name. Every session shares it. */
const RELAY_OBJECT = "relay";
const INFO_TTL_MS = 24 * 60 * 60 * 1000;
const MAX_CONTROL_MESSAGE_BYTES = 64 * 1024;
const textEncoder = new TextEncoder();

// Per-connection diagnostics, keyed off the socket via a serialized tag so it
// survives hibernation restarts. Lets us attribute a drop to a close code /
// wall-clock rather than guessing at "free tier limits".
interface ConnMeta {
	role: Role;
	connectedAt: number;
	msgs: number;
	bytes: number;
	/**
	 * Which socket this is for its role, counting from 1. Immutable: tags are
	 * fixed at acceptWebSocket, which is what makes this a reliable identity
	 * for a socket that may outlive its own replacement.
	 */
	generation: number;
}

// Every key and socket tag carries the session code, because one object now
// holds every session: without it, one session's state would answer for
// another's.
const generationKey = (code: string, role: Role) => `gen:${code}:${role}`;
const claimKey = (code: string) => `claim:${code}`;
const pausedKey = (code: string) => `paused:${code}`;
const infoKey = (code: string) => `info:${code}`;
const infoAtKey = (code: string) => `infoAt:${code}`;
const infoGenKey = (code: string) => `infoGen:${code}`;

/** Socket tag identifying which session and role a connection belongs to. */
const socketTag = (code: string, role: Role) => `${code}|${role}`;

// How long a dev's claim on a phone outlives its socket. Long enough that the
// CLI's own recovery loop (which backs off for seconds) reconnects into the
// claim it already held, short enough that a laptop that crashed or walked out
// of the building gives the phone back without anyone intervening.
//
// A claim is only consulted while it is unexpired AND its holder is absent: a
// live socket holds the phone on its own, so these seconds only matter across
// a disconnect.
const CLAIM_GRACE_MS = 45_000;

/**
 * Who currently holds the device, across disconnects.
 *
 * Without this a second developer's connect silently evicts the first, which
 * on a phone that several people share means whoever typed most recently wins
 * and the tester watching the screen is not consulted.
 */
interface Claim {
	/** Opaque per-invocation id: identity for resuming across a reconnect. */
	claimId: string;
	generation: number;
	/** When the grace period ends. Only meaningful while the holder is away. */
	expiresAt: number;
}

/**
 * Set while the tester has paused the phone.
 *
 * Stopping a session without this just hands the phone to whoever asks next,
 * which reads as the Stop button not working: the tester ends a session, a
 * developer's recovery loop reclaims it a second later, and their screen is
 * taken over again. Pause is what actually gives the phone back.
 */

/**
 * A dev announces the claim it is resuming with this header. The granted claim
 * comes back as a control frame instead: neither Dart WebSocket client exposes
 * the upgrade response, and a frame rides the channel that already exists.
 */
const CLAIM_HEADER = "x-rhr-claim";

export class RelaySession implements DurableObject {
	constructor(private ctx: DurableObjectState) {}

	async fetch(request: Request): Promise<Response> {
		const url = new URL(request.url);
		// Session code = the DO name = the path segment before the role.
		// /s/<code>/<role>
		const parts = url.pathname.split("/").filter(Boolean);
		const role = parts.at(-1) as Role;
		const code = parts.at(-2) as string;

		if (request.headers.get("Upgrade") !== "websocket") {
			console.log(`[rhr] ${role} NON-WS request → 426`);
			return new Response("expected websocket", { status: 426 });
		}

		const before = {
			dev: this.ctx.getWebSockets(socketTag(code, "dev")).length,
			device: this.ctx.getWebSockets(socketTag(code, "device")).length,
		};

		// A dev asks to hold the phone; a device reconnecting is the same phone
		// coming back, so it keeps the old replace-on-connect behaviour.
		let claim: Claim | null = null;
		if (role === "dev") {
			const decision = await this.admitDev(
				code,
				request.headers.get(CLAIM_HEADER),
				before.dev > 0,
			);
			if (decision.refused) {
				console.log(`[rhr] dev REFUSED ${decision.reason}`);
				// 409 rather than a close code: the CLI learns why before it has a
				// socket to be closed on, so it can say "busy" instead of retrying
				// into a fight for a phone someone else is holding.
				return new Response(decision.reason, {
					status: 409,
					headers: { "content-type": "text/plain" },
				});
			}
			claim = decision.claim;
		}

		// One connection per role: kick the previous holder. The evicted socket
		// stays alive until its own close event arrives, so it must not be able
		// to act on the session from here on — hence the generation.
		for (const ws of this.ctx.getWebSockets(socketTag(code, role))) {
			ws.close(1000, "replaced by new connection");
		}

		const generation =
			((await this.ctx.storage.get<number>(generationKey(code, role))) ?? 0) +
			1;
		await this.ctx.storage.put(generationKey(code, role), generation);
		if (claim) {
			await this.ctx.storage.put(claimKey(code), { ...claim, generation });
		}

		const pair = new WebSocketPair();
		const meta: ConnMeta = {
			role,
			connectedAt: Date.now(),
			msgs: 0,
			bytes: 0,
			generation,
		};
		this.ctx.acceptWebSocket(pair[1], [
			socketTag(code, role),
			JSON.stringify(meta),
		]);
		console.log(
			`[rhr] ${role} CONNECTED gen=${generation} ` +
				`(was dev=${before.dev} device=${before.device})`,
		);
		if (role === "dev") {
			const deviceLive =
				this.ctx.getWebSockets(socketTag(code, "device")).length > 0;
			const info = await this.ctx.storage.get<string>(infoKey(code));
			const at = (await this.ctx.storage.get<number>(infoAtKey(code))) ?? 0;
			const infoGen =
				(await this.ctx.storage.get<number>(infoGenKey(code))) ?? 0;
			const deviceGen =
				(await this.ctx.storage.get<number>(generationKey(code, "device"))) ??
				0;
			const fresh = info !== undefined && Date.now() - at < INFO_TTL_MS;
			// Info from a device connection that has since been replaced describes
			// a VM the current device is not serving; replaying it would tunnel
			// the dev into nothing.
			const current = infoGen === deviceGen;
			console.log(
				`[rhr] dev replay check: deviceLive=${deviceLive} ` +
					`hasInfo=${info !== undefined} fresh=${fresh} ` +
					`infoGen=${infoGen} deviceGen=${deviceGen}`,
			);
			if (deviceLive && fresh && current) {
				pair[1].send(info);
				console.log("[rhr] dev replayed cached info");
			}
		}
		if (claim) {
			// The dev needs its claim id to resume this same claim after a drop
			// rather than arrive as a stranger and be told the phone is busy.
			pair[1].send(JSON.stringify({ t: "claim", id: claim.claimId }));
		}
		return new Response(null, { status: 101, webSocket: pair[0] });
	}

	/**
	 * Decides whether a connecting dev may hold this phone.
	 *
	 * Three cases, in order:
	 *
	 *   - Nobody holds it, or the last holder's grace ran out: admit, new claim.
	 *   - The caller names the claim that is still standing: admit, same claim.
	 *     This is the CLI's own recovery loop coming back after a drop, which is
	 *     routine, so it must resume rather than be told its own phone is busy.
	 *   - Anyone else while the holder is live or still inside its grace: refuse.
	 *
	 * `holderLive` decides whether the grace period even applies: a connected
	 * holder owns the phone outright, and the clock only matters once it is
	 * gone.
	 */
	private async admitDev(
		code: string,
		offeredClaimId: string | null,
		holderLive: boolean,
	): Promise<
		{ refused: false; claim: Claim } | { refused: true; reason: string }
	> {
		if (await this.ctx.storage.get<boolean>(pausedKey(code))) {
			return {
				refused: true,
				reason: "paused: the tester has paused this device",
			};
		}
		const held = await this.ctx.storage.get<Claim>(claimKey(code));
		const now = Date.now();

		if (held && offeredClaimId === held.claimId) {
			return {
				refused: false,
				claim: { ...held, expiresAt: now + CLAIM_GRACE_MS },
			};
		}
		if (held && (holderLive || now < held.expiresAt)) {
			const seconds = Math.max(0, Math.round((held.expiresAt - now) / 1000));
			return {
				refused: true,
				reason: holderLive
					? "busy: another developer is connected to this device"
					: `busy: another developer holds this device for ${seconds}s more`,
			};
		}
		return {
			refused: false,
			claim: {
				claimId: crypto.randomUUID(),
				generation: 0,
				expiresAt: now + CLAIM_GRACE_MS,
			},
		};
	}

	async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer) {
		const { code, role } = this.sessionOf(ws);
		if (typeof message !== "string") {
			console.warn(
				`[rhr] ${role} rejected binary payload (${message.byteLength} bytes)`,
			);
			ws.close(4002, "binary payload disabled");
			return;
		}
		const messageBytes = textEncoder.encode(message).byteLength;
		if (messageBytes > MAX_CONTROL_MESSAGE_BYTES) {
			console.warn(
				`[rhr] ${role} rejected oversized control message (${messageBytes} bytes)`,
			);
			ws.close(4003, "control message too large");
			return;
		}
		const meta = this.metaOf(ws);
		if (meta) {
			meta.msgs++;
			meta.bytes += messageBytes;
		}
		// The tester's pause and resume, which only the phone may set: it is
		// the one that knows whether someone is holding it.
		if (role === "device" && message.includes('"pause"')) {
			await this.ctx.storage.put(pausedKey(code), true);
			await this.ctx.storage.delete(claimKey(code));
			// 1001 (going away) rather than a custom code: the runtime accepts it
			// on a hibernatable socket, and the CLI already treats it as a clean
			// end of session rather than an error to retry through.
			this.closeRole(code, "dev", 1001, "paused by the tester");
			console.log("[rhr] device paused by the tester");
			return;
		}
		if (role === "device" && message.includes('"resume"')) {
			await this.ctx.storage.delete(pausedKey(code));
			console.log("[rhr] device resumed by the tester");
			return;
		}
		// A dev leaving on purpose hands the device back now rather than making
		// the next person wait out a grace period meant for crashes.
		if (role === "dev" && message.includes('"release"')) {
			const held = await this.ctx.storage.get<Claim>(claimKey(code));
			if (held && held.generation === meta?.generation) {
				await this.ctx.storage.delete(claimKey(code));
				console.log("[rhr] dev released its claim");
			}
			return;
		}
		// Cache ONLY the device's info announcement for late-dev replay. Pings
		// and other control text must NOT overwrite it (they used to, clobbering
		// the cached VM URI with "{"t":"ping"}").
		if (role === "device" && message.includes('"info"')) {
			await this.ctx.storage.put({
				[infoKey(code)]: message,
				[infoAtKey(code)]: Date.now(),
				[infoGenKey(code)]: meta?.generation ?? 0,
			});
			console.log(`[rhr] cached device info gen=${meta?.generation ?? 0}`);
		}
		const peer: Role = role === "device" ? "dev" : "device";
		const peers = this.ctx.getWebSockets(socketTag(code, peer));
		for (const other of peers) {
			try {
				other.send(message);
			} catch {
				// The peer socket died between getWebSockets and send (e.g. a
				// dev CLI that crashed without a clean close). An unhandled
				// throw here would reject this handler and drop the SENDER's
				// connection too — the device then sees a connect→EOF loop.
				// Tolerate it; the dead peer's own close handler cleans up.
			}
		}
	}

	async webSocketClose(
		ws: WebSocket,
		code: number,
		_reason: string,
		clean: boolean,
	) {
		this.logDrop(ws, "close", code, clean);
		await this.onSocketGone(ws);
	}

	async webSocketError(ws: WebSocket, _error: unknown) {
		this.logDrop(ws, "error", -1, false);
		await this.onSocketGone(ws);
	}

	private async onSocketGone(ws: WebSocket) {
		if (this.roleOf(ws) === "dev") {
			await this.onDevGone(ws);
			return;
		}
		await this.onDeviceGone(ws);
	}

	/**
	 * Starts the grace clock when the holding dev's socket ends.
	 *
	 * The claim outlives the socket so the CLI's recovery loop reconnects into
	 * what it already held. A dev that never comes back simply lets the clock
	 * run out, which is what stops a crashed laptop from holding a phone that
	 * someone else is standing in front of.
	 */
	private async onDevGone(ws: WebSocket) {
		const { code } = this.sessionOf(ws);
		const generation = this.metaOf(ws)?.generation ?? 0;
		const held = await this.ctx.storage.get<Claim>(claimKey(code));
		if (!held || held.generation !== generation) {
			console.log(
				`[rhr] ignoring stale dev close gen=${generation} ` +
					`claimGen=${held?.generation ?? "none"}`,
			);
			return;
		}
		const expiresAt = Date.now() + CLAIM_GRACE_MS;
		await this.ctx.storage.put(claimKey(code), { ...held, expiresAt });
		console.log(
			`[rhr] dev gone; claim held ${CLAIM_GRACE_MS / 1000}s for reconnect`,
		);
	}

	/**
	 * Tears the session down when the CURRENT device connection ends.
	 *
	 * An evicted socket's close event can arrive after its replacement is
	 * already serving — reconnects are routine, so this is the common case, not
	 * a rare race. Acting on role alone would let the outgoing connection
	 * delete the live device's cached info and hang up on its dev, leaving a
	 * session that looks connected on both ends and moves no traffic.
	 */
	private async onDeviceGone(ws: WebSocket) {
		const { code, role } = this.sessionOf(ws);
		if (role !== "device") return;
		const generation = this.metaOf(ws)?.generation ?? 0;
		const current =
			(await this.ctx.storage.get<number>(generationKey(code, "device"))) ?? 0;
		if (generation !== current) {
			console.log(
				`[rhr] ignoring stale device close gen=${generation} current=${current}`,
			);
			return;
		}
		await this.ctx.storage.delete(infoKey(code));
		// Holding a phone that is gone helps nobody: the claim exists to stop
		// developers stealing a phone from each other, and there is no phone to
		// steal. Releasing here also means a tester who walks away and comes
		// back is not locked out by whoever held it last.
		await this.ctx.storage.delete(claimKey(code));
		// The session is dead without a device: its tunnel channels are
		// half-open and the attached dev's flutter attach would hang on
		// them forever. Drop the dev too so the CLI's recovery loop wakes
		// up, re-dials, and re-pairs with the device when it returns.
		this.closeRole(code, "dev", 1001, "device disconnected");
	}

	private closeRole(code: string, role: Role, wsCode: number, reason: string) {
		for (const ws of this.ctx.getWebSockets(socketTag(code, role))) {
			try {
				ws.close(wsCode, reason);
			} catch {
				// Already gone.
			}
		}
	}

	private logDrop(ws: WebSocket, how: string, code: number, clean: boolean) {
		const m = this.metaOf(ws);
		const secs = m ? Math.round((Date.now() - m.connectedAt) / 1000) : -1;
		console.log(
			`[rhr] ${m?.role ?? "?"} ${how} gen=${m?.generation ?? "?"} ` +
				`code=${code} clean=${clean} ` +
				`aliveSec=${secs} msgs=${m?.msgs ?? "?"} bytes=${m?.bytes ?? "?"}`,
		);
	}

	/** Session and role, recovered from the tag fixed at acceptWebSocket. */
	private sessionOf(ws: WebSocket): { code: string; role: Role } {
		const [code, role] = (this.ctx.getTags(ws)[0] ?? "|").split("|");
		return { code, role: role as Role };
	}

	private roleOf(ws: WebSocket): Role {
		return this.sessionOf(ws).role;
	}

	private metaOf(ws: WebSocket): ConnMeta | null {
		const tag = this.ctx.getTags(ws)[1];
		return tag ? (JSON.parse(tag) as ConnMeta) : null;
	}
}

export default {
	async fetch(request: Request, env: Env): Promise<Response> {
		const url = new URL(request.url);
		const seg = url.pathname.split("/").filter(Boolean);
		if (seg.length === 1 && seg[0] === "healthz") {
			return new Response("ok");
		}
		// `rhr login` prints a URL for the developer to open, and WorkOS hands
		// back one on its own auto-generated environment domain
		// (bright-dandelion-45.authkit.app) — a random name on someone else's
		// domain, in front of anyone signing in. A custom AuthKit domain is a
		// paid feature, but a redirect costs nothing: the CLI prints a URL on
		// ours, and this hop forwards to whatever WorkOS asked for.
		//
		// The destination is carried in ?to= rather than rebuilt here, because
		// the device-flow URL is issued per attempt and only the CLI has it.
		// Restricted to WorkOS hosts so this cannot be used as an open
		// redirect.
		if (seg.length === 1 && seg[0] === "login") {
			const to = url.searchParams.get("to");
			if (to === null) {
				return new Response("missing ?to=", { status: 400 });
			}
			let target: URL;
			try {
				target = new URL(to);
			} catch {
				return new Response("bad ?to=", { status: 400 });
			}
			// Exact hosts, not a suffix match. authkit.app is shared tenancy:
			// every WorkOS environment gets a subdomain, so allowing
			// *.authkit.app would forward to anyone else's login page from a
			// domain our users trust — a phishing hop wearing our name.
			const allowed =
				target.protocol === "https:" &&
				(target.hostname === AUTHKIT_HOST ||
					target.hostname === "api.workos.com");
			if (!allowed) {
				return new Response("refused: not a WorkOS URL", { status: 400 });
			}
			return Response.redirect(target.toString(), 302);
		}
		if (
			seg.length === 3 &&
			seg[0] === "s" &&
			(seg[2] === "device" || seg[2] === "dev")
		) {
			// Native clients (CLI, bridge) send no Origin header; a browser
			// always does. Rejecting it blocks cross-site WebSocket hijacking.
			if (request.headers.get("Origin") !== null) {
				return new Response("browser clients not allowed", { status: 403 });
			}
			if (seg[1].length < MIN_CODE_LENGTH) {
				return new Response(
					`session code must be at least ${MIN_CODE_LENGTH} chars`,
					{ status: 400 },
				);
			}
			// One object for every session, not one per code. A Durable Object
			// exists here only to hold idle sockets and introduce two peers;
			// spending an object per session buys nothing and multiplies them
			// with traffic. Signaling is a few kilobytes and a DO handles tens
			// of thousands of concurrent sockets, so a single instance covers
			// far more load than this will see — and when it stops doing so,
			// hashing the code across a fixed handful of shards is a one-line
			// change from here.
			const id = env.SESSIONS.idFromName(RELAY_OBJECT);
			return env.SESSIONS.get(id).fetch(request);
		}

		// Account routes. Ordinary HTTP, deliberately apart from the session
		// socket above: that one is native-clients-only, these are reached by a
		// phone redeeming an invite and a CLI holding a developer's token.
		if (seg.length === 2 && seg[0] === "account" && seg[1] === "invite") {
			if (request.method !== "POST") {
				return new Response("method not allowed", { status: 405 });
			}
			const account = await accountForToken(
				env,
				request.headers.get("Authorization"),
				new URL(request.url).searchParams.get("email") ?? undefined,
			);
			if (!account) return new Response("sign in first", { status: 401 });
			const invite = await createInvite(env, account.id);
			return Response.json({
				token: invite.token,
				expiresAt: invite.expiresAt,
				account: account.email,
			});
		}

		if (seg.length === 2 && seg[0] === "device" && seg[1] === "join") {
			if (request.method !== "POST") {
				return new Response("method not allowed", { status: 405 });
			}
			const body = (await request.json().catch(() => null)) as {
				invite?: string;
				installationId?: string;
				secret?: string;
				label?: string;
			} | null;
			if (!body?.invite || !body.installationId || !body.secret) {
				return new Response("invite, installationId and secret are required", {
					status: 400,
				});
			}
			const result = await redeemInvite(
				env,
				body.invite,
				body.installationId,
				body.secret,
				cleanLabel(body.label),
			);
			if (!result.ok) {
				return Response.json({ error: result.reason }, { status: 409 });
			}
			return Response.json({
				accountId: result.accountId,
				account: result.email,
				alreadyJoined: result.alreadyJoined,
			});
		}

		// Where to meet a device this account may use.
		//
		// Membership is checked here, before the CLI is told anything: an
		// account that has not been invited learns only that it cannot use this
		// device, not whether it exists or who has it. The rendezvous name is
		// derived rather than stored, so both ends compute the same one without
		// a lookup.
		if (seg.length === 2 && seg[0] === "account" && seg[1] === "connect") {
			const installationId = url.searchParams.get("installationId");
			if (!installationId) {
				return new Response("installationId is required", { status: 400 });
			}
			const account = await accountForToken(
				env,
				request.headers.get("Authorization"),
			);
			// Failing closed: an unverifiable token must never fall through to
			// an unauthenticated session on somebody's phone.
			if (!account) return new Response("sign in first", { status: 401 });
			if (!(await hasMembership(env, account.id, installationId))) {
				return new Response("this device is not on your account", {
					status: 403,
				});
			}
			return Response.json({ rendezvous: rendezvousFor(installationId) });
		}

		// The devices on the signed-in account, and removing one.
		if (seg.length === 2 && seg[0] === "account" && seg[1] === "devices") {
			const account = await accountForToken(
				env,
				request.headers.get("Authorization"),
			);
			if (!account) return new Response("sign in first", { status: 401 });

			if (request.method === "GET") {
				return Response.json({
					devices: await devicesForAccount(env, account.id),
				});
			}
			if (request.method === "DELETE") {
				const installationId = url.searchParams.get("installationId");
				if (!installationId) {
					return new Response("installationId is required", { status: 400 });
				}
				const removed = await endMembership(env, account.id, installationId);
				return Response.json({ removed });
			}
			return new Response("method not allowed", { status: 405 });
		}

		// The accounts a phone has joined, and leaving one. A phone holds no
		// token — it proves nothing beyond naming its own installation, which
		// is why these answer only about that installation and expose nothing
		// about an account beyond the address that named it on the consent
		// screen the tester already saw.
		if (seg.length === 2 && seg[0] === "device" && seg[1] === "accounts") {
			const installationId = url.searchParams.get("installationId");
			if (!installationId) {
				return new Response("installationId is required", { status: 400 });
			}
			// An installation id names a phone but proves nothing — it travels
			// in device listings and logs. Without the secret, anyone who read
			// one could see which accounts that phone had joined, and remove it
			// from them.
			if (
				!(await installationIsGenuine(
					env,
					installationId,
					request.headers.get("x-rhr-installation-secret"),
				))
			) {
				return new Response("this device could not prove itself", {
					status: 401,
				});
			}
			if (request.method === "GET") {
				return Response.json({
					accounts: await accountsForInstallation(env, installationId),
				});
			}
			if (request.method === "DELETE") {
				const accountId = url.searchParams.get("accountId");
				if (!accountId) {
					return new Response("accountId is required", { status: 400 });
				}
				const left = await endMembership(env, accountId, installationId);
				return Response.json({ left });
			}
			return new Response("method not allowed", { status: 405 });
		}

		return new Response("not found", { status: 404 });
	},
} satisfies ExportedHandler<Env>;
