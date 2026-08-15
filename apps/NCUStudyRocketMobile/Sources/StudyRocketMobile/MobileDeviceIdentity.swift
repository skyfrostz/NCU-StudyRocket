import Foundation
import CryptoKit
import Security

public enum MobileIdentityError: LocalizedError {
    case unavailable
    case invalidKey

    public var errorDescription: String? {
        switch self {
        case .unavailable: "无法在此设备创建安全密钥。"
        case .invalidKey: "设备安全密钥已损坏，请重新配对。"
        }
    }
}

public final class MobileDeviceIdentity {
    private let service = "com.skyfrost.ncustudyrocket.mobile"
    private let account = "device-signing-key"

    public init() {}

    #if os(iOS)
    public func secureEnclaveKey() throws -> SecureEnclave.P256.Signing.PrivateKey {
        if let stored = load(), let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: stored) {
            return key
        }
        let key = try SecureEnclave.P256.Signing.PrivateKey()
        save(key.dataRepresentation)
        return key
    }

    public func publicKeyBase64() throws -> String {
        try secureEnclaveKey().publicKey.rawRepresentation.base64EncodedString()
    }
    #else
    public func softwareKey() throws -> P256.Signing.PrivateKey {
        if let stored = load(), let key = try? P256.Signing.PrivateKey(rawRepresentation: stored) {
            return key
        }
        let key = P256.Signing.PrivateKey()
        save(key.rawRepresentation)
        return key
    }

    public func publicKeyBase64() throws -> String {
        try softwareKey().publicKey.rawRepresentation.base64EncodedString()
    }
    #endif

    private func load() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private func save(_ data: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        let item = query.merging([
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]) { _, new in new }
        SecItemAdd(item as CFDictionary, nil)
    }
}
