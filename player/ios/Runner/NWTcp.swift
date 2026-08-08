import Foundation
import Network

/// Minimal TCP client over Network.framework for tunneling a channel to the
/// local Dart VM Service. onData(nil) signals EOF/close.
final class NWTcp {
	private let conn: NWConnection
	private let onData: (Data?) -> Void
	private let queue = DispatchQueue(label: "rhr.nwtcp")

	init(host: String, port: UInt16, onData: @escaping (Data?) -> Void) {
		self.onData = onData
		self.conn = NWConnection(
			host: NWEndpoint.Host(host),
			port: NWEndpoint.Port(rawValue: port) ?? 80,
			using: .tcp)
	}

	func start() {
		conn.stateUpdateHandler = { [weak self] state in
			switch state {
			case .ready: self?.readLoop()
			case .failed, .cancelled: self?.onData(nil)
			default: break
			}
		}
		conn.start(queue: queue)
	}

	private func readLoop() {
		conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
			[weak self] data, _, isComplete, error in
			guard let self = self else { return }
			if let data = data, !data.isEmpty { self.onData(data) }
			if isComplete || error != nil {
				self.onData(nil)
				return
			}
			self.readLoop()
		}
	}

	func write(_ data: Data) {
		conn.send(content: data, completion: .contentProcessed { _ in })
	}

	func close() {
		conn.cancel()
	}
}
