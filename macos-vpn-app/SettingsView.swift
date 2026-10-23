import SwiftUI

class SettingsWindow {
    static var window: NSWindow?

    static func show() {
        if window == nil {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window?.title = "VPN Settings"
            window?.contentView = NSHostingView(rootView: SettingsView())
            window?.center()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SettingsView: View {
    @StateObject private var vpnManager = VPNManager()
    @State private var server = ""
    @State private var port = "443"
    @State private var uuid = ""
    @State private var publicKey = ""
    @State private var shortId = ""
    @State private var sni = ""
    @State private var vlessLink = ""
    @State private var showAlert = false
    @State private var alertMessage = ""

    var body: some View {
        VStack(spacing: 20) {
            Text("VPN Configuration")
                .font(.title)
                .padding(.top)

            VStack(alignment: .leading, spacing: 15) {
                Text("Import from vless:// link:")
                    .font(.headline)

                HStack {
                    TextField("Paste vless:// link here", text: $vlessLink)
                        .textFieldStyle(RoundedBorderTextFieldStyle())

                    Button("Import") {
                        importVlessLink()
                    }
                    .buttonStyle(.borderedProminent)
                }

                Divider()
                    .padding(.vertical, 5)

                Text("Or enter manually:")
                    .font(.headline)

                HStack {
                    Text("Server:")
                        .frame(width: 100, alignment: .trailing)
                    TextField("example.com", text: $server)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }

                HStack {
                    Text("Port:")
                        .frame(width: 100, alignment: .trailing)
                    TextField("443", text: $port)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(width: 100)
                }

                HStack {
                    Text("UUID:")
                        .frame(width: 100, alignment: .trailing)
                    TextField("", text: $uuid)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }

                HStack {
                    Text("Public Key:")
                        .frame(width: 100, alignment: .trailing)
                    TextField("", text: $publicKey)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }

                HStack {
                    Text("Short ID:")
                        .frame(width: 100, alignment: .trailing)
                    TextField("", text: $shortId)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }

                HStack {
                    Text("SNI:")
                        .frame(width: 100, alignment: .trailing)
                    TextField("", text: $sni)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }
            }
            .padding(.horizontal)

            Spacer()

            HStack {
                Button("Cancel") {
                    SettingsWindow.window?.close()
                }

                Spacer()

                Button("Save") {
                    saveConfig()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 500, height: 400)
        .alert("Configuration", isPresented: $showAlert) {
            Button("OK") { }
        } message: {
            Text(alertMessage)
        }
        .onAppear(perform: loadConfig)
    }

    private func loadConfig() {
        if let config = try? JSONDecoder().decode(VPNConfig.self, from: Data(contentsOf: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vpn/config.json"))) {
            server = config.server
            port = String(config.port)
            uuid = config.uuid
            publicKey = config.publicKey
            shortId = config.shortId
            sni = config.sni
        }
    }

    private func saveConfig() {
        let config = VPNConfig(
            server: server,
            port: Int(port) ?? 443,
            uuid: uuid,
            publicKey: publicKey,
            shortId: shortId,
            sni: sni
        )
        vpnManager.saveConfig(config)
        alertMessage = "Configuration saved successfully"
        showAlert = true
    }

    private func importVlessLink() {
        guard vlessLink.hasPrefix("vless://") else {
            alertMessage = "Invalid vless:// link"
            showAlert = true
            return
        }

        let link = String(vlessLink.dropFirst(8))
        let parts = link.components(separatedBy: "@")
        guard parts.count == 2 else { return }

        uuid = parts[0]

        let rest = parts[1].components(separatedBy: "?")
        let hostPort = rest[0].components(separatedBy: ":")
        server = hostPort[0]
        if hostPort.count > 1 {
            port = hostPort[1].components(separatedBy: "#")[0]
        }

        if rest.count > 1 {
            let query = rest[1].components(separatedBy: "#")[0]
            let params = query.components(separatedBy: "&")
            for param in params {
                let kv = param.components(separatedBy: "=")
                if kv.count == 2 {
                    switch kv[0] {
                    case "pbk": publicKey = kv[1].removingPercentEncoding ?? kv[1]
                    case "sid": shortId = kv[1].removingPercentEncoding ?? kv[1]
                    case "sni": sni = kv[1].removingPercentEncoding ?? kv[1]
                    default: break
                    }
                }
            }
        }

        alertMessage = "Configuration imported successfully"
        showAlert = true
    }
}
