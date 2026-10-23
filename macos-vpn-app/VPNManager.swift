import Foundation
import SystemConfiguration

class VPNManager: ObservableObject {
    @Published var isConnected = false
    @Published var statusMessage = "Disconnected"

    private var xrayProcess: Process?
    private let configPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vpn/config.json")
    private let xrayPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vpn/xray")

    var onStatusChange: ((Bool) -> Void)?

    func connect() {
        guard let config = loadConfig() else {
            statusMessage = "No configuration found. Please add server settings."
            return
        }

        ensureXrayInstalled()

        let xrayConfig = generateXrayConfig(config: config)
        let xrayConfigPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vpn/xray-config.json")
        try? xrayConfig.write(to: xrayConfigPath, atomically: true, encoding: .utf8)

        xrayProcess = Process()
        xrayProcess?.executableURL = xrayPath
        xrayProcess?.arguments = ["run", "-c", xrayConfigPath.path]

        try? xrayProcess?.run()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.enableSystemProxy()
            self.isConnected = true
            self.statusMessage = "Connected to \(config.server)"
            self.onStatusChange?(true)
        }
    }

    func disconnect() {
        xrayProcess?.terminate()
        xrayProcess = nil

        disableSystemProxy()
        isConnected = false
        statusMessage = "Disconnected"
        onStatusChange?(false)
    }

    private func loadConfig() -> VPNConfig? {
        guard let data = try? Data(contentsOf: configPath) else { return nil }
        return try? JSONDecoder().decode(VPNConfig.self, from: data)
    }

    func saveConfig(_ config: VPNConfig) {
        let dir = configPath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try? JSONEncoder().encode(config)
        try? data?.write(to: configPath)
    }

    private func ensureXrayInstalled() {
        guard !FileManager.default.fileExists(atPath: xrayPath.path) else { return }

        let script = """
        arch=$(uname -m)
        if [[ "$arch" == "arm64" ]]; then
            url="https://github.com/XTLS/Xray-core/releases/download/v1.8.7/Xray-darwin-arm64-v8a.zip"
        else
            url="https://github.com/XTLS/Xray-core/releases/download/v1.8.7/Xray-darwin-64.zip"
        fi
        curl -L "$url" -o /tmp/xray.zip
        unzip -o /tmp/xray.zip -d ~/.vpn/
        chmod +x ~/.vpn/xray
        rm /tmp/xray.zip
        """

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", script]
        try? task.run()
        task.waitUntilExit()
    }

    private func enableSystemProxy() {
        let script = """
        networksetup -setsocksfirewallproxy "Wi-Fi" 127.0.0.1 10808
        networksetup -setsocksfirewallproxystate "Wi-Fi" on
        """
        runScript(script)
    }

    private func disableSystemProxy() {
        let script = """
        networksetup -setsocksfirewallproxystate "Wi-Fi" off
        """
        runScript(script)
    }

    private func runScript(_ script: String) {
        let appleScript = """
        do shell script "\(script)" with administrator privileges
        """
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: appleScript) {
            scriptObject.executeAndReturnError(&error)
        }
    }

    private func generateXrayConfig(config: VPNConfig) -> String {
        return """
        {
          "log": {"loglevel": "warning"},
          "inbounds": [{
            "listen": "127.0.0.1",
            "port": 10808,
            "protocol": "socks",
            "settings": {"udp": true}
          }],
          "outbounds": [{
            "protocol": "vless",
            "settings": {
              "vnext": [{
                "address": "\(config.server)",
                "port": \(config.port),
                "users": [{
                  "id": "\(config.uuid)",
                  "encryption": "none",
                  "flow": "xtls-rprx-vision"
                }]
              }]
            },
            "streamSettings": {
              "network": "tcp",
              "security": "reality",
              "realitySettings": {
                "serverName": "\(config.sni)",
                "fingerprint": "chrome",
                "publicKey": "\(config.publicKey)",
                "shortId": "\(config.shortId)"
              }
            }
          }]
        }
        """
    }
}

struct VPNConfig: Codable {
    var server: String
    var port: Int
    var uuid: String
    var publicKey: String
    var shortId: String
    var sni: String
}
