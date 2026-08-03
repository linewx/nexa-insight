import Foundation
import Security

enum SecretKey: String {
    case openAIKey, dashscopeKey, dashscopeWorkspaceId
    // YouTube Data API v3, for channel catalogues and richer discovery results.
    case youtubeAPIKey
}

struct KeychainStore {
    let service = "com.nexainsight.secrets"

    func set(_ value: String, for key: SecretKey) {
        let data = Data(value.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrService as String: service,
                                     kSecAttrAccount as String: key.rawValue]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    func get(_ key: SecretKey) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrService as String: service,
                                     kSecAttrAccount as String: key.rawValue,
                                     kSecReturnData as String: true,
                                     kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(_ key: SecretKey) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrService as String: service,
                                     kSecAttrAccount as String: key.rawValue]
        SecItemDelete(query as CFDictionary)
    }
}
