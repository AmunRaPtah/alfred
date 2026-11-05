import Foundation
import Security

/// mTLS client certificate for the public (non-WireGuard) alfredd route.
/// The .p12 and its password live in the Keychain; the decoded identity is
/// cached in memory. Logic is identical to Helm's; only the Keychain account
/// names changed so the two apps don't collide on the same phone.
enum ClientIdentity {
    private static let p12Account = "alfred.clientcert.p12"
    private static let passAccount = "alfred.clientcert.pass"
    private static let lock = NSLock()
    private static var cached: (identity: SecIdentity, chain: [SecCertificate], name: String)?
    private static var loaded = false

    enum ImportError: LocalizedError {
        case badPassword, invalidFile(OSStatus), keychain
        var errorDescription: String? {
            switch self {
            case .badPassword: return "Wrong password for this certificate."
            case .invalidFile(let status): return "Not a usable .p12 client certificate (OSStatus \(status))."
            case .keychain: return "Could not save to the Keychain."
            }
        }
    }

    /// Validates the p12 and stores it. Returns the certificate's common name.
    @discardableResult
    static func importP12(_ data: Data, password: String) throws -> String {
        let decoded = try decode(data, password: password)
        guard Keychain.writeData(data, account: p12Account),
              Keychain.write(password, account: passAccount) else { throw ImportError.keychain }
        lock.lock(); cached = decoded; loaded = true; lock.unlock()
        return decoded.name
    }

    static func remove() {
        Keychain.delete(p12Account)
        Keychain.delete(passAccount)
        lock.lock(); cached = nil; loaded = true; lock.unlock()
    }

    /// Common name of the installed certificate, or nil if none.
    static var installedName: String? { current()?.name }

    static func credential() -> URLCredential? {
        guard let c = current() else { return nil }
        return URLCredential(identity: c.identity, certificates: c.chain, persistence: .forSession)
    }

    private static func current() -> (identity: SecIdentity, chain: [SecCertificate], name: String)? {
        lock.lock(); defer { lock.unlock() }
        if !loaded {
            loaded = true
            if let data = Keychain.readData(p12Account), let pass = Keychain.read(passAccount) {
                cached = try? decode(data, password: pass)
            }
            if cached == nil, let e = EmbeddedConfig.shared, let data = e.p12Data {
                cached = try? decode(data, password: e.p12_pass ?? "")
            }
        }
        return cached
    }

    private static func decode(_ data: Data, password: String) throws -> (identity: SecIdentity, chain: [SecCertificate], name: String) {
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: password] as CFDictionary, &items)
        if status == errSecAuthFailed { throw ImportError.badPassword }
        guard status == errSecSuccess else { throw ImportError.invalidFile(status) }
        guard let first = (items as? [[String: Any]])?.first,
              let idRef = first[kSecImportItemIdentity as String] else { throw ImportError.invalidFile(errSecItemNotFound) }
        let identity = idRef as! SecIdentity
        var leaf: SecCertificate?
        SecIdentityCopyCertificate(identity, &leaf)
        let chain = (first[kSecImportItemCertChain as String] as? [SecCertificate]) ?? []
        let name = leaf.flatMap { SecCertificateCopySubjectSummary($0) as String? } ?? "client certificate"
        // The credential's certificates list is the intermediates, not the leaf.
        let extra = chain.filter { c in leaf.map { CFEqual(c, $0) } != true }
        return (identity, extra, name)
    }
}

/// Answers TLS client-certificate challenges with the imported identity.
final class ClientCertDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = ClientCertDelegate()

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler)
    }

    private func handle(_ challenge: URLAuthenticationChallenge,
                        _ completion: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate else {
            completion(.performDefaultHandling, nil)
            return
        }
        if let cred = ClientIdentity.credential() {
            completion(.useCredential, cred)
        } else {
            completion(.performDefaultHandling, nil)
        }
    }
}
