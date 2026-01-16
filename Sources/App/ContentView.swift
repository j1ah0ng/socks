import SwiftUI

struct ContentView: View {
    @StateObject private var proxyManager = ProxyManager()
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            List {
                statusSection
                addressSection
                backgroundSection
            }
            .navigationTitle("SOCKS Proxy")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gear")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView(port: $proxyManager.port, isRunning: proxyManager.isRunning)
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

            if proxyManager.backgroundEnabled {
                HStack {
                    Image(systemName: proxyManager.backgroundActive ? "location.fill" : "location")
                        .foregroundStyle(proxyManager.backgroundActive ? .blue : .secondary)
                    Text(proxyManager.backgroundActive ? "Background mode active" : "Waiting for location permission...")
                        .font(.caption)
                        .foregroundStyle(proxyManager.backgroundActive ? .primary : .secondary)
                }
            }
        } footer: {
            Text("Requires \"Always\" location permission. Uses minimal battery (3km accuracy).")
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var port: UInt16
    let isRunning: Bool
    @State private var portText: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Server Configuration") {
                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("1080", text: $portText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                            .disabled(isRunning)
                    }

                    if isRunning {
                        Text("Stop the proxy to change port")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

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

                Section("About") {
                    LabeledContent("Protocol", value: "SOCKS5")
                    LabeledContent("Authentication", value: "None")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if let newPort = UInt16(portText), newPort > 0 {
                            port = newPort
                        }
                        dismiss()
                    }
                }
            }
            .onAppear {
                portText = String(port)
            }
        }
    }
}

#Preview {
    ContentView()
}
