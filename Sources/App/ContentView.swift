import SwiftUI

struct ContentView: View {
    @StateObject private var proxyManager = ProxyManager()
    @State private var showingInfo = false
    @State private var portText: String = ""

    var body: some View {
        NavigationStack {
            List {
                statusSection
                portSection
                addressSection
                backgroundSection
            }
            .navigationTitle("SOCKS Proxy")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                }
            }
            .sheet(isPresented: $showingInfo) {
                InfoView()
            }
            .onAppear {
                portText = String(proxyManager.port)
            }
        }
    }

    // MARK: - Sections

    private var statusSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Proxy Status")
                        .font(.headline)
                    Text(proxyManager.isRunning ? "Running" : "Stopped")
                        .font(.subheadline)
                        .foregroundStyle(proxyManager.isRunning ? .green : .secondary)
                }

                Spacer()

                Button {
                    proxyManager.toggleProxy()
                } label: {
                    Text(proxyManager.isRunning ? "Stop" : "Start")
                        .fontWeight(.semibold)
                        .frame(minWidth: 80)
                }
                .buttonStyle(.borderedProminent)
                .tint(proxyManager.isRunning ? .red : .green)
            }
            .padding(.vertical, 4)

            if let error = proxyManager.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var portSection: some View {
        Section {
            HStack {
                Text("Port")
                Spacer()
                TextField("1080", text: $portText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .disabled(proxyManager.isRunning)
                    .onChange(of: portText) { _, newValue in
                        if let newPort = UInt16(newValue), newPort > 0 {
                            proxyManager.port = newPort
                        }
                    }
            }
        } footer: {
            if proxyManager.isRunning {
                Text("Stop the proxy to change port")
            }
        }
    }

    private var addressSection: some View {
        Section("Proxy Address") {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(proxyManager.proxyAddress)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.medium)
                    Text("Configure clients to use this SOCKS5 proxy")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if proxyManager.isRunning {
                    Button {
                        UIPasteboard.general.string = proxyManager.proxyAddress
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private var backgroundSection: some View {
        Section {
            Toggle("Run in Background", isOn: $proxyManager.backgroundEnabled)

            if proxyManager.backgroundEnabled && proxyManager.backgroundActive {
                HStack {
                    Image(systemName: "location.fill")
                        .foregroundStyle(.blue)
                    Text("Background mode active")
                        .font(.caption)
                }
            }
        } footer: {
            Text("Requires \"Always\" location permission. Uses minimal battery (3km accuracy).")
        }
    }
}

// MARK: - Info View

struct InfoView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Usage") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. Start the proxy server")
                        Text("2. Enable Personal Hotspot")
                        Text("3. Connect device to hotspot")
                        Text("4. Configure device to use SOCKS5 proxy")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                Section("TTL Configuration") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("To fully mask proxied traffic origin, run on the connected device:")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("macOS:")
                                .font(.caption)
                                .fontWeight(.medium)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("sudo sysctl net.inet.ip.ttl=65")
                                Text("sudo sysctl net.inet6.ip6.hlim=65")
                            }
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Linux:")
                                .font(.caption)
                                .fontWeight(.medium)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("sudo sysctl -w net.ipv4.ip_default_ttl=65")
                                Text("sudo sysctl -w net.ipv6.conf.all.hop_limit=65")
                            }
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                        }
                    }
                }

                Section("About") {
                    LabeledContent("Protocol", value: "SOCKS5")
                    LabeledContent("Authentication", value: "None")
                }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
