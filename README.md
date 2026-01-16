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
│ (172.20.10.x)│    SOCKS5 Proxy    │(172.20.10.1)│                   │              │
└─────────────┘                      └─────────────┘                   └──────────────┘
```

1. iPhone creates a WiFi hotspot (typically on 172.20.10.0/24 network)
2. iPhone runs SOCKS5 proxy server on port 1080
3. Connected devices configure their apps to use proxy at `172.20.10.1:1080`
4. All proxied traffic flows through the iPhone's cellular connection

## Features

- **SOCKS5 Protocol**: Full SOCKS5 CONNECT support for TCP connections
- **No Authentication**: Simple setup for trusted local hotspot network
- **Connection Logging**: See active connections and transfer statistics
- **Clean UI**: Simple SwiftUI interface to start/stop the proxy

## Requirements

- iPhone running iOS 17.0 or later
- Xcode 15+ (for building)
- Apple Developer account (for device deployment)

## Building

### From Xcode

1. Open `SOCKSProxy.xcodeproj` in Xcode
2. Select your development team in Signing & Capabilities
3. Connect your iPhone and select it as the run destination
4. Build and run (⌘R)

### From Command Line

```bash
# List available devices
xcrun xctrace list devices

# Build for a specific device
xcodebuild -project SOCKSProxy.xcodeproj \
           -scheme SOCKSProxy \
           -configuration Debug \
           -destination 'platform=iOS,id=<DEVICE_UDID>' \
           build
```

## Usage

### On Your iPhone

1. Open the SOCKS Proxy app
2. Tap "Start Proxy" to begin listening on port 1080
3. Enable Personal Hotspot in Settings
4. Note the proxy address shown (typically `172.20.10.1:1080`)

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

## Architecture

The app uses Apple's Network.framework for efficient, modern networking:

- **NWListener**: Accepts incoming proxy connections
- **NWConnection**: Handles both client and target connections
- **SwiftUI**: Reactive UI with real-time connection status

### SOCKS5 Protocol

The server implements RFC 1928 (SOCKS5) with:
- Method selection (no authentication)
- CONNECT command for TCP proxying
- IPv4 and domain name address types

## Limitations

- **Background execution**: iOS may suspend the app when backgrounded. Keep the app in foreground for reliable operation.
- **TCP only**: UDP ASSOCIATE and BIND commands are not implemented
- **No encryption**: SOCKS5 itself doesn't encrypt traffic - use with HTTPS/TLS applications
- **Hotspot required**: The proxy is only useful when sharing your hotspot

## License

MIT License - See LICENSE file for details
