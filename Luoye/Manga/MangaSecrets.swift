import Foundation
import CryptoKit
import Security

/// Only the encryption key is kept in Keychain; source data can remain large on disk.
enum MangaSecrets {
    private static let service = "app.luoye.manga.secrets.v1"
    private static let prefix = Data("MGS1".utf8)
    static func read(_ name: String) throws -> Data? {
        let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:name,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw failure(status) }
        return data
    }
    static func write(_ data: Data, name: String) throws {
        let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:name]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String:data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw failure(status) }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let result = SecItemAdd(insert as CFDictionary, nil)
        guard result == errSecSuccess else { throw failure(result) }
    }
    static func remove(_ name: String) throws {
        let result = SecItemDelete([kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:name] as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw failure(result) }
    }
    private static func encryptionKey(_ namespace: String, create: Bool) throws -> SymmetricKey {
        let name = "file-key:" + namespace
        if let data = try read(name) { return SymmetricKey(data: data) }
        guard create else { throw MangaScriptRuntime.RuntimeError.message("此设备没有漫画源登录数据的解密密钥，请重新登录") }
        let key = SymmetricKey(size: .bits256)
        try write(key.withUnsafeBytes { Data($0) }, name: name)
        return key
    }
    static func loadFile(_ url: URL, namespace: String) throws -> Data {
        let data = try Data(contentsOf: url)
        guard data.starts(with: prefix) else { return data }
        let key = try encryptionKey(namespace, create: false)
        return try AES.GCM.open(AES.GCM.SealedBox(combined: data.dropFirst(prefix.count)), using: key, authenticating: Data(namespace.utf8))
    }
    static func saveFile(_ data: Data, to url: URL, namespace: String) throws {
        let key = try encryptionKey(namespace, create: true)
        guard let combined = try AES.GCM.seal(data, using: key, authenticating: Data(namespace.utf8)).combined else { throw MangaScriptRuntime.RuntimeError.message("漫画源数据加密失败") }
        try (prefix + combined).write(to: url, options: .atomic)
    }
    private static func failure(_ status: OSStatus) -> Error {
        MangaScriptRuntime.RuntimeError.message("安全存储暂不可用（\(status)）")
    }
}
