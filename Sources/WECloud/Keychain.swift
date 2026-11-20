import Foundation
import Security

/// Small secrets in the login keychain: generic password items of one service.
public final class KeychainStore: @unchecked Sendable {
    public static let defaultService = "sk.whiteeagles.screenshot.google"

    private let service: String
    // The keychain is thread safe itself, but the "update, else add" pair is
    // not atomic; the lock keeps two writers from racing between the calls.
    private let lock = NSLock()

    public init(service: String = KeychainStore.defaultService) {
        self.service = service
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// The stored value, nil when there is none.
    public func string(for account: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainStore.error(status) }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stores the value; nil or an empty string removes the item.
    public func set(_ value: String?, for account: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard let value = value, !value.isEmpty else {
            let status = SecItemDelete(baseQuery(account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainStore.error(status)
            }
            return
        }
        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainStore.error(status) }

        var add = baseQuery(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecAttrLabel as String] = "WE Screenshot (\(account))"
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainStore.error(addStatus) }
    }

    private static func error(_ status: OSStatus) -> CloudError {
        .badResponse("Keychain error \(status)")
    }
}
