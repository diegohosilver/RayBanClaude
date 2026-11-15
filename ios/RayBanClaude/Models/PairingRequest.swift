import Foundation

/// Pairing data from the QR code in the PC dashboard:
/// `raybanclaude://pair?host=192.168.1.20&port=18790&token=…&remote=100.101.102.103`
///
/// `remote` (optional) is the PC's Tailscale address – through it the app reaches
/// the PC while you are away too, so it keeps using the Claude subscription instead of an API key.
///
/// Always confirmed before it is applied – otherwise a foreign QR code could silently
/// redirect the app to a foreign server (and send camera images there).
struct PairingRequest: Identifiable, Equatable {
    let host: String
    let port: Int
    let token: String
    /// Address for when you are away (Tailscale), if the PC has one
    let remote: String?

    var id: String { "\(host):\(port)" }

    static let urlHost = "pair"

    init?(url: URL) {
        guard url.scheme?.lowercased() == "raybanclaude",
              url.host?.lowercased() == Self.urlHost,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return nil
        }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        guard let host = value("host"), Self.isValidHost(host),
              let portText = value("port"), let port = Int(portText), (1024...65535).contains(port),
              let token = value("token"), Self.isValidToken(token) else {
            return nil
        }
        self.host = host
        self.port = port
        self.token = token
        let remote = value("remote")
        self.remote = remote.flatMap { Self.isValidHost($0) && $0 != host ? $0 : nil }
    }

    /// IPv4 address or simple hostname (e.g. "my-pc.local")
    static func isValidHost(_ host: String) -> Bool {
        guard (1...253).contains(host.count) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        return host.unicodeScalars.allSatisfy { allowed.contains($0) && $0.isASCII }
            && !host.hasPrefix(".") && !host.hasPrefix("-")
    }

    /// 16–128 characters: letters, digits, _ and -
    static func isValidToken(_ token: String) -> Bool {
        guard (16...128).contains(token.count) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        return token.unicodeScalars.allSatisfy { allowed.contains($0) && $0.isASCII }
    }
}
