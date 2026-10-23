import SwiftUI

struct SettingsView: View {
    @StateObject private var manager = VPNManager.shared
    @State private var vlessLink = ""
    @State private var server = ""
    @State private var port = ""
    @State private var uuid = ""
    @State private var publicKey = ""
    @State private var shortId = ""
    @State private var sni = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Server Settings")
                .font(.system(size: 18, weight: .semibold))

            Group {
                Text("Paste vless:// link:")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                HStack {
                    TextField("vless://...", text: $vlessLink)
                        .textFieldStyle(.roundedBorder)

                    Button("Import") {
                        importLink()
                    }
                }
            }

            Divider()

            Text("Or enter manually:")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            Group {
                LabeledField(label: "Server IP", text: $server, placeholder: "52.34.245.131")
                LabeledField(label: "Port", text: $port, placeholder: "443")
                LabeledField(label: "UUID", text: $uuid, placeholder: "...")
                LabeledField(label: "Public Key", text: $publicKey, placeholder: "...")
                LabeledField(label: "Short ID", text: $shortId, placeholder: "...")
                LabeledField(label: "SNI", text: $sni, placeholder: "aws.amazon.com")
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }

                Spacer()

                Button("Save") {
                    saveSettings()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top)
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            loadCurrentSettings()
        }
    }

    private func loadCurrentSettings() {
        server = manager.config.server
        port = String(manager.config.port)
        uuid = manager.config.uuid
        publicKey = manager.config.publicKey
        shortId = manager.config.shortId
        sni = manager.config.sni
    }

    private func importLink() {
        guard vlessLink.hasPrefix("vless://") else { return }

        let trimmed = String(vlessLink.dropFirst(8))
        guard let atIndex = trimmed.firstIndex(of: "@") else { return }

        uuid = String(trimmed[..<atIndex])

        let rest = String(trimmed[trimmed.index(after: atIndex)...])
        guard let qIndex = rest.firstIndex(of: "?") else { return }

        let hostPort = String(rest[..<qIndex])
        let components = hostPort.split(separator: ":")
        if components.count == 2 {
            server = String(components[0])
            port = String(components[1])
        }

        let query = String(rest[rest.index(after: qIndex)...])
        let params = query.split(separator: "&").reduce(into: [String: String]()) { dict, pair in
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                dict[String(kv[0])] = String(kv[1])
            }
        }

        publicKey = params["pbk"] ?? ""
        shortId = params["sid"] ?? ""
        sni = params["sni"] ?? ""
    }

    private func saveSettings() {
        manager.config = VPNConfig(
            server: server,
            port: UInt16(port) ?? 443,
            uuid: uuid,
            publicKey: publicKey,
            shortId: shortId,
            sni: sni
        )
        manager.saveConfiguration()
    }
}

struct LabeledField: View {
    let label: String
    @Binding var text: String
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
        }
    }
}
