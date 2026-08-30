import Foundation
import Security

/// Keychain storage for the Vercel API token: generic password, service
/// `com.overture.vercel-token`, AfterFirstUnlock, no iCloud sync. Never in
/// SwiftData, never in UserDefaults, never logged (spec 02 §7).
public struct VercelTokenStore: Sendable {
    public enum StoreError: Error, Sendable {
        case unexpectedStatus(OSStatus)
    }

    private let service: String

    public init(service: String = "com.overture.vercel-token") {
        self.service = service
    }

    public func read() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ token: String) throws {
        let data = Data(token.utf8)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let update = SecItemUpdate(query as CFDictionary,
                                   attributes as CFDictionary)
        if update == errSecItemNotFound {
            var add = query
            add.merge(attributes) { _, new in new }
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw StoreError.unexpectedStatus(status)
            }
        } else if update != errSecSuccess {
            throw StoreError.unexpectedStatus(update)
        }
    }

    public func delete() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.unexpectedStatus(status)
        }
    }
}
