// rhr relay on Cloudflare Workers.
//
// One Durable Object per session code. The DO holds two WebSockets — the
// device bridge (dials out from the phone) and the dev CLI — and forwards text
// control messages between them. Uses the WebSocket Hibernation API so idle
// sessions cost nothing. Binary tunnel payloads are rejected: they belong on
// the direct WebRTC data channel.
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

export interface Env {
	SESSIONS: DurableObjectNamespace;
}

type Role = "device" | "dev";

// The tunnel grants VM-service access (arbitrary code execution in the app),
// so the session code is a bearer token. Codes must be unguessable, and a
// cached device info older than this is assumed stale (device WS died without
// a close event, e.g. eviction).
const MIN_CODE_LENGTH = 16;
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

/** DO storage key holding the newest generation handed out for a role. */
const generationKey = (role: Role) => `gen:${role}`;

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

const CLAIM_KEY = "claim";

/**
 * Set while the tester has paused the phone.
 *
 * Stopping a session without this just hands the phone to whoever asks next,
 * which reads as the Stop button not working: the tester ends a session, a
 * developer's recovery loop reclaims it a second later, and their screen is
 * taken over again. Pause is what actually gives the phone back.
 */
const PAUSED_KEY = "paused";

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

		if (request.headers.get("Upgrade") !== "websocket") {
			console.log(`[rhr] ${role} NON-WS request → 426`);
			return new Response("expected websocket", { status: 426 });
		}

		const before = {
			dev: this.ctx.getWebSockets("dev").length,
			device: this.ctx.getWebSockets("device").length,
		};

		// A dev asks to hold the phone; a device reconnecting is the same phone
		// coming back, so it keeps the old replace-on-connect behaviour.
		let claim: Claim | null = null;
		if (role === "dev") {
			const decision = await this.admitDev(
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
		for (const ws of this.ctx.getWebSockets(role)) {
			ws.close(1000, "replaced by new connection");
		}

		const generation =
			((await this.ctx.storage.get<number>(generationKey(role))) ?? 0) + 1;
		await this.ctx.storage.put(generationKey(role), generation);
		if (claim) {
			await this.ctx.storage.put(CLAIM_KEY, { ...claim, generation });
		}

		const pair = new WebSocketPair();
		const meta: ConnMeta = {
			role,
			connectedAt: Date.now(),
			msgs: 0,
			bytes: 0,
			generation,
		};
		this.ctx.acceptWebSocket(pair[1], [role, JSON.stringify(meta)]);
		console.log(
			`[rhr] ${role} CONNECTED gen=${generation} ` +
				`(was dev=${before.dev} device=${before.device})`,
		);
		if (role === "dev") {
			const deviceLive = this.ctx.getWebSockets("device").length > 0;
			const info = await this.ctx.storage.get<string>("deviceInfo");
			const at = (await this.ctx.storage.get<number>("deviceInfoAt")) ?? 0;
			const infoGen =
				(await this.ctx.storage.get<number>("deviceInfoGen")) ?? 0;
			const deviceGen =
				(await this.ctx.storage.get<number>(generationKey("device"))) ?? 0;
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
		offeredClaimId: string | null,
		holderLive: boolean,
	): Promise<
		{ refused: false; claim: Claim } | { refused: true; reason: string }
	> {
		if (await this.ctx.storage.get<boolean>(PAUSED_KEY)) {
			return {
				refused: true,
				reason: "paused: the tester has paused this device",
			};
		}
		const held = await this.ctx.storage.get<Claim>(CLAIM_KEY);
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
		const role = this.roleOf(ws);
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
			await this.ctx.storage.put(PAUSED_KEY, true);
			await this.ctx.storage.delete(CLAIM_KEY);
			// 1001 (going away) rather than a custom code: the runtime accepts it
			// on a hibernatable socket, and the CLI already treats it as a clean
			// end of session rather than an error to retry through.
			this.closeRole("dev", 1001, "paused by the tester");
			console.log("[rhr] device paused by the tester");
			return;
		}
		if (role === "device" && message.includes('"resume"')) {
			await this.ctx.storage.delete(PAUSED_KEY);
			console.log("[rhr] device resumed by the tester");
			return;
		}
		// A dev leaving on purpose hands the device back now rather than making
		// the next person wait out a grace period meant for crashes.
		if (role === "dev" && message.includes('"release"')) {
			const held = await this.ctx.storage.get<Claim>(CLAIM_KEY);
			if (held && held.generation === meta?.generation) {
				await this.ctx.storage.delete(CLAIM_KEY);
				console.log("[rhr] dev released its claim");
			}
			return;
		}
		// Cache ONLY the device's info announcement for late-dev replay. Pings
		// and other control text must NOT overwrite it (they used to, clobbering
		// the cached VM URI with "{"t":"ping"}").
		if (role === "device" && message.includes('"info"')) {
			await this.ctx.storage.put({
				deviceInfo: message,
				deviceInfoAt: Date.now(),
				deviceInfoGen: meta?.generation ?? 0,
			});
			console.log(`[rhr] cached device info gen=${meta?.generation ?? 0}`);
		}
		const peer: Role = role === "device" ? "dev" : "device";
		const peers = this.ctx.getWebSockets(peer);
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
		const generation = this.metaOf(ws)?.generation ?? 0;
		const held = await this.ctx.storage.get<Claim>(CLAIM_KEY);
		if (!held || held.generation !== generation) {
			console.log(
				`[rhr] ignoring stale dev close gen=${generation} ` +
					`claimGen=${held?.generation ?? "none"}`,
			);
			return;
		}
		const expiresAt = Date.now() + CLAIM_GRACE_MS;
		await this.ctx.storage.put(CLAIM_KEY, { ...held, expiresAt });
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
		if (this.roleOf(ws) !== "device") return;
		const generation = this.metaOf(ws)?.generation ?? 0;
		const current =
			(await this.ctx.storage.get<number>(generationKey("device"))) ?? 0;
		if (generation !== current) {
			console.log(
				`[rhr] ignoring stale device close gen=${generation} current=${current}`,
			);
			return;
		}
		await this.ctx.storage.delete("deviceInfo");
		// Holding a phone that is gone helps nobody: the claim exists to stop
		// developers stealing a phone from each other, and there is no phone to
		// steal. Releasing here also means a tester who walks away and comes
		// back is not locked out by whoever held it last.
		await this.ctx.storage.delete(CLAIM_KEY);
		// The session is dead without a device: its tunnel channels are
		// half-open and the attached dev's flutter attach would hang on
		// them forever. Drop the dev too so the CLI's recovery loop wakes
		// up, re-dials, and re-pairs with the device when it returns.
		this.closeRole("dev", 1001, "device disconnected");
	}

	private closeRole(role: Role, code: number, reason: string) {
		for (const ws of this.ctx.getWebSockets(role)) {
			try {
				ws.close(code, reason);
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

	private roleOf(ws: WebSocket): Role {
		return this.ctx.getTags(ws)[0] as Role;
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
			const id = env.SESSIONS.idFromName(seg[1]);
			return env.SESSIONS.get(id).fetch(request);
		}
		return new Response("not found", { status: 404 });
	},
} satisfies ExportedHandler<Env>;
