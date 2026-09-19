import Foundation

// iOS twin of Android's RhrSessionService. Owns the rhr tunnel end so it
// survives the guest app's hot restart the same way the Android foreground
// service does. Runs in-process (iOS has no equivalent to a detached
// foreground service that can outlive the app), but the tunnel connection
// itself persists across Dart isolate restarts because this Swift object is
// owned by the native Runner, not the Dart VM.
//
// Protocol (mirror of bridge/lib/tunnel.dart):
//   TEXT frames   = JSON control ({"t":"info","vm":<uri>})
//   BINARY frames = [1B op][4B channel BE][payload]; op 0=open 1=data 2=close
//                   3=ack (payload = 4B consumed-byte count; 512KB window)
//
// Unlike Android there is no logcat to discover the live VM URI, so the Dart
// lobby passes it in and refreshes it on every resume/restart via the
// MethodChannel — Service.getInfo() is always callable from Dart.
final class RhrSessionService: NSObject, URLSessionWebSocketDelegate {
	static let shared = RhrSessionService()

	private let opOpen: UInt8 = 0
	private let opData: UInt8 = 1
	private let opClose: UInt8 = 2
	private let opAck: UInt8 = 3
	private let windowBytes = 512 * 1024

	private var session: URLSession!
	private var ws: URLSessionWebSocketTask?
	private var relayUrl = ""
	private var sessionCode = ""
	private var vmUri = ""
	private var stopped = false
	private var backoff: TimeInterval = 1

	// channel -> connection to the local VM service
	private var conns: [UInt32: NWTcp] = [:]
	private var unacked: [UInt32: Int] = [:]
	private let lock = NSLock()

	private(set) var status = "idle"

	override init() {
		super.init()
		session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
	}

	func start(relayUrl: String, code: String, vmUri: String) {
		self.relayUrl = relayUrl
		self.sessionCode = code
		self.vmUri = vmUri
		self.stopped = false
		connect()
	}

	/// Called by the lobby whenever the VM service URI may have changed
	/// (resume, after a guest process restart). Re-announces if different.
	func updateVmUri(_ uri: String) {
		guard uri != vmUri, !uri.contains(":0/") else { return }
		vmUri = uri
		announceInfo()
	}

	func kick() { /* connection is persistent on iOS; nothing to wake */ }

	func stop() {
		stopped = true
		ws?.cancel(with: .goingAway, reason: nil)
		status = "stopped"
	}

	// MARK: - relay connection

	private func connect() {
		guard !stopped else { return }
		guard let url = URL(string: "\(relayUrl)/s/\(sessionCode)/device") else { return }
		let task = session.webSocketTask(with: url)
		ws = task
		task.resume()
		receive()
	}

	func urlSession(
		_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
		didOpenWithProtocol proto: String?
	) {
		status = "connected"
		backoff = 1
		NSLog("[rhr] connected to relay, vm=\(vmUri)")
		announceInfo()
	}

	func urlSession(
		_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
		didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
	) {
		handleDisconnect()
	}

	private func announceInfo() {
		guard !vmUri.contains(":0/") else { return }
		let json = "{\"t\":\"info\",\"vm\":\"\(vmUri)\"}"
		ws?.send(.string(json)) { _ in }
	}

	private func receive() {
		ws?.receive { [weak self] result in
			guard let self = self else { return }
			switch result {
			case .failure:
				self.handleDisconnect()
			case .success(let message):
				switch message {
				case .data(let d): self.handleFrame(Array(d))
				case .string: break  // control from dev; none yet
				@unknown default: break
				}
				self.receive()
			}
		}
	}

	private func handleDisconnect() {
		guard !stopped else { return }
		status = "retrying"
		lock.lock()
		for (_, c) in conns { c.close() }
		conns.removeAll()
		unacked.removeAll()
		lock.unlock()
		let delay = backoff
		backoff = min(backoff * 2, 30)
		DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
			self?.connect()
		}
	}

	// MARK: - tunnel frames

	private func handleFrame(_ f: [UInt8]) {
		guard f.count >= 5 else { return }
		let op = f[0]
		let channel = UInt32(f[1]) << 24 | UInt32(f[2]) << 16 | UInt32(f[3]) << 8 | UInt32(f[4])
		let payload = Array(f[5...])
		switch op {
		case opOpen: openChannel(channel)
		case opData:
			lock.lock(); let c = conns[channel]; lock.unlock()
			c?.write(Data(payload))
			ws?.send(.data(Data(encodeAck(channel, payload.count)))) { _ in }
		case opAck:
			guard let n = Self.decodeAckCount(payload) else { return }
			lock.lock()
			unacked[channel] = max(0, (unacked[channel] ?? 0) - n)
			lock.unlock()
		case opClose: closeChannel(channel, notifyPeer: false)
		default: break
		}
	}

	private func openChannel(_ channel: UInt32) {
		guard let url = URL(string: vmUri), let host = url.host else {
			ws?.send(.data(Data(encodeClose(channel)))) { _ in }
			return
		}
		let conn = NWTcp(host: host, port: UInt16(url.port ?? 0)) { [weak self] data in
			guard let self = self, let data = data else {
				self?.closeChannel(channel, notifyPeer: true); return
			}
			self.ws?.send(.data(Data(self.encodeData(channel, Array(data))))) { _ in }
		}
		lock.lock(); conns[channel] = conn; lock.unlock()
		conn.start()
	}

	private func closeChannel(_ channel: UInt32, notifyPeer: Bool) {
		lock.lock()
		conns.removeValue(forKey: channel)?.close()
		unacked.removeValue(forKey: channel)
		lock.unlock()
		if notifyPeer { ws?.send(.data(Data(encodeClose(channel)))) { _ in } }
	}

	private func encodeData(_ ch: UInt32, _ p: [UInt8]) -> [UInt8] {
		[opData] + beBytes(ch) + p
	}
	private func encodeAck(_ ch: UInt32, _ n: Int) -> [UInt8] {
		[opAck] + beBytes(ch) + beBytes(UInt32(n))
	}
	private func encodeClose(_ ch: UInt32) -> [UInt8] { [opClose] + beBytes(ch) }

	static func decodeAckCount(_ payload: [UInt8]) -> Int? {
		guard payload.count >= 4 else { return nil }
		return Int(payload[0]) << 24 | Int(payload[1]) << 16 |
			Int(payload[2]) << 8 | Int(payload[3])
	}

	private func beBytes(_ v: UInt32) -> [UInt8] {
		[UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]
	}
}
