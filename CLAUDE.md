# CLAUDE.md - Project Intelligence for SOCKS Proxy iOS App

## Project Overview

iOS app that runs a SOCKS5 proxy server on the iPhone. Primary use case: privacy for devices connected to the iPhone's hotspot, tunneling their traffic through the phone's cellular connection.

## Architecture

### Core Components

| File | Purpose |
|------|---------|
| `Sources/App/SOCKSProxyApp.swift` | SwiftUI app entry point |
| `Sources/App/ContentView.swift` | Main UI with start/stop and background toggle |
| `Sources/App/ProxyManager.swift` | Server lifecycle, background mode via CoreLocation |
| `Sources/Proxy/SOCKSServer.swift` | NWListener-based TCP server on port 1080 |
| `Sources/Proxy/SOCKSConnection.swift` | Per-connection SOCKS5 state machine |
| `Sources/Proxy/SOCKS5Protocol.swift` | RFC 1928 protocol parsing/construction |

### Network Flow

```
Client (laptop) → NWListener (iPhone:1080) → SOCKSConnection → NWConnection → Target Server
```

1. `SOCKSServer` accepts connections via `NWListener`
2. Each connection spawns a `SOCKSConnection` instance
3. `SOCKSConnection` handles SOCKS5 handshake (greeting → auth → request)
4. On CONNECT, creates `NWConnection` to target and relays bidirectionally

### Background Execution

Uses `CLLocationManager` to prevent iOS from suspending the app:
- `kCLLocationAccuracyThreeKilometers` - lowest power GPS mode
- `distanceFilter = 1000` - minimal location updates
- `allowsBackgroundLocationUpdates = true` - keeps app alive
- Requires `UIBackgroundModes: location` in Info.plist
- Requires `NSLocationAlwaysAndWhenInUseUsageDescription`

### Data Persistence

UserDefaults keys:
- `SOCKSProxyPort` - server port (default 1080)
- `SOCKSProxyBackground` - background mode enabled

## Build Commands

```bash
# Device build
xcodebuild -project SOCKSProxy.xcodeproj -target SOCKSProxy -sdk iphoneos -configuration Debug build

# Simulator build
xcodebuild -project SOCKSProxy.xcodeproj -target SOCKSProxy -sdk iphonesimulator -configuration Debug build

# Run in simulator
xcrun simctl boot "iPhone 17 Pro"
xcrun simctl install "iPhone 17 Pro" build/Debug-iphonesimulator/SOCKSProxy.app
xcrun simctl launch "iPhone 17 Pro" com.example.SOCKSProxy
```

## SOCKS5 Protocol Quick Reference

### Handshake
```
Client → Server: [0x05, nMethods, ...methods]
Server → Client: [0x05, selectedMethod]  // 0x00 = no auth
```

### Connect Request
```
Client → Server: [0x05, 0x01, 0x00, addrType, ...addr, portHi, portLo]
Server → Client: [0x05, reply, 0x00, addrType, ...bindAddr, portHi, portLo]
```

Address types: `0x01` = IPv4, `0x03` = domain, `0x04` = IPv6

## Code Patterns

### Threading Model
- `SOCKSServer` uses dedicated `DispatchQueue` for network operations
- UI updates dispatched to `@MainActor` via `Task { @MainActor in ... }`
- `CLLocationManagerDelegate` methods are `nonisolated`, hop to MainActor for state updates

### Network.framework Usage
```swift
// Server
let listener = try NWListener(using: .tcp, on: port)
listener.newConnectionHandler = { connection in ... }
listener.start(queue: queue)

// Connection
let conn = NWConnection(to: endpoint, using: .tcp)
conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in ... }
conn.send(content: data, completion: .contentProcessed { error in ... })
```

## Common Tasks

### Change Default Port
Edit `ProxyManager.swift`:
```swift
static let defaultPort: UInt16 = 1080  // Change this
```

### Add SOCKS5 Authentication
1. Add auth method to `SOCKS5Protocol.swift` `AuthMethod` enum
2. Handle auth exchange after greeting in `SOCKSConnection.handleGreeting()`
3. Add UI for credentials in `ContentView.swift`

### Add UDP Support
1. Add `udpAssociate` case handling in `SOCKSConnection.handleRequest()`
2. Create UDP relay using `NWConnection` with `.udp` parameters
3. Handle UDP encapsulation per RFC 1928 section 7

## Testing

### Local Testing (Mac connected to hotspot)
```bash
# Test connectivity
curl -v --socks5 172.20.10.1:1080 https://httpbin.org/ip

# Test with netcat
nc -X 5 -x 172.20.10.1:1080 example.com 80
```

### Simulator Limitations
- No hotspot interface (bridge0) in simulator
- Proxy starts but isn't reachable from host
- Use physical device for full testing

## Gotchas

1. **Hotspot IP**: Usually `172.20.10.1` but can vary. App detects via `getifaddrs()` looking for `bridge*` or `ap0` interface.

2. **Background Mode**: Requires "Always" location permission. "When In Use" allows some background time but iOS will eventually suspend.

3. **Code Signing**: Free Apple Developer accounts work but apps expire after 7 days. Paid accounts last 1 year.

4. **Network Extension**: This app does NOT use NetworkExtension.framework (VPN/content filter). It's a simple userspace TCP server, which works fine for the hotspot use case.

## File Permissions (Info.plist)

Required keys:
- `NSLocalNetworkUsageDescription` - local network access
- `NSLocationAlwaysAndWhenInUseUsageDescription` - background location
- `NSLocationWhenInUseUsageDescription` - foreground location
- `UIBackgroundModes: [location]` - background execution
