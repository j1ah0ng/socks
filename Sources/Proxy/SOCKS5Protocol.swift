import Foundation
import Network

/// SOCKS5 Protocol implementation based on RFC 1928
enum SOCKS5 {

    // MARK: - Constants

    static let version: UInt8 = 0x05

    // MARK: - Authentication Methods

    enum AuthMethod: UInt8 {
        case noAuth = 0x00
        case gssapi = 0x01
        case usernamePassword = 0x02
        case noAcceptable = 0xFF
    }

    // MARK: - Commands

    enum Command: UInt8 {
        case connect = 0x01
        case bind = 0x02
        case udpAssociate = 0x03
    }

    // MARK: - Address Types

    enum AddressType: UInt8 {
        case ipv4 = 0x01
        case domainName = 0x03
        case ipv6 = 0x04
    }

    // MARK: - Reply Codes

    enum Reply: UInt8 {
        case succeeded = 0x00
        case generalFailure = 0x01
        case connectionNotAllowed = 0x02
        case networkUnreachable = 0x03
        case hostUnreachable = 0x04
        case connectionRefused = 0x05
        case ttlExpired = 0x06
        case commandNotSupported = 0x07
        case addressTypeNotSupported = 0x08
    }

    /// A malformed or unsupported message. `reply` is the code to send back, if the
    /// handshake has progressed far enough for a reply to be meaningful.
    struct ParseError: Error {
        let reply: Reply
    }

    // MARK: - Greeting

    struct MethodSelection {
        let methods: [AuthMethod]

        /// Parses a greeting from the front of `bytes`.
        /// Returns nil if more bytes are needed; throws if the greeting is malformed.
        static func parse(_ bytes: [UInt8]) throws -> (MethodSelection, consumed: Int)? {
            guard bytes.count >= 2 else { return nil }
            guard bytes[0] == SOCKS5.version else { throw ParseError(reply: .generalFailure) }

            let length = 2 + Int(bytes[1])
            guard bytes.count >= length else { return nil }

            let methods = bytes[2..<length].compactMap(AuthMethod.init(rawValue:))
            return (MethodSelection(methods: methods), length)
        }

        static func response(method: AuthMethod) -> Data {
            Data([SOCKS5.version, method.rawValue])
        }
    }

    // MARK: - Connection Request

    struct Request {
        let command: Command
        let host: NWEndpoint.Host
        let port: NWEndpoint.Port

        /// Parses a request from the front of `bytes`.
        /// Returns nil if more bytes are needed; throws if the request is malformed or unsupported.
        static func parse(_ bytes: [UInt8]) throws -> (Request, consumed: Int)? {
            guard bytes.count >= 4 else { return nil }
            guard bytes[0] == SOCKS5.version else { throw ParseError(reply: .generalFailure) }
            guard let command = Command(rawValue: bytes[1]) else { throw ParseError(reply: .commandNotSupported) }
            // bytes[2] is reserved

            var offset = 4
            let host: NWEndpoint.Host

            switch AddressType(rawValue: bytes[3]) {
            case .ipv4:
                guard bytes.count >= offset + 4 + 2 else { return nil }
                guard let address = IPv4Address(Data(bytes[offset..<(offset + 4)])) else {
                    throw ParseError(reply: .generalFailure)
                }
                host = .ipv4(address)
                offset += 4

            case .ipv6:
                guard bytes.count >= offset + 16 + 2 else { return nil }
                guard let address = IPv6Address(Data(bytes[offset..<(offset + 16)])) else {
                    throw ParseError(reply: .generalFailure)
                }
                host = .ipv6(address)
                offset += 16

            case .domainName:
                guard bytes.count >= offset + 1 else { return nil }
                let length = Int(bytes[offset])
                offset += 1
                guard bytes.count >= offset + length + 2 else { return nil }
                guard length > 0, let name = String(bytes: bytes[offset..<(offset + length)], encoding: .utf8) else {
                    throw ParseError(reply: .generalFailure)
                }
                host = NWEndpoint.Host(name)
                offset += length

            case nil:
                throw ParseError(reply: .addressTypeNotSupported)
            }

            let rawPort = UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
            guard rawPort != 0, let port = NWEndpoint.Port(rawValue: rawPort) else {
                throw ParseError(reply: .generalFailure)
            }
            offset += 2

            return (Request(command: command, host: host, port: port), offset)
        }
    }

    // MARK: - Response Builder

    /// Builds a request reply. The bound address is always reported as 0.0.0.0:0,
    /// which clients accept for CONNECT.
    static func response(reply: Reply) -> Data {
        Data([SOCKS5.version, reply.rawValue, 0x00, AddressType.ipv4.rawValue, 0, 0, 0, 0, 0, 0])
    }
}
