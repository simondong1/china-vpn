import Foundation
import NetworkExtension
import Combine

struct VPNConfig: Codable {
    var server: String
    var port: UInt16
    var uuid: String
    var publicKey: String
    var shortId: String
    var sni: String

    static var empty: VPNConfig {
        VPNConfig(server: "", port: 443, uuid: "", publicKey: "", shortId: "", sni: "")
    }
}

class VPNManager: ObservableObject {
    static let shared = VPNManager()

    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var lastError: String?
    @Published var uploadSpeed: UInt64 = 0
    @Published var downloadSpeed: UInt64 = 0
    @Published var bytesSent: UInt64 = 0
    @Published var bytesReceived: UInt64 = 0
    @Published var connectedDuration: TimeInterval = 0

    var config = VPNConfig.empty
    private var tunnelManager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?
    private var metricsTimer: Timer?
    private var connectionStartTime: Date?
    private var lastBytesSent: UInt64 = 0
    private var lastBytesReceived: UInt64 = 0

    private init() {
        loadTunnelManager()
    }

    func loadConfiguration() {
        let defaults = UserDefaults(suiteName: "group.com.vpn.client")
        if let data = defaults?.data(forKey: "vpn_config"),
           let decoded = try? JSONDecoder().decode(VPNConfig.self, from: data) {
            config = decoded
        }
    }

    func saveConfiguration() {
        let defaults = UserDefaults(suiteName: "group.com.vpn.client")
        if let encoded = try? JSONEncoder().encode(config) {
            defaults?.set(encoded, forKey: "vpn_config")
        }
    }

    private func loadTunnelManager() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            if let error = error {
                self?.lastError = "Failed to load VPN: \(error.localizedDescription)"
                return
            }

            self?.tunnelManager = managers?.first
            if self?.tunnelManager == nil {
                self?.createTunnelManager()
            } else {
                self?.observeStatus()
                self?.updateConnectionStatus()
            }
        }
    }

    private func createTunnelManager() {
        let manager = NETunnelProviderManager()
        manager.localizedDescription = "VPN"

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = "com.vpn.client.extension"
        proto.serverAddress = "VPN Server"
        manager.protocolConfiguration = proto
        manager.isEnabled = true

        manager.saveToPreferences { [weak self] error in
            if let error = error {
                self?.lastError = "Failed to save VPN: \(error.localizedDescription)"
                return
            }
            self?.tunnelManager = manager
            self?.observeStatus()
        }
    }

    private func observeStatus() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: tunnelManager?.connection,
            queue: .main
        ) { [weak self] _ in
            self?.updateConnectionStatus()
        }
        updateConnectionStatus()
    }

    private func updateConnectionStatus() {
        guard let status = tunnelManager?.connection.status else { return }

        DispatchQueue.main.async {
            switch status {
            case .connected:
                self.isConnected = true
                self.isConnecting = false
                self.lastError = nil
                self.startMetricsTimer()
                if self.connectionStartTime == nil {
                    self.connectionStartTime = Date()
                }
            case .connecting, .reasserting:
                self.isConnected = false
                self.isConnecting = true
                self.lastError = nil
            case .disconnected:
                self.isConnected = false
                self.isConnecting = false
                self.stopMetricsTimer()
                self.connectionStartTime = nil
            case .disconnecting:
                self.isConnected = false
                self.isConnecting = false
            case .invalid:
                self.isConnected = false
                self.isConnecting = false
                self.lastError = "Invalid configuration"
            @unknown default:
                break
            }
        }
    }

    func toggleConnection() {
        if isConnected {
            disconnect()
        } else {
            connect()
        }
    }

    private func connect() {
        guard !config.server.isEmpty && !config.uuid.isEmpty else {
            lastError = "Server configuration required"
            return
        }

        isConnecting = true
        lastError = nil

        // Validate configuration
        if config.publicKey.isEmpty {
            lastError = "Public key required"
            isConnecting = false
            return
        }

        // Pass config to extension via providerConfiguration
        let providerConfig: [String: Any] = [
            "server": config.server,
            "port": config.port,
            "uuid": config.uuid,
            "publicKey": config.publicKey,
            "shortId": config.shortId,
            "sni": config.sni
        ]

        tunnelManager?.protocolConfiguration?.as(NETunnelProviderProtocol.self)?.providerConfiguration = providerConfig
        tunnelManager?.saveToPreferences { [weak self] error in
            if let error = error {
                self?.lastError = "Save failed: \(error.localizedDescription)"
                self?.isConnecting = false
                return
            }

            do {
                try self?.tunnelManager?.connection.startVPNTunnel()
            } catch {
                self?.lastError = "Connect failed: \(error.localizedDescription)"
                self?.isConnecting = false
            }
        }
    }

    private func disconnect() {
        tunnelManager?.connection.stopVPNTunnel()
    }

    private func startMetricsTimer() {
        stopMetricsTimer()
        metricsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateMetrics()
        }
    }

    private func stopMetricsTimer() {
        metricsTimer?.invalidate()
        metricsTimer = nil
        uploadSpeed = 0
        downloadSpeed = 0
    }

    private func updateMetrics() {
        // Fetch stats from tunnel via IPC would go here
        // For now, simulate with connection duration
        if let startTime = connectionStartTime {
            connectedDuration = Date().timeIntervalSince(startTime)
        }

        // In real implementation, read from shared UserDefaults or IPC
        let defaults = UserDefaults(suiteName: "group.com.vpn.client")
        if let sent = defaults?.object(forKey: "bytes_sent") as? UInt64,
           let received = defaults?.object(forKey: "bytes_received") as? UInt64 {

            uploadSpeed = sent > lastBytesSent ? sent - lastBytesSent : 0
            downloadSpeed = received > lastBytesReceived ? received - lastBytesReceived : 0

            bytesSent = sent
            bytesReceived = received

            lastBytesSent = sent
            lastBytesReceived = received
        }
    }
}
