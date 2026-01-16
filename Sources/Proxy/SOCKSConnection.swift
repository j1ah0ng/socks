import Foundation
import Network
import OSLog

private let logger = Logger(subsystem: "com.socksproxy", category: "SOCKSConnection")

/// Represents the state of a SOCKS connection
enum ConnectionState {
    case awaitingGreeting
    case awaitingRequest
    case connecting
    case relaying
    case closed
}

/// Statistics for a single connection
struct ConnectionStats: Identifiable {
    let id: UUID
    let startTime: Date
    var destinationHost: String?
    var destinationPort: UInt16?
    var bytesIn: Int64 = 0
    var bytesOut: Int64 = 0
    var state: ConnectionState = .awaitingGreeting

    init(id: UUID = UUID()) {
        self.id = id
        self.startTime = Date()
    }
}

/// Handles a single SOCKS5 client connection
final class SOCKSConnection {
    let id: UUID
    private let clientConnection: NWConnection
    private var targetConnection: NWConnection?
    private var state: ConnectionState = .awaitingGreeting
    private var stats: ConnectionStats
    private let statsCallback: (ConnectionStats) -> Void

    init(connection: NWConnection, statsCallback: @escaping (ConnectionStats) -> Void) {
        self.id = UUID()
        self.clientConnection = connection
        self.stats = ConnectionStats(id: id)
        self.statsCallback = statsCallback
    }

    func start() {
        clientConnection.stateUpdateHandler = { [weak self] state in
            self?.handleClientStateChange(state)
        }
        clientConnection.start(queue: .global(qos: .userInitiated))
    }

    func cancel() {
        state = .closed
        stats.state = .closed
        statsCallback(stats)
        clientConnection.cancel()
        targetConnection?.cancel()
    }

    // MARK: - Client State Handling

    private func handleClientStateChange(_ newState: NWConnection.State) {
        switch newState {
        case .ready:
            logger.info("Client connection ready: \(self.id)")
            receiveFromClient()

        case .failed(let error):
            logger.error("Client connection failed: \(error.localizedDescription)")
            cancel()

        case .cancelled:
            logger.info("Client connection cancelled: \(self.id)")
            state = .closed

        default:
            break
        }
    }

    // MARK: - Data Reception

    private func receiveFromClient() {
        clientConnection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                logger.error("Client receive error: \(error.localizedDescription)")
                self.cancel()
                return
            }

            if let data = data, !data.isEmpty {
                self.handleClientData(data)
            }

            if isComplete {
                self.cancel()
            } else if self.state != .closed {
                self.receiveFromClient()
            }
        }
    }

    private func handleClientData(_ data: Data) {
        switch state {
        case .awaitingGreeting:
            handleGreeting(data)

        case .awaitingRequest:
            handleRequest(data)

        case .relaying:
            relayToTarget(data)

        default:
            break
        }
    }

    // MARK: - SOCKS5 Handshake

    private func handleGreeting(_ data: Data) {
        guard let methodSelection = SOCKS5.MethodSelection(from: data) else {
            logger.error("Invalid greeting from client")
            cancel()
            return
        }

        // We only support no-auth for simplicity on local network
        if methodSelection.methods.contains(.noAuth) {
            let response = SOCKS5.MethodSelection.response(method: .noAuth)
            sendToClient(response) { [weak self] in
                self?.state = .awaitingRequest
                self?.stats.state = .awaitingRequest
            }
        } else {
            let response = SOCKS5.MethodSelection.response(method: .noAcceptable)
            sendToClient(response) { [weak self] in
                self?.cancel()
            }
        }
    }

    private func handleRequest(_ data: Data) {
        guard let request = SOCKS5.Request(from: data) else {
            logger.error("Invalid request from client")
            sendErrorResponse(.generalFailure)
            return
        }

        stats.destinationHost = request.destinationHost
        stats.destinationPort = request.destinationPort
        statsCallback(stats)

        logger.info("CONNECT request to \(request.destinationHost):\(request.destinationPort)")

        switch request.command {
        case .connect:
            connectToTarget(host: request.destinationHost, port: request.destinationPort)

        case .bind, .udpAssociate:
            logger.warning("Unsupported command: \(request.command.rawValue)")
            sendErrorResponse(.commandNotSupported)
        }
    }

    // MARK: - Target Connection

    private func connectToTarget(host: String, port: UInt16) {
        state = .connecting
        stats.state = .connecting
        statsCallback(stats)

        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: port))
        let connection = NWConnection(to: endpoint, using: .tcp)

        connection.stateUpdateHandler = { [weak self] state in
            self?.handleTargetStateChange(state)
        }

        targetConnection = connection
        connection.start(queue: .global(qos: .userInitiated))
    }

    private func handleTargetStateChange(_ newState: NWConnection.State) {
        switch newState {
        case .ready:
            logger.info("Target connection ready")
            sendSuccessResponse()
            startRelaying()

        case .failed(let error):
            logger.error("Target connection failed: \(error.localizedDescription)")
            handleTargetConnectionError(error)

        case .cancelled:
            logger.info("Target connection cancelled")
            cancel()

        default:
            break
        }
    }

    private func handleTargetConnectionError(_ error: NWError) {
        let reply: SOCKS5.Reply

        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED:
                reply = .connectionRefused
            case .ENETUNREACH:
                reply = .networkUnreachable
            case .EHOSTUNREACH:
                reply = .hostUnreachable
            case .ETIMEDOUT:
                reply = .ttlExpired
            default:
                reply = .generalFailure
            }
        default:
            reply = .generalFailure
        }

        sendErrorResponse(reply)
    }

    // MARK: - Response Sending

    private func sendSuccessResponse() {
        let response = SOCKS5.response(reply: .succeeded)
        sendToClient(response) { [weak self] in
            self?.state = .relaying
            self?.stats.state = .relaying
            self?.statsCallback(self!.stats)
        }
    }

    private func sendErrorResponse(_ reply: SOCKS5.Reply) {
        let response = SOCKS5.response(reply: reply)
        sendToClient(response) { [weak self] in
            self?.cancel()
        }
    }

    private func sendToClient(_ data: Data, completion: @escaping () -> Void) {
        clientConnection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                logger.error("Send to client error: \(error.localizedDescription)")
                self?.cancel()
                return
            }
            self?.stats.bytesOut += Int64(data.count)
            completion()
        })
    }

    // MARK: - Data Relaying

    private func startRelaying() {
        receiveFromTarget()
    }

    private func receiveFromTarget() {
        targetConnection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                logger.error("Target receive error: \(error.localizedDescription)")
                self.cancel()
                return
            }

            if let data = data, !data.isEmpty {
                self.relayToClient(data)
            }

            if isComplete {
                self.cancel()
            } else if self.state == .relaying {
                self.receiveFromTarget()
            }
        }
    }

    private func relayToTarget(_ data: Data) {
        stats.bytesIn += Int64(data.count)
        statsCallback(stats)

        targetConnection?.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                logger.error("Relay to target error: \(error.localizedDescription)")
                self?.cancel()
            }
        })
    }

    private func relayToClient(_ data: Data) {
        stats.bytesOut += Int64(data.count)
        statsCallback(stats)

        clientConnection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                logger.error("Relay to client error: \(error.localizedDescription)")
                self?.cancel()
            }
        })
    }
}
