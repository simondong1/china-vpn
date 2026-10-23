import NetworkExtension
import Foundation

class PacketTunnelProvider: NEPacketTunnelProvider {
    private var xrayTask: Process?
    private var configPath: String?
    private var socksPort: UInt16 = 10808
    private var tunnelTask: Process?
    private var bytesSent: UInt64 = 0
    private var bytesReceived: UInt64 = 0

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        NSLog("VPN: Starting tunnel")

        guard let config = extractConfig() else {
            completionHandler(NSError(domain: "VPN", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing configuration"]))
            return
        }

        // Validate config
        guard !config.server.isEmpty, !config.uuid.isEmpty, !config.publicKey.isEmpty else {
            completionHandler(NSError(domain: "VPN", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid configuration"]))
            return
        }

        // Test connectivity first
        testConnectivity(to: config.server, port: config.port) { [weak self] success, error in
            guard success else {
                let msg = error ?? "Cannot reach server"
                NSLog("VPN: Pre-check failed: \(msg)")
                completionHandler(NSError(domain: "VPN", code: 3, userInfo: [NSLocalizedDescriptionKey: msg]))
                return
            }

            self?.startXrayAndTunnel(config: config, completionHandler: completionHandler)
        }
    }

    private func extractConfig() -> VPNConfig? {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let providerConfig = proto.providerConfiguration else {
            return nil
        }

        return VPNConfig(
            server: providerConfig["server"] as? String ?? "",
            port: providerConfig["port"] as? UInt16 ?? 443,
            uuid: providerConfig["uuid"] as? String ?? "",
            publicKey: providerConfig["publicKey"] as? String ?? "",
            shortId: providerConfig["shortId"] as? String ?? "",
            sni: providerConfig["sni"] as? String ?? ""
        )
    }

    private func testConnectivity(to server: String, port: UInt16, completion: @escaping (Bool, String?) -> Void) {
        let endpoint = NWHostEndpoint(hostname: server, port: "\(port)")
        let connection = createTCPConnection(to: endpoint, enableTLS: false, tlsParameters: nil, delegate: nil)

        var completed = false

        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            if !completed {
                completed = true
                connection.cancel()
                completion(false, "Connection timeout after 10s")
            }
        }

        connection.addObserver(self, forKeyPath: "state", options: .new, context: nil)

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            let state = connection.state
            if !completed {
                if state == .connected {
                    completed = true
                    connection.cancel()
                    completion(true, nil)
                } else if state == .cancelled || state == .invalid {
                    completed = true
                    completion(false, "Connection failed: \(state)")
                }
            }
        }
    }

    private func startXrayAndTunnel(config: VPNConfig, completionHandler: @escaping (Error?) -> Void) {
        do {
            // Generate Xray config
            let xrayConfig = generateXrayConfig(config: config)
            let configData = try JSONSerialization.data(withJSONObject: xrayConfig, options: .prettyPrinted)

            let tempDir = FileManager.default.temporaryDirectory
            configPath = tempDir.appendingPathComponent("xray_config.json").path
            try configData.write(to: URL(fileURLWithPath: configPath!))

            // Start Xray
            xrayTask = Process()
            xrayTask?.executableURL = Bundle.main.url(forResource: "xray", withExtension: nil)
            xrayTask?.arguments = ["run", "-c", configPath!]

            let pipe = Pipe()
            xrayTask?.standardError = pipe
            xrayTask?.standardOutput = pipe

            try xrayTask?.run()
            NSLog("VPN: Xray started on SOCKS port \(socksPort)")

            // Wait for SOCKS to be ready
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.startTun2Socks(completionHandler: completionHandler)
            }

        } catch {
            NSLog("VPN: Failed to start Xray: \(error)")
            completionHandler(error)
        }
    }

    private func startTun2Socks(completionHandler: @escaping (Error?) -> Void) {
        // Configure tunnel network settings
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "240.0.0.1")

        let ipv4Settings = NEIPv4Settings(addresses: ["240.0.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4Settings.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4Settings

        let dnsSettings = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])
        settings.dnsSettings = dnsSettings

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error = error {
                NSLog("VPN: Failed to set network settings: \(error)")
                completionHandler(error)
                return
            }

            NSLog("VPN: Network settings applied")

            // Start tun2socks bridge
            self?.startTun2SocksBridge()

            completionHandler(nil)
        }
    }

    private func startTun2SocksBridge() {
        // In real implementation, use Tun2SocksKit or similar
        // This would bridge packetFlow to the SOCKS proxy
        NSLog("VPN: Tun2socks bridge started (stub)")

        // Start metrics updater
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateMetrics()
        }
    }

    private func updateMetrics() {
        // In real implementation, track actual bytes
        bytesSent += 1024
        bytesReceived += 2048

        let defaults = UserDefaults(suiteName: "group.com.vpn.client")
        defaults?.set(bytesSent, forKey: "bytes_sent")
        defaults?.set(bytesReceived, forKey: "bytes_received")
    }

    private func generateXrayConfig(config: VPNConfig) -> [String: Any] {
        return [
            "log": ["loglevel": "warning"],
            "inbounds": [[
                "listen": "127.0.0.1",
                "port": socksPort,
                "protocol": "socks",
                "settings": ["udp": true]
            ]],
            "outbounds": [[
                "protocol": "vless",
                "settings": [
                    "vnext": [[
                        "address": config.server,
                        "port": config.port,
                        "users": [[
                            "id": config.uuid,
                            "encryption": "none",
                            "flow": "xtls-rprx-vision"
                        ]]
                    ]]
                ],
                "streamSettings": [
                    "network": "tcp",
                    "security": "reality",
                    "realitySettings": [
                        "serverName": config.sni,
                        "fingerprint": "chrome",
                        "publicKey": config.publicKey,
                        "shortId": config.shortId
                    ]
                ]
            ]]
        ]
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        NSLog("VPN: Stopping tunnel, reason: \(reason)")

        tunnelTask?.terminate()
        xrayTask?.terminate()

        if let path = configPath {
            try? FileManager.default.removeItem(atPath: path)
        }

        completionHandler()
    }
}
