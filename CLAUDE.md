# CLAUDE.md - Project Intelligence for SOCKS Proxy iOS App

## Project Overview
This is an iOS app that runs a SOCKS5 proxy server on the iPhone. The primary use case is privacy: devices connected to the iPhone's hotspot can tunnel their traffic through the phone via the SOCKS proxy.

## Architecture

### Core Components
1. **SOCKSServer** (`Sources/Proxy/SOCKSServer.swift`) - Main server using Network.framework's NWListener
2. **SOCKSConnection** (`Sources/Proxy/SOCKSConnection.swift`) - Handles individual client connections and SOCKS5 protocol
3. **SOCKS5Protocol** (`Sources/Proxy/SOCKS5Protocol.swift`) - Protocol parsing and message construction
4. **ProxyManager** (`Sources/App/ProxyManager.swift`) - ObservableObject managing server state for SwiftUI

### Network Architecture
- Server listens on `0.0.0.0` (all interfaces) to be accessible from hotspot clients
- Default port: 1080 (standard SOCKS port)
- Hotspot network is typically `172.20.10.x` with iPhone at `172.20.10.1`
- Uses Network.framework (NWListener, NWConnection) for modern async networking

### SOCKS5 Protocol Flow
1. Client connects → Server accepts
2. Client sends auth methods → Server responds (no-auth: 0x00)
3. Client sends CONNECT request → Server connects to target
4. Server sends success/failure → Data relay begins

## Code Patterns

### Swift Conventions
- Use `async/await` where possible
- Network.framework uses callback-based API - wrap in continuation when needed
- All UI updates via `@MainActor`
- Use `OSLog` for logging, not print statements

### Error Handling
- Network errors should be logged but not crash the app
- Individual connection failures shouldn't affect the server
- Use Swift's Result type or throwing functions

## Build & Run

### Requirements
- Xcode 15+
- iOS 17+ deployment target
- Physical device for testing (hotspot not available in simulator)

### Build Commands
```bash
# Build from command line
xcodebuild -project SOCKSProxy.xcodeproj -scheme SOCKSProxy -configuration Debug -destination 'platform=iOS,name=<DeviceName>' build

# Or open in Xcode
open SOCKSProxy.xcodeproj
```

### Testing the Proxy
1. Enable iPhone hotspot
2. Connect test device to hotspot
3. Start proxy in app
4. Configure test device to use SOCKS proxy at 172.20.10.1:1080

## File Structure
```
socks/
├── SOCKSProxy.xcodeproj/
├── Sources/
│   ├── App/
│   │   ├── SOCKSProxyApp.swift      # App entry point
│   │   ├── ContentView.swift         # Main UI
│   │   └── ProxyManager.swift        # Server state management
│   └── Proxy/
│       ├── SOCKSServer.swift         # NWListener server
│       ├── SOCKSConnection.swift     # Per-connection handler
│       └── SOCKS5Protocol.swift      # Protocol implementation
├── Resources/
│   └── Info.plist
├── README.md
└── CLAUDE.md
```

## Common Tasks

### Adding new SOCKS commands
Edit `SOCKS5Protocol.swift` - add to the Command enum and handle in SOCKSConnection

### Changing default port
Modify `ProxyManager.swift` - the `defaultPort` property

### Adding authentication
1. Add auth method to `SOCKS5Protocol.swift`
2. Handle auth exchange in `SOCKSConnection.swift`
3. Add UI for credentials in `ContentView.swift`

## Gotchas
- iOS may kill background network servers - app should handle restart gracefully
- Hotspot interface name varies by iOS version (bridge100, bridge101, etc.)
- Simulator cannot test hotspot functionality - use physical device
- Some traffic may bypass proxy (system traffic, certain apps)
