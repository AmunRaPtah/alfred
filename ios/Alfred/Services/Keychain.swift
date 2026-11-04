import Foundation
import Security

enum Keychain {
    private static let service = "org.zyco.alfred"

    static func read(_ account: String) -> String? {
        readData(account).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func readData(_ account: String) -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return data
    }

    @discardableResult
    static func write(_ value: String, account: String) -> Bool {
        writeData(Data(value.utf8), account: account)
    }

    @discardableResult
    static func writeData(_ value: Data, account: String) -> Bool {
        delete(account)
        guard !value.isEmpty else { return true }
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: value,
        ]
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}
