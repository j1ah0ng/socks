import Foundation

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

    // MARK: - Greeting

    struct MethodSelection {
        let methods: [AuthMethod]

        init?(from data: Data) {
            guard data.count >= 2 else { return nil }
            guard data[0] == SOCKS5.version else { return nil }

            let methodCount = Int(data[1])
            guard data.count >= 2 + methodCount else { return nil }

            var methods: [AuthMethod] = []
            for i in 0..<methodCount {
                if let method = AuthMethod(rawValue: data[2 + i]) {
                    methods.append(method)
                }
            }
            self.methods = methods
        }

        static func response(method: AuthMethod) -> Data {
            return Data([SOCKS5.version, method.rawValue])
        }
    }

    // MARK: - Connection Request

    struct Request {
        let command: Command
        let addressType: AddressType
        let destinationHost: String
        let destinationPort: UInt16

        init?(from data: Data) {
            guard data.count >= 4 else { return nil }
            guard data[0] == SOCKS5.version else { return nil }

            guard let cmd = Command(rawValue: data[1]) else { return nil }
            self.command = cmd

            // data[2] is reserved (0x00)

            guard let addrType = AddressType(rawValue: data[3]) else { return nil }
            self.addressType = addrType

            var offset = 4
            let host: String

            switch addressType {
            case .ipv4:
                guard data.count >= offset + 4 + 2 else { return nil }
                let ip = data[offset..<(offset + 4)]
                host = ip.map { String($0) }.joined(separator: ".")
                offset += 4

            case .domainName:
                guard data.count >= offset + 1 else { return nil }
                let domainLength = Int(data[offset])
                offset += 1
                guard data.count >= offset + domainLength + 2 else { return nil }
                guard let domain = String(data: data[offset..<(offset + domainLength)], encoding: .utf8) else {
                    return nil
                }
                host = domain
                offset += domainLength

            case .ipv6:
                guard data.count >= offset + 16 + 2 else { return nil }
                let ip = data[offset..<(offset + 16)]
                var parts: [String] = []
                for i in stride(from: 0, to: 16, by: 2) {
                    let value = UInt16(ip[ip.startIndex + i]) << 8 | UInt16(ip[ip.startIndex + i + 1])
                    parts.append(String(format: "%x", value))
                }
                host = parts.joined(separator: ":")
                offset += 16
            }

            self.destinationHost = host

            guard data.count >= offset + 2 else { return nil }
            self.destinationPort = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
        }
    }

    // MARK: - Response Builder

    static func response(reply: Reply, addressType: AddressType = .ipv4, bindAddress: String = "0.0.0.0", bindPort: UInt16 = 0) -> Data {
        var response = Data([
            SOCKS5.version,
            reply.rawValue,
            0x00,  // Reserved
            addressType.rawValue
        ])

        switch addressType {
        case .ipv4:
            let parts = bindAddress.split(separator: ".").compactMap { UInt8($0) }
            if parts.count == 4 {
                response.append(contentsOf: parts)
            } else {
                response.append(contentsOf: [0, 0, 0, 0])
            }

        case .domainName:
            let domainData = Data(bindAddress.utf8)
            response.append(UInt8(domainData.count))
            response.append(domainData)

        case .ipv6:
            // Simplified: just append 16 zero bytes
            response.append(contentsOf: [UInt8](repeating: 0, count: 16))
        }

        // Port in network byte order (big-endian)
        response.append(UInt8(bindPort >> 8))
        response.append(UInt8(bindPort & 0xFF))

        return response
    }
}
