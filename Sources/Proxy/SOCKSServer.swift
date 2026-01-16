import Foundation
import Network
import OSLog

private let logger = Logger(subsystem: "com.socksproxy", category: "SOCKSServer")

/// SOCKS5 proxy server using Network.framework
final class SOCKSServer {
    private var listener: NWListener?
    private var connections: [UUID: SOCKSConnection] = [:]
    private let port: UInt16
    private let queue = DispatchQueue(label: "com.socksproxy.server", qos: .userInitiated)

    var isRunning: Bool {
        listener?.state == .ready
    }

    var onStateChange: ((Bool) -> Void)?
    var onConnectionUpdate: ((ConnectionStats) -> Void)?
    var onError: ((Error) -> Void)?

    init(port: UInt16 = 1080) {
        self.port = port
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        // Allow connections from any interface (important for hotspot)
        parameters.requiredInterfaceType = .wifi

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw SOCKSServerError.invalidPort
        }

        do {
            listener = try NWListener(using: parameters, on: nwPort)
        } catch {
            throw SOCKSServerError.listenerCreationFailed(error)
        }

        listener?.stateUpdateHandler = { [weak self] state in
            self?.handleStateChange(state)
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        listener?.start(queue: queue)
        logger.info("SOCKS server starting on port \(self.port)")
    }

    func stop() {
        listener?.cancel()
        listener = nil

        // Cancel all active connections
        for (_, connection) in connections {
            connection.cancel()
        }
        connections.removeAll()

        logger.info("SOCKS server stopped")
        onStateChange?(false)
    }

    // MARK: - Private Methods

    private func handleStateChange(_ state: NWListener.State) {
        switch state {
        case .ready:
            logger.info("SOCKS server ready on port \(self.port)")
            DispatchQueue.main.async {
                self.onStateChange?(true)
            }

        case .failed(let error):
            logger.error("SOCKS server failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.onError?(SOCKSServerError.listenerFailed(error))
                self.onStateChange?(false)
            }

        case .cancelled:
            logger.info("SOCKS server cancelled")
            DispatchQueue.main.async {
                self.onStateChange?(false)
            }

        default:
            break
        }
    }

    private func handleNewConnection(_ connection: NWConnection) {
        let endpoint = connection.endpoint
        logger.info("New connection from \(String(describing: endpoint))")

        let socksConnection = SOCKSConnection(connection: connection) { [weak self] stats in
            DispatchQueue.main.async {
                self?.onConnectionUpdate?(stats)
            }

            if stats.state == .closed {
                self?.queue.async {
                    self?.connections.removeValue(forKey: stats.id)
                }
            }
        }

        connections[socksConnection.id] = socksConnection
        socksConnection.start()
    }
}

// MARK: - Errors

enum SOCKSServerError: LocalizedError {
    case invalidPort
    case listenerCreationFailed(Error)
    case listenerFailed(NWError)

    var errorDescription: String? {
        switch self {
        case .invalidPort:
            return "Invalid port number"
        case .listenerCreationFailed(let error):
            return "Failed to create listener: \(error.localizedDescription)"
        case .listenerFailed(let error):
            return "Listener failed: \(error.localizedDescription)"
        }
    }
}
