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
    private static let lock = NSLock()
    private let service = MobileRuntimeConfiguration.keychainService
    // Keep the simulator fixture isolated from the physical-device key. This
    // also prevents a pre-fallback Secure Enclave reference in an existing
    // Simulator keychain from being decoded as a software key.
    private let account: String = {
        #if targetEnvironment(simulator)
        "simulator-device-signing-key"
        #else
        "device-signing-key"
        #endif
    }()

    public init() {}

    // Secure Enclave does not exist in an iOS Simulator. Simulator-only
    // debugging still needs a stable signing identity to exercise pairing and
    // request verification; physical iPhones never enter this branch.
    #if os(iOS) && !targetEnvironment(simulator)
    public func secureEnclaveKey() throws -> SecureEnclave.P256.Signing.PrivateKey {
        Self.lock.lock(); defer { Self.lock.unlock() }
        if let stored = try load() {
            guard let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: stored) else {
                throw MobileIdentityError.invalidKey
            }
            return key
        }
        let key = try SecureEnclave.P256.Signing.PrivateKey()
        try add(key.dataRepresentation)
        return key
    }

    public func publicKeyBase64() throws -> String {
        try secureEnclaveKey().publicKey.rawRepresentation.base64EncodedString()
    }
    #else
    public func softwareKey() throws -> P256.Signing.PrivateKey {
        Self.lock.lock(); defer { Self.lock.unlock() }
        if let stored = try load() {
            guard let key = try? P256.Signing.PrivateKey(rawRepresentation: stored) else {
                throw MobileIdentityError.invalidKey
            }
            return key
        }
        let key = P256.Signing.PrivateKey()
        try add(key.rawRepresentation)
        return key
    }

    public func publicKeyBase64() throws -> String {
        try softwareKey().publicKey.rawRepresentation.base64EncodedString()
    }
    #endif

    private func load() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw MobileIdentityError.unavailable }
        return data
    }

    private func add(_ data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let item = query.merging([
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]) { _, new in new }
        let status = SecItemAdd(item as CFDictionary, nil)
        #if targetEnvironment(simulator)
        if status != errSecSuccess {
            NSLog("StudyRocket Simulator keychain write failed: %d", status)
        }
        #endif
        guard status == errSecSuccess else {
            throw MobileIdentityError.unavailable
        }
    }
}

private enum MobileRuntimeConfiguration {
    static let keychainService: String = {
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: "StudyRocketKeychainService") as? String else {
            return "com.skyfrost.ncustudyrocket.mobile"
        }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("$(") else {
            return "com.skyfrost.ncustudyrocket.mobile"
        }
        return value
    }()
}
