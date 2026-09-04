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
}

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
		// One connection per role: kick the previous holder.
		for (const ws of this.ctx.getWebSockets(role)) {
			ws.close(1000, "replaced by new connection");
		}

		const pair = new WebSocketPair();
		const meta: ConnMeta = { role, connectedAt: Date.now(), msgs: 0, bytes: 0 };
		this.ctx.acceptWebSocket(pair[1], [role, JSON.stringify(meta)]);
		console.log(
			`[rhr] ${role} CONNECTED (was dev=${before.dev} device=${before.device})`,
		);
		if (role === "dev") {
			const deviceLive = this.ctx.getWebSockets("device").length > 0;
			const info = await this.ctx.storage.get<string>("deviceInfo");
			const at = (await this.ctx.storage.get<number>("deviceInfoAt")) ?? 0;
			const fresh = info !== undefined && Date.now() - at < INFO_TTL_MS;
			console.log(
				`[rhr] dev replay check: deviceLive=${deviceLive} hasInfo=${info !== undefined} fresh=${fresh}`,
			);
			if (deviceLive && fresh) {
				pair[1].send(info);
				console.log("[rhr] dev replayed cached info");
			}
		}
		return new Response(null, { status: 101, webSocket: pair[0] });
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
		// Cache ONLY the device's info announcement for late-dev replay. Pings
		// and other control text must NOT overwrite it (they used to, clobbering
		// the cached VM URI with "{"t":"ping"}").
		if (role === "device" && message.includes('"info"')) {
			await this.ctx.storage.put({
				deviceInfo: message,
				deviceInfoAt: Date.now(),
			});
			console.log("[rhr] cached device info");
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
		const role = this.roleOf(ws);
		if (role === "device") {
			await this.ctx.storage.delete("deviceInfo");
			// The session is dead without a device: its tunnel channels are
			// half-open and the attached dev's flutter attach would hang on
			// them forever. Drop the dev too so the CLI's recovery loop wakes
			// up, re-dials, and re-pairs with the device when it returns.
			this.closeRole("dev", 1001, "device disconnected");
		}
	}

	async webSocketError(ws: WebSocket, _error: unknown) {
		this.logDrop(ws, "error", -1, false);
		const role = this.roleOf(ws);
		if (role === "device") {
			await this.ctx.storage.delete("deviceInfo");
			this.closeRole("dev", 1001, "device disconnected");
		}
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
			`[rhr] ${m?.role ?? "?"} ${how} code=${code} clean=${clean} ` +
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
