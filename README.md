# SOCKS Proxy for iOS

A lightweight SOCKS5 proxy server that runs on your iPhone, enabling devices connected to your phone's hotspot to tunnel their traffic through your cellular connection.

## Use Case

**Privacy through your iPhone**: When you share your iPhone's hotspot, connected devices can route their traffic through a SOCKS proxy running on your phone. This is useful for:

- Routing laptop traffic through your phone's cellular connection
- Adding a layer of privacy for hotspot clients
- Debugging network traffic from connected devices

## How It Works

```
┌─────────────┐     WiFi Hotspot     ┌─────────────┐     Cellular     ┌──────────────┐
│   Laptop    │ ──────────────────▶  │   iPhone    │ ──────────────▶  │   Internet   │
│(172.20.10.x)│    SOCKS5 Proxy     │(172.20.10.1)│                   │              │
└─────────────┘                      └─────────────┘                   └──────────────┘
```

1. iPhone creates a WiFi hotspot (typically on 172.20.10.0/24 network)
2. iPhone runs SOCKS5 proxy server on port 1080
3. Connected devices configure their apps to use proxy at `172.20.10.1:1080`
4. All proxied traffic flows through the iPhone's cellular connection

## Features

- **SOCKS5 Protocol**: Full SOCKS5 CONNECT support for TCP connections (RFC 1928)
- **Background Mode**: Uses location services to keep proxy running when app is backgrounded
- **No Authentication**: Simple setup for trusted local hotspot network
- **Persistent Settings**: Port configuration saved across app launches
- **Clean UI**: Simple SwiftUI interface to start/stop proxy and configure background mode

## Requirements

- iPhone running iOS 17.0 or later
- Xcode 15+ (for building)
- Apple Developer account (for device deployment)

## Building

### From Xcode (Recommended)

1. Open `SOCKSProxy.xcodeproj` in Xcode
2. Select your development team in Signing & Capabilities
3. Connect your iPhone and select it as the run destination
4. Build and run (⌘R)

### From Command Line

```bash
# Build for device
xcodebuild -project SOCKSProxy.xcodeproj \
           -target SOCKSProxy \
           -sdk iphoneos \
           -configuration Debug \
           build

# Build for simulator
xcodebuild -project SOCKSProxy.xcodeproj \
           -target SOCKSProxy \
           -sdk iphonesimulator \
           -configuration Debug \
           build

# Install to simulator
xcrun simctl install "iPhone 17 Pro" build/Debug-iphonesimulator/SOCKSProxy.app
xcrun simctl launch "iPhone 17 Pro" com.example.SOCKSProxy
```

## Usage

### On Your iPhone

1. Open the SOCKS Proxy app
2. Tap **Start** to begin listening on port 1080
3. Enable **Run in Background** toggle if you want proxy to stay active when app is backgrounded
4. Grant "Always" location permission when prompted (required for background mode)
5. Enable Personal Hotspot in Settings
6. Note the proxy address shown (typically `172.20.10.1:1080`)

### On Connected Devices

Configure your applications to use the SOCKS5 proxy:

**macOS System Proxy:**
```
System Settings → Network → WiFi → Details → Proxies → SOCKS Proxy
Server: 172.20.10.1
Port: 1080
```

**curl:**
```bash
curl --socks5 172.20.10.1:1080 https://example.com
```

**SSH:**
```bash
ssh -o ProxyCommand='nc -X 5 -x 172.20.10.1:1080 %h %p' user@remote.host
```

**Firefox:**
```
Settings → Network Settings → Manual proxy → SOCKS Host: 172.20.10.1:1080
```

**Chrome (via command line):**
```bash
/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome --proxy-server="socks5://172.20.10.1:1080"
```

### TTL Configuration (Optional)

To fully mask proxied traffic origin, set your packet TTL to 65 on the connected device:

**macOS:**
```bash
sudo sysctl net.inet.ip.ttl=65    # Set default TTL for IPv4 packets
sudo sysctl net.inet6.ip6.hlim=65 # Set default TTL for IPv6 packets
```

**Linux:**
```bash
sudo sysctl -w net.ipv4.ip_default_ttl=65    # Set default TTL for IPv4 packets
sudo sysctl -w net.ipv6.conf.all.hop_limit=65 # Set default TTL for IPv6 packets
```

This ensures packets leaving your device have the same TTL as if they originated from the iPhone itself.

## Background Mode

The app uses iOS location services to remain active in the background. When enabled:

- A blue location indicator appears in the status bar
- Uses lowest accuracy (`kCLLocationAccuracyThreeKilometers`) for minimal battery impact
- Your location is **not** stored or transmitted - it's only used to keep iOS from suspending the app

To enable:
1. Toggle "Run in Background" in the app
2. Grant "Always" location permission when prompted

## Architecture

The app uses Apple's Network.framework for modern, efficient networking:

- **NWListener**: Accepts incoming proxy connections on port 1080
- **NWConnection**: Handles both client and upstream server connections
- **SwiftUI**: Reactive UI with real-time proxy status
- **CoreLocation**: Background execution via location services

### SOCKS5 Protocol

The server implements RFC 1928 (SOCKS5) with:
- Method selection (no authentication)
- CONNECT command for TCP proxying
- IPv4, IPv6, and domain name address types

## Limitations

- **TCP only**: UDP ASSOCIATE and BIND commands are not implemented
- **No encryption**: SOCKS5 itself doesn't encrypt traffic - use with HTTPS/TLS applications
- **Hotspot required**: The proxy is only useful when sharing your hotspot
- **Location permission**: Background mode requires "Always" location access

## Project Structure

```
socks/
├── SOCKSProxy.xcodeproj/
├── Sources/
│   ├── App/
│   │   ├── SOCKSProxyApp.swift      # App entry point
│   │   ├── ContentView.swift         # Main UI
│   │   └── ProxyManager.swift        # Server state + background mode
│   └── Proxy/
│       ├── SOCKSServer.swift         # NWListener server
│       ├── SOCKSConnection.swift     # Per-connection handler
│       └── SOCKS5Protocol.swift      # Protocol implementation
├── Resources/
│   ├── Info.plist                    # App config + permissions
│   └── Assets.xcassets/              # App icon
├── README.md
├── CLAUDE.md
└── .gitignore
```

## License

MIT License
