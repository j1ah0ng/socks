import Foundation
import Network
import OSLog

private let logger = Logger(subsystem: "com.socksproxy", category: "ProxyManager")

/// Observable object managing the SOCKS proxy server state for SwiftUI
@MainActor
final class ProxyManager: ObservableObject {
    static let defaultPort: UInt16 = 1080

    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var activeConnections: [ConnectionStats] = []
    @Published var port: UInt16 = ProxyManager.defaultPort

    private var server: SOCKSServer?

    var proxyAddress: String {
        guard isRunning else { return "Not running" }
        if let hotspotIP = getHotspotIPAddress() {
            return "\(hotspotIP):\(port)"
        }
        return "0.0.0.0:\(port)"
    }

    var totalBytesIn: Int64 {
        activeConnections.reduce(0) { $0 + $1.bytesIn }
    }

    var totalBytesOut: Int64 {
        activeConnections.reduce(0) { $0 + $1.bytesOut }
    }

    func startProxy() {
        guard !isRunning else { return }

        errorMessage = nil
        server = SOCKSServer(port: port)

        server?.onStateChange = { [weak self] running in
            Task { @MainActor in
                self?.isRunning = running
            }
        }

        server?.onError = { [weak self] error in
            Task { @MainActor in
                self?.errorMessage = error.localizedDescription
            }
        }

        server?.onConnectionUpdate = { [weak self] stats in
            Task { @MainActor in
                self?.handleConnectionUpdate(stats)
            }
        }

        do {
            try server?.start()
            logger.info("Proxy started on port \(self.port)")
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to start proxy: \(error.localizedDescription)")
        }
    }

    func stopProxy() {
        server?.stop()
        server = nil
        activeConnections.removeAll()
        logger.info("Proxy stopped")
    }

    func toggleProxy() {
        if isRunning {
            stopProxy()
        } else {
            startProxy()
        }
    }

    private func handleConnectionUpdate(_ stats: ConnectionStats) {
        if let index = activeConnections.firstIndex(where: { $0.id == stats.id }) {
            if stats.state == .closed {
                activeConnections.remove(at: index)
            } else {
                activeConnections[index] = stats
            }
        } else if stats.state != .closed {
            activeConnections.append(stats)
        }
    }

    private func getHotspotIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return nil
        }

        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family

            // Check for IPv4 on bridge interface (hotspot)
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name.hasPrefix("bridge") || name == "ap0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                   &hostname, socklen_t(hostname.count),
                                   nil, 0, NI_NUMERICHOST) == 0 {
                        address = String(cString: hostname)
                        break
                    }
                }
            }
        }

        return address
    }
}

// MARK: - Formatting Helpers

extension ProxyManager {
    func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: bytes)
    }

    func formatDuration(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 {
            return "\(Int(interval))s"
        } else if interval < 3600 {
            return "\(Int(interval / 60))m"
        } else {
            return "\(Int(interval / 3600))h"
        }
    }
}
