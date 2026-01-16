import SwiftUI

struct ContentView: View {
    @StateObject private var proxyManager = ProxyManager()
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            List {
                statusSection
                addressSection
                statisticsSection
                connectionsSection
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

    private var statisticsSection: some View {
        Section("Statistics") {
            LabeledContent("Active Connections") {
                Text("\(proxyManager.activeConnections.count)")
                    .fontWeight(.medium)
            }

            LabeledContent("Data In") {
                Text(proxyManager.formatBytes(proxyManager.totalBytesIn))
                    .fontWeight(.medium)
            }

            LabeledContent("Data Out") {
                Text(proxyManager.formatBytes(proxyManager.totalBytesOut))
                    .fontWeight(.medium)
            }
        }
    }

    @ViewBuilder
    private var connectionsSection: some View {
        if !proxyManager.activeConnections.isEmpty {
            Section("Active Connections") {
                ForEach(proxyManager.activeConnections) { connection in
                    ConnectionRow(connection: connection, proxyManager: proxyManager)
                }
            }
        }
    }
}

// MARK: - Connection Row

struct ConnectionRow: View {
    let connection: ConnectionStats
    let proxyManager: ProxyManager

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let host = connection.destinationHost, let port = connection.destinationPort {
                Text("\(host):\(port)")
                    .font(.system(.subheadline, design: .monospaced))
            } else {
                Text("Handshaking...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Label(proxyManager.formatBytes(connection.bytesIn), systemImage: "arrow.down")
                Label(proxyManager.formatBytes(connection.bytesOut), systemImage: "arrow.up")
                Label(proxyManager.formatDuration(connection.startTime), systemImage: "clock")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
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
