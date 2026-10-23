import Foundation

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
