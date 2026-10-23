import SwiftUI
import NetworkExtension

struct ContentView: View {
    @StateObject private var manager = VPNManager.shared
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: statusIcon)
                    .font(.system(size: 24))
                    .foregroundColor(statusColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(statusText)
                        .font(.system(size: 14, weight: .semibold))
                    if let error = manager.lastError {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                            .lineLimit(2)
                    }
                }

                Spacer()

                Button(action: { showSettings.toggle() }) {
                    Image(systemName: "gear")
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            // Metrics
            if manager.isConnected {
                VStack(spacing: 12) {
                    MetricRow(label: "Upload", value: formatSpeed(manager.uploadSpeed))
                    MetricRow(label: "Download", value: formatSpeed(manager.downloadSpeed))
                    MetricRow(label: "Total Sent", value: formatBytes(manager.bytesSent))
                    MetricRow(label: "Total Received", value: formatBytes(manager.bytesReceived))
                    MetricRow(label: "Connected", value: formatDuration(manager.connectedDuration))
                }
                .padding()

                Divider()
            }

            // Connect button
            Button(action: { manager.toggleConnection() }) {
                Text(manager.isConnected ? "Disconnect" : "Connect")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(manager.isConnected ? .red : .blue)
            .disabled(manager.isConnecting)
            .padding()
        }
        .frame(width: 320)
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }

    private var statusIcon: String {
        if manager.isConnected { return "checkmark.shield.fill" }
        if manager.isConnecting { return "arrow.triangle.2.circlepath" }
        return "xmark.shield"
    }

    private var statusColor: Color {
        if manager.isConnected { return .green }
        if manager.isConnecting { return .orange }
        return .gray
    }

    private var statusText: String {
        if manager.isConnected { return "Connected" }
        if manager.isConnecting { return "Connecting..." }
        return "Disconnected"
    }

    private func formatSpeed(_ bytesPerSec: UInt64) -> String {
        let kb = Double(bytesPerSec) / 1024
        if kb < 1024 {
            return String(format: "%.1f KB/s", kb)
        }
        return String(format: "%.2f MB/s", kb / 1024)
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        if mb < 1024 {
            return String(format: "%.1f MB", mb)
        }
        return String(format: "%.2f GB", mb / 1024)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

struct MetricRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
        }
    }
}
