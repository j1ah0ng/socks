import Foundation
import Network
import OSLog

private let logger = Logger(subsystem: "com.socksproxy", category: "SOCKSConnection")

/// Handles a single SOCKS5 client connection.
///
/// All state is confined to `queue`, which must be serial. Both the client and target
/// `NWConnection`s deliver their callbacks on it, and `close()` must be called on it.
final class SOCKSConnection {
    private enum State {
        case awaitingGreeting
        case awaitingRequest
        case connecting
        case relaying
        /// Sending a final reply before closing; ignore further input.
        case closing
        case closed
    }

    /// Maximum bytes read per receive. Also caps the handshake buffer.
    private static let maxReadLength = 64 * 1024
    /// Seconds to wait for the target to accept a connection.
    private static let connectTimeout = 15

    let id = UUID()
    private let client: NWConnection
    private var target: NWConnection?
    private let queue: DispatchQueue
    private let onClose: (SOCKSConnection) -> Void
    private var state = State.awaitingGreeting
    /// Handshake bytes received but not yet parsed.
    private var buffer: [UInt8] = []
    /// Number of relay directions that have seen and forwarded EOF.
    private var finishedDirections = 0

    init(connection: NWConnection, queue: DispatchQueue, onClose: @escaping (SOCKSConnection) -> Void) {
        self.client = connection
        self.queue = queue
        self.onClose = onClose
    }

    func start() {
        client.stateUpdateHandler = { [weak self] state in
            self?.clientStateChanged(state)
        }
        client.start(queue: queue)
    }

    func close() {
        guard state != .closed else { return }
        state = .closed
        client.cancel()
        target?.cancel()
        onClose(self)
    }

    // MARK: - Client

    private func clientStateChanged(_ newState: NWConnection.State) {
        switch newState {
        case .ready:
            receiveHandshake()
        case .failed(let error):
            logger.debug("Client connection failed: \(error.localizedDescription)")
            close()
        default:
            break
        }
    }

    // MARK: - Handshake

    private func receiveHandshake() {
        client.receive(minimumIncompleteLength: 1, maximumLength: Self.maxReadLength) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard self.state == .awaitingGreeting || self.state == .awaitingRequest else { return }

            if let error {
                logger.debug("Client receive error during handshake: \(error.localizedDescription)")
                self.close()
                return
            }
            if let data {
                self.buffer.append(contentsOf: data)
            }

            self.processHandshake()

            // Once the request is parsed, the relay takes over reading from the client.
            guard self.state == .awaitingGreeting || self.state == .awaitingRequest else { return }
            if isComplete || self.buffer.count > Self.maxReadLength {
                self.close()
            } else {
                self.receiveHandshake()
            }
        }
    }

    /// Consumes as many complete handshake messages from `buffer` as are available.
    /// Clients may pipeline the greeting and request into a single segment.
    private func processHandshake() {
        if state == .awaitingGreeting {
            let parsed: (SOCKS5.MethodSelection, consumed: Int)?
            do {
                parsed = try SOCKS5.MethodSelection.parse(buffer)
            } catch {
                logger.error("Invalid greeting from client")
                close()
                return
            }
            guard let (greeting, consumed) = parsed else { return }
            buffer.removeFirst(consumed)

            // We only support no-auth for simplicity on local network
            guard greeting.methods.contains(.noAuth) else {
                sendFinalReply(SOCKS5.MethodSelection.response(method: .noAcceptable))
                return
            }
            // Advance state before sending, so a request arriving before the send
            // completes is not misread as a second greeting.
            state = .awaitingRequest
            sendToClient(SOCKS5.MethodSelection.response(method: .noAuth))
        }

        if state == .awaitingRequest {
            let parsed: (SOCKS5.Request, consumed: Int)?
            do {
                parsed = try SOCKS5.Request.parse(buffer)
            } catch let error as SOCKS5.ParseError {
                logger.error("Invalid request from client: reply \(error.reply.rawValue)")
                sendFinalReply(SOCKS5.response(reply: error.reply))
                return
            } catch {
                close()
                return
            }
            guard let (request, consumed) = parsed else { return }
            buffer.removeFirst(consumed)

            guard request.command == .connect else {
                logger.warning("Unsupported command: \(request.command.rawValue)")
                sendFinalReply(SOCKS5.response(reply: .commandNotSupported))
                return
            }
            connect(to: request.host, port: request.port)
        }
    }

    // MARK: - Target

    private func connect(to host: NWEndpoint.Host, port: NWEndpoint.Port) {
        logger.info("CONNECT \(String(describing: host)):\(port.rawValue)")
        state = .connecting

        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Self.connectTimeout
        tcp.noDelay = true
        tcp.enableKeepalive = true
        let connection = NWConnection(host: host, port: port, using: NWParameters(tls: nil, tcp: tcp))

        connection.stateUpdateHandler = { [weak self] state in
            self?.targetStateChanged(state)
        }
        target = connection
        connection.start(queue: queue)
    }

    private func targetStateChanged(_ newState: NWConnection.State) {
        switch newState {
        case .ready:
            guard state == .connecting, let target else { return }
            state = .relaying
            sendToClient(SOCKS5.response(reply: .succeeded))
            // Forward any bytes the client sent after its request (optimistic data).
            if !buffer.isEmpty {
                target.send(content: Data(buffer), completion: .contentProcessed { [weak self] error in
                    if error != nil { self?.close() }
                })
                buffer = []
            }
            pump(from: client, to: target)
            pump(from: target, to: client)

        // A connection that can't currently be established (e.g. DNS failure or no route)
        // sits in .waiting indefinitely. Fail fast instead of leaving the client hanging.
        case .waiting(let error) where state == .connecting,
             .failed(let error) where state == .connecting:
            logger.error("Target connection failed: \(error.localizedDescription)")
            sendFinalReply(SOCKS5.response(reply: Self.reply(for: error)))

        case .failed(let error):
            logger.debug("Target connection failed while relaying: \(error.localizedDescription)")
            close()

        default:
            break
        }
    }

    private static func reply(for error: NWError) -> SOCKS5.Reply {
        switch error {
        case .posix(.ECONNREFUSED):
            return .connectionRefused
        case .posix(.ENETUNREACH), .posix(.ENETDOWN):
            return .networkUnreachable
        case .posix(.EHOSTUNREACH), .posix(.EHOSTDOWN), .dns:
            return .hostUnreachable
        case .posix(.ETIMEDOUT):
            return .ttlExpired
        default:
            return .generalFailure
        }
    }

    // MARK: - Sending

    private func sendToClient(_ data: Data) {
        client.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error {
                logger.debug("Send to client failed: \(error.localizedDescription)")
                self?.close()
            }
        })
    }

    /// Sends `data`, half-closes the client connection, then tears everything down.
    private func sendFinalReply(_ data: Data) {
        state = .closing
        target?.cancel()
        client.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }

    // MARK: - Relaying

    /// Copies bytes from `source` to `destination` until EOF.
    ///
    /// The next read is only issued once the previous chunk has been handed off, so a
    /// slow peer applies backpressure instead of letting buffered data grow unbounded
    /// (which risks the app being killed for memory use while in the background).
    private func pump(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: Self.maxReadLength) { [weak self] data, _, isComplete, error in
            guard let self, self.state == .relaying else { return }

            if let error {
                logger.debug("Relay receive error: \(error.localizedDescription)")
                self.close()
                return
            }

            // On EOF, forward a FIN so the other side sees a half-close rather than
            // tearing down the connection while the reverse direction may still have data.
            let context: NWConnection.ContentContext = isComplete ? .finalMessage : .defaultMessage
            destination.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
                guard let self, self.state == .relaying else { return }

                if let error {
                    logger.debug("Relay send error: \(error.localizedDescription)")
                    self.close()
                } else if isComplete {
                    self.finishedDirections += 1
                    if self.finishedDirections == 2 {
                        self.close()
                    }
                } else {
                    self.pump(from: source, to: destination)
                }
            })
        }
    }
}
