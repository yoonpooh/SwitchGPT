import Foundation
import Security

@MainActor
protocol CredentialVault {
    func save(_ data: Data, id: String) throws
    func read(_ id: String) throws -> Data
    func remove(_ id: String) throws
}

struct Vault: CredentialVault {
    private let service = "local.codex-account-switch.credentials"
    private func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id]
    }
    func save(_ data: Data, id: String) throws {
        let status = SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(id)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            try check(SecItemAdd(item as CFDictionary, nil))
        } else { try check(status) }
    }
    func read(_ id: String) throws -> Data {
        var item = query(id)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        try check(SecItemCopyMatching(item as CFDictionary, &result))
        guard let data = result as? Data else { throw SwitchError(message: L10n.text("vault_read")) }
        return data
    }
    func remove(_ id: String) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw SwitchError(message: L10n.format("keychain_error", status)) }
    }
}
