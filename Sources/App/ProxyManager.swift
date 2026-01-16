import Foundation
import Network
import CoreLocation
import OSLog

private let logger = Logger(subsystem: "com.socksproxy", category: "ProxyManager")

/// Observable object managing the SOCKS proxy server state for SwiftUI
@MainActor
final class ProxyManager: NSObject, ObservableObject {
    static let defaultPort: UInt16 = 1080
    private static let portKey = "SOCKSProxyPort"
    private static let backgroundKey = "SOCKSProxyBackground"

    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?
    @Published var port: UInt16 {
        didSet {
            UserDefaults.standard.set(Int(port), forKey: Self.portKey)
        }
    }
    @Published var backgroundEnabled: Bool {
        didSet {
            UserDefaults.standard.set(backgroundEnabled, forKey: Self.backgroundKey)
            updateBackgroundMode()
        }
    }

    private var server: SOCKSServer?
    private var locationManager: CLLocationManager?

    var proxyAddress: String {
        guard isRunning else { return "Not running" }
        if let hotspotIP = getHotspotIPAddress() {
            return "\(hotspotIP):\(port)"
        }
        return "0.0.0.0:\(port)"
    }

    override init() {
        let savedPort = UserDefaults.standard.integer(forKey: Self.portKey)
        self.port = savedPort > 0 ? UInt16(savedPort) : Self.defaultPort
        self.backgroundEnabled = UserDefaults.standard.bool(forKey: Self.backgroundKey)
        super.init()
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

        do {
            try server?.start()
            logger.info("Proxy started on port \(self.port)")
            updateBackgroundMode()
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to start proxy: \(error.localizedDescription)")
        }
    }

    func stopProxy() {
        server?.stop()
        server = nil
        stopBackgroundMode()
        logger.info("Proxy stopped")
    }

    func toggleProxy() {
        if isRunning {
            stopProxy()
        } else {
            startProxy()
        }
    }

    // MARK: - Background Mode

    private func updateBackgroundMode() {
        if backgroundEnabled && isRunning {
            startBackgroundMode()
        } else {
            stopBackgroundMode()
        }
    }

    private func startBackgroundMode() {
        guard locationManager == nil else { return }

        locationManager = CLLocationManager()
        locationManager?.delegate = self
        locationManager?.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        locationManager?.distanceFilter = 1000 // meters
        locationManager?.allowsBackgroundLocationUpdates = true
        locationManager?.pausesLocationUpdatesAutomatically = false

        // Request always authorization for background
        locationManager?.requestAlwaysAuthorization()

        logger.info("Background mode enabled via location services")
    }

    private func stopBackgroundMode() {
        locationManager?.stopUpdatingLocation()
        locationManager = nil
        logger.info("Background mode disabled")
    }

    // MARK: - Network Helpers

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

// MARK: - CLLocationManagerDelegate

extension ProxyManager: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // We don't need the location, just the background execution time
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedAlways:
                logger.info("Location always authorized - starting updates")
                manager.startUpdatingLocation()
            case .authorizedWhenInUse:
                logger.warning("Only authorized when in use - background mode limited")
                manager.startUpdatingLocation()
            case .denied, .restricted:
                logger.error("Location access denied")
                self.errorMessage = "Location access required for background mode"
                self.backgroundEnabled = false
            case .notDetermined:
                logger.info("Location authorization not determined")
            @unknown default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        logger.error("Location error: \(error.localizedDescription)")
    }
}
