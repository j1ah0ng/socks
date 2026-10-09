import Foundation
import Network
import OSLog

private let logger = Logger(subsystem: "com.socksproxy", category: "SOCKSServer")

/// SOCKS5 proxy server using Network.framework.
///
/// All mutable state is confined to `queue`. Callbacks are delivered on the main queue.
///
/// If the listener fails (e.g. its socket is reclaimed while the app was suspended, or
/// the network configuration changes), it is recreated automatically with backoff until
/// `stop()` is called.
final class SOCKSServer {
    private static let maxRestartDelay: TimeInterval = 30

    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "com.socksproxy.server", qos: .userInitiated)
    private var listener: NWListener?
    private var connections: [UUID: SOCKSConnection] = [:]
    private var isStopped = false
    private var restartAttempts = 0

    /// Called with `true` when the listener is accepting connections, and `false` when it
    /// has failed and is being restarted.
    var onListeningChange: ((Bool) -> Void)?
    var onError: ((Error) -> Void)?

    init(port: UInt16) throws {
        guard port != 0, let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw SOCKSServerError.invalidPort
        }
        self.port = nwPort
    }

    func start() {
        queue.async { self.startListener() }
    }

    func stop() {
        onListeningChange = nil
        onError = nil
        queue.async {
            self.isStopped = true
            self.listener?.cancel()
            self.listener = nil
            for connection in self.connections.values {
                connection.close()
            }
            self.connections.removeAll()
            logger.info("SOCKS server stopped")
        }
    }

    // MARK: - Listener

    private func startListener() {
        guard !isStopped, listener == nil else { return }

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        // Detect clients that vanished without closing (e.g. left the hotspot).
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 60
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: port)
        } catch {
            logger.error("Failed to create listener: \(error.localizedDescription)")
            notify(error: SOCKSServerError.listenerCreationFailed(error))
            scheduleRestart()
            return
        }

        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            self.listenerStateChanged(state, listener: listener)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        self.listener = listener
        listener.start(queue: queue)
        logger.info("SOCKS server starting on port \(self.port.rawValue)")
    }

    private func listenerStateChanged(_ state: NWListener.State, listener: NWListener) {
        guard listener === self.listener else { return }

        switch state {
        case .ready:
            logger.info("SOCKS server ready on port \(self.port.rawValue)")
            restartAttempts = 0
            notify(listening: true)

        case .failed(let error):
            logger.error("SOCKS server failed: \(error.localizedDescription)")
            listener.cancel()
            self.listener = nil
            notify(listening: false)
            notify(error: SOCKSServerError.listenerFailed(error))
            scheduleRestart()

        default:
            break
        }
    }

    private func scheduleRestart() {
        guard !isStopped else { return }
        let delay = min(pow(2, Double(restartAttempts)), Self.maxRestartDelay)
        restartAttempts += 1
        logger.info("Restarting listener in \(delay)s")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.startListener()
        }
    }

    private func accept(_ nwConnection: NWConnection) {
        guard !isStopped else {
            nwConnection.cancel()
            return
        }
        logger.debug("New connection from \(String(describing: nwConnection.endpoint))")

        let connection = SOCKSConnection(connection: nwConnection, queue: queue) { [weak self] connection in
            self?.connections[connection.id] = nil
        }
        connections[connection.id] = connection
        connection.start()
    }

    // MARK: - Callbacks

    private func notify(listening: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.onListeningChange?(listening)
        }
    }

    private func notify(error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.onError?(error)
        }
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
