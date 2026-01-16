import Foundation
import Network
@preconcurrency import CoreLocation
import UIKit
import OSLog

private let logger = Logger(subsystem: "com.socksproxy", category: "ProxyManager")

/// Observable object managing the SOCKS proxy server state for SwiftUI
final class ProxyManager: NSObject, ObservableObject {
    static let defaultPort: UInt16 = 1080
    private static let portKey = "SOCKSProxyPort"
    private static let backgroundKey = "SOCKSProxyBackground"

    @MainActor @Published private(set) var isRunning = false
    @MainActor @Published private(set) var errorMessage: String?
    @MainActor @Published var port: UInt16 {
        didSet {
            UserDefaults.standard.set(Int(port), forKey: Self.portKey)
        }
    }
    @MainActor @Published var backgroundEnabled: Bool {
        didSet {
            UserDefaults.standard.set(backgroundEnabled, forKey: Self.backgroundKey)
            updateBackgroundMode()
        }
    }
    @MainActor @Published private(set) var backgroundActive = false

    private var server: SOCKSServer?
    private var locationManager: CLLocationManager?

    @MainActor
    var proxyAddress: String {
        guard isRunning else { return "Not running" }
        if let hotspotIP = getHotspotIPAddress() {
            return "\(hotspotIP):\(port)"
        }
        return "0.0.0.0:\(port)"
    }

    override init() {
        let savedPort = UserDefaults.standard.integer(forKey: Self.portKey)
        let port = savedPort > 0 ? UInt16(savedPort) : Self.defaultPort
        let backgroundEnabled = UserDefaults.standard.bool(forKey: Self.backgroundKey)

        // Initialize stored properties before super.init()
        self._port = Published(wrappedValue: port)
        self._backgroundEnabled = Published(wrappedValue: backgroundEnabled)

        super.init()
    }

    @MainActor
    func startProxy() {
        guard !isRunning else { return }

        errorMessage = nil
        server = SOCKSServer(port: port)

        server?.onStateChange = { [weak self] running in
            DispatchQueue.main.async {
                self?.isRunning = running
            }
        }

        server?.onError = { [weak self] error in
            DispatchQueue.main.async {
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

    @MainActor
    func stopProxy() {
        server?.stop()
        server = nil
        stopBackgroundMode()
        logger.info("Proxy stopped")
    }

    @MainActor
    func toggleProxy() {
        if isRunning {
            stopProxy()
        } else {
            startProxy()
        }
    }

    // MARK: - Background Mode

    @MainActor
    private func updateBackgroundMode() {
        if backgroundEnabled && isRunning {
            startBackgroundMode()
        } else {
            stopBackgroundMode()
        }
    }

    @MainActor
    private func startBackgroundMode() {
        guard locationManager == nil else { return }

        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = 1000 // meters
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
        locationManager = manager

        // Check current authorization and act accordingly
        let status = manager.authorizationStatus
        logger.info("Background mode starting, current auth status: \(status.rawValue)")

        switch status {
        case .authorizedAlways:
            logger.info("Already authorized always - starting location updates")
            manager.startUpdatingLocation()
        case .authorizedWhenInUse:
            logger.info("Authorized when in use - requesting always, starting updates")
            manager.requestAlwaysAuthorization()
            manager.startUpdatingLocation()
        case .notDetermined:
            logger.info("Not determined - requesting always authorization")
            manager.requestAlwaysAuthorization()
        case .denied, .restricted:
            logger.error("Location access denied/restricted")
            errorMessage = "Location access required for background mode"
            backgroundEnabled = false
        @unknown default:
            manager.requestAlwaysAuthorization()
        }
    }

    @MainActor
    private func stopBackgroundMode() {
        locationManager?.stopUpdatingLocation()
        locationManager = nil
        backgroundActive = false
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
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // We don't need the location, just the background execution time
        logger.debug("Location update (keeping alive)")

        // Only update UI state when app is active to avoid concurrency issues
        DispatchQueue.main.async { [weak self] in
            guard UIApplication.shared.applicationState == .active else { return }
            if self?.backgroundActive == false {
                self?.backgroundActive = true
                logger.info("Background mode now active")
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        logger.info("Authorization changed to: \(status.rawValue)")

        // Start location updates immediately (don't wait for main queue)
        if status == .authorizedAlways || status == .authorizedWhenInUse {
            manager.startUpdatingLocation()
        }

        // Update UI only when app is active
        DispatchQueue.main.async { [weak self] in
            guard UIApplication.shared.applicationState == .active else { return }
            switch status {
            case .authorizedWhenInUse:
                logger.warning("Only 'When In Use' - grant 'Always' for reliable background operation.")
            case .denied, .restricted:
                logger.error("Location access denied")
                self?.errorMessage = "Location access required for background mode"
                self?.backgroundEnabled = false
            default:
                break
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Ignore errors - we don't actually need accurate location
        logger.debug("Location error (ignored): \(error.localizedDescription)")
    }
}
