import Foundation

/// Optional private-build provisioning. CI drops `embedded.json` into the
/// .app (from repo secrets, never committed) so a personal build connects with
/// no setup: server URL, bearer token and the mTLS .p12. Public builds have no
/// such file and behave exactly as before.
struct EmbeddedConfig: Decodable {
    let url: String?
    let token: String?
    let p12_b64: String?
    let p12_pass: String?

    static let shared: EmbeddedConfig? = {
        guard let u = Bundle.main.url(forResource: "embedded", withExtension: "json"),
              let d = try? Data(contentsOf: u) else { return nil }
        return try? JSONDecoder().decode(EmbeddedConfig.self, from: d)
    }()

    var p12Data: Data? { p12_b64.flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) } }
}
