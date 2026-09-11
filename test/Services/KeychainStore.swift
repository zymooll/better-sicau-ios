import Foundation
import Security

struct KeychainStore: Sendable {
    static let defaultService = "cn.better.sicau"

    let service: String

    init(service: String = KeychainStore.defaultService) {
        self.service = service
    }

    func read(_ account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            Log.error(.storage, LogMessage("读取本地安全存储失败（\(status)）"))
            throw AppError.storageFailure("读取本地安全存储失败（\(status)）")
        }
        guard let data = result as? Data else {
            Log.error(.storage, LogMessage("本地安全存储数据格式无效"))
            throw AppError.storageFailure("本地安全存储数据格式无效")
        }
        return data
    }

    func write(_ data: Data, account: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            Log.error(.storage, LogMessage("写入本地安全存储失败（\(updateStatus)）"))
            throw AppError.storageFailure("写入本地安全存储失败（\(updateStatus)）")
        }
        var item = base
        item.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
            Log.error(.storage, LogMessage("写入本地安全存储失败（\(addStatus)）"))
            throw AppError.storageFailure("写入本地安全存储失败（\(addStatus)）")
        }
        if addStatus == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
            guard retryStatus == errSecSuccess else {
                Log.error(.storage, LogMessage("更新本地安全存储失败（\(retryStatus)）"))
                throw AppError.storageFailure("更新本地安全存储失败（\(retryStatus)）")
            }
        }
    }

    func delete(_ account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            Log.error(.storage, LogMessage("删除本地安全存储失败（\(status)）"))
            throw AppError.storageFailure("删除本地安全存储失败（\(status)）")
        }
    }
}
