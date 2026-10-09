import Foundation
import Network
@preconcurrency import CoreLocation
import OSLog

private let logger = Logger(subsystem: "com.socksproxy", category: "ProxyManager")

/// Observable object managing the SOCKS proxy server state for SwiftUI
@MainActor
final class ProxyManager: NSObject, ObservableObject {
    static let defaultPort: UInt16 = 1080
    private static let portKey = "SOCKSProxyPort"
    private static let backgroundKey = "SOCKSProxyBackground"

    /// Whether the user has started the proxy. The listener may briefly be down while
    /// it recovers from a failure; see `isListening`.
    @Published private(set) var isRunning = false
    /// Whether the listener is currently accepting connections.
    @Published private(set) var isListening = false
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
    /// Whether location updates are running to keep the app alive in the background.
    @Published private(set) var backgroundActive = false
    @Published private(set) var locationAuthStatus: CLAuthorizationStatus = .notDetermined

    // Triggers SwiftUI refresh when network changes
    @Published private(set) var networkStateToken = 0

    private var server: SOCKSServer?
    private var locationManager: CLLocationManager?
    private var backgroundSession: CLBackgroundActivitySession?
    private var pathMonitor: NWPathMonitor?

    /// The proxy's address on the Personal Hotspot interface, if the hotspot is up.
    var hotspotAddress: String? {
        // Access token to trigger SwiftUI refresh on network changes
        _ = networkStateToken
        return getHotspotIPAddress().map { "\($0):\(port)" }
    }

    override init() {
        let savedPort = UserDefaults.standard.integer(forKey: Self.portKey)
        let port = (1...Int(UInt16.max)).contains(savedPort) ? UInt16(savedPort) : Self.defaultPort
        let backgroundEnabled = UserDefaults.standard.bool(forKey: Self.backgroundKey)

        // Initialize stored properties before super.init()
        self._port = Published(wrappedValue: port)
        self._backgroundEnabled = Published(wrappedValue: backgroundEnabled)

        super.init()
    }

    func startProxy() {
        guard server == nil else { return }

        errorMessage = nil
        let server: SOCKSServer
        do {
            server = try SOCKSServer(port: port)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        server.onListeningChange = { [weak self] listening in
            self?.isListening = listening
            if listening {
                self?.errorMessage = nil
            }
        }
        server.onError = { [weak self] error in
            self?.errorMessage = error.localizedDescription
        }

        self.server = server
        server.start()
        isRunning = true
        startNetworkMonitor()
        updateBackgroundMode()
        logger.info("Proxy started on port \(self.port)")
    }

    func stopProxy() {
        server?.stop()
        server = nil
        isRunning = false
        isListening = false
        errorMessage = nil
        stopNetworkMonitor()
        updateBackgroundMode()
        logger.info("Proxy stopped")
    }

    func toggleProxy() {
        if isRunning {
            stopProxy()
        } else {
            startProxy()
        }
    }

    // MARK: - Network Monitor

    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            MainActor.assumeIsolated {
                self?.networkStateToken += 1
            }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }

    private func stopNetworkMonitor() {
        pathMonitor?.cancel()
        pathMonitor = nil
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

        let manager = CLLocationManager()
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = 1000 // meters
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
        manager.delegate = self
        locationManager = manager

        // Marks the app as actively in use while backgrounded. Must be created while the
        // app is in the foreground. Per Apple, this lets location updates (and therefore
        // the app) continue in the background even with only "When In Use" authorization.
        backgroundSession = CLBackgroundActivitySession()

        let status = manager.authorizationStatus
        logger.info("Background mode starting, auth status: \(status.rawValue)")
        if status == .notDetermined || status == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }
        applyAuthorization(status)
    }

    private func stopBackgroundMode() {
        guard locationManager != nil else { return }
        locationManager?.stopUpdatingLocation()
        locationManager = nil
        backgroundSession?.invalidate()
        backgroundSession = nil
        backgroundActive = false
        logger.info("Background mode disabled")
    }

    private func applyAuthorization(_ status: CLAuthorizationStatus) {
        locationAuthStatus = status
        guard let manager = locationManager else { return }

        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
            backgroundActive = true
        case .denied, .restricted:
            logger.error("Location access denied/restricted")
            manager.stopUpdatingLocation()
            backgroundActive = false
        default:
            backgroundActive = false
        }
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
            guard let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: interface.ifa_name)
            if name.hasPrefix("bridge") || name == "ap0" {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                               &hostname, socklen_t(hostname.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    address = String(cString: hostname)
                    break
                }
            }
        }

        return address
    }
}

// MARK: - CLLocationManagerDelegate

// CLLocationManager delivers delegate callbacks on the thread it was created on, which
// is always the main thread here.
extension ProxyManager: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // We don't need the location, just the background execution time
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        logger.info("Authorization changed to: \(status.rawValue)")
        MainActor.assumeIsolated {
            applyAuthorization(status)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Ignore errors - we don't actually need accurate location
        logger.debug("Location error (ignored): \(error.localizedDescription)")
    }
}
