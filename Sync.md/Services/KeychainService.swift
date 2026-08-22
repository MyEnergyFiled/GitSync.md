import Foundation
import Security

struct KeychainServiceError: LocalizedError, Equatable {
    enum Operation: String, Equatable {
        case save
        case load
        case delete
        case encode
    }

    let operation: Operation
    let status: OSStatus

    var errorDescription: String? {
        String(localized: "Secure credential access failed.")
    }

    var diagnosticDescription: String {
        "operation=\(operation.rawValue) status=\(status)"
    }
}

enum KeychainService {
    private static let service = "com.myenergyfiled.GitSyncMD"

    static func save(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainServiceError(operation: .encode, status: errSecParam)
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let updateAttributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainServiceError(operation: .save, status: updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainServiceError(operation: .save, status: addStatus)
        }
    }

    static func load(key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainServiceError(operation: .load, status: status)
        }
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainServiceError(operation: .encode, status: errSecDecode)
        }
        return value
    }

    static func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainServiceError(operation: .delete, status: status)
        }
    }
}
