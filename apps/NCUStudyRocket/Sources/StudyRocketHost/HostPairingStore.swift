import Foundation
import CryptoKit
import Security
import StudyRocketShared

struct HostPairingError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct PairedDeviceRecord: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let publicKey: String
    let createdAt: Date
    var isRevoked: Bool
}

final class HostPairingStore: @unchecked Sendable {
    private static let maximumNonceCount = 2_048
    private static let maximumChallengeCount = 128
    private let lock = NSLock()
    private var devices: [String: PairedDeviceRecord]
    private var persistenceAvailable: Bool
    private var activeCode: String?
    private var codeExpiresAt: Date?
    private var failedAttempts = 0
    private var usedNonces: [String: Date] = [:]
    private var authorizationChallenges: [String: (deviceID: String, expiresAt: Date)] = [:]
    private let keychainService: String
    private let keychainAccount: String
    private let deviceLoader: (String, String) -> (devices: [String: PairedDeviceRecord], available: Bool)

    init(
        service: String = "com.skyfrost.ncustudyrocket.host",
        account: String = "paired-devices",
        deviceLoader: @escaping (String, String) -> (devices: [String: PairedDeviceRecord], available: Bool) = HostPairingStore.load
    ) {
        keychainService = service
        keychainAccount = account
        self.deviceLoader = deviceLoader
        let loaded = deviceLoader(service, account)
        devices = loaded.devices
        persistenceAvailable = loaded.available
    }

    var deviceCount: Int {
        lock.lock(); defer { lock.unlock() }
        return devices.values.filter { !$0.isRevoked }.count
    }

    func list() -> [PairedDeviceRecord] {
        lock.lock(); defer { lock.unlock() }
        return devices.values.sorted { $0.createdAt < $1.createdAt }
    }

    func generateCode(now: Date = .now) -> String {
        lock.lock(); defer { lock.unlock() }
        let code = String(format: "%06d", Int.random(in: 100000...999999))
        activeCode = code
        codeExpiresAt = now.addingTimeInterval(300)
        failedAttempts = 0
        return code
    }

    func pair(_ request: PairRequest, now: Date = .now) throws -> PairResponse {
        lock.lock(); defer { lock.unlock() }
        guard request.apiVersion == StudyRocketAPI.version else {
            throw HostPairingError(message: "客户端版本不兼容，请更新 StudyRocket。")
        }
        guard let expectedCode = activeCode, let expiresAt = codeExpiresAt, now < expiresAt, failedAttempts < 5 else {
            throw HostPairingError(message: "配对码已失效，请在 Mac Host 中生成新配对码。")
        }
        guard Self.isSixDigitCode(request.code), request.code == expectedCode else {
            failedAttempts += 1
            throw HostPairingError(message: "配对码不正确。")
        }
        let deviceName = request.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...64).contains(deviceName.count),
              !deviceName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw HostPairingError(message: "设备名称无效。")
        }
        guard !request.publicKey.isEmpty, request.publicKey.utf8.count <= 256,
              let keyData = Data(base64Encoded: request.publicKey),
              (try? P256.Signing.PublicKey(rawRepresentation: keyData)) != nil else {
            throw HostPairingError(message: "iPhone 公钥格式无效。")
        }
        let id = UUID().uuidString
        devices[id] = PairedDeviceRecord(id: id, name: deviceName, publicKey: request.publicKey, createdAt: now, isRevoked: false)
        do {
            try persist()
        } catch {
            devices.removeValue(forKey: id)
            throw error
        }
        activeCode = nil
        codeExpiresAt = nil
        failedAttempts = 0
        return PairResponse(deviceID: id, serverName: HostIdentity.name)
    }

    func revoke(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard let device = devices[id] else { return }
        devices[id] = PairedDeviceRecord(id: device.id, name: device.name, publicKey: device.publicKey, createdAt: device.createdAt, isRevoked: true)
        do {
            try persist()
        } catch {
            devices[id] = device
            throw error
        }
    }

    func verify(_ authentication: RequestAuthentication, method: String, path: String, body: Data, now: Date = .now) -> Bool {
        verifyAndIdentify(authentication, method: method, path: path, body: body, now: now) != nil
    }

    func verifyAndIdentify(_ authentication: RequestAuthentication, method: String, path: String, body: Data, now: Date = .now) -> String? {
        lock.lock(); defer { lock.unlock() }
        let current = now.timeIntervalSince1970
        usedNonces = usedNonces.filter { now.timeIntervalSince($0.value) < 300 }
        guard abs(current - Double(authentication.timestamp)) <= 60,
              UUID(uuidString: authentication.deviceID) != nil,
              UUID(uuidString: authentication.nonce) != nil,
              !authentication.signature.isEmpty,
              authentication.signature.utf8.count <= 256,
              usedNonces[authentication.nonce] == nil,
              let device = devices[authentication.deviceID], !device.isRevoked,
              let publicKeyData = Data(base64Encoded: device.publicKey) else { return nil }
        guard RequestSigning.verify(publicKeyData: publicKeyData, signatureBase64: authentication.signature, method: method, path: path, timestamp: authentication.timestamp, nonce: authentication.nonce, bodyHash: RequestSigning.bodyHash(body)) else { return nil }
        usedNonces[authentication.nonce] = now
        while usedNonces.count > Self.maximumNonceCount,
              let oldest = usedNonces.min(by: { $0.value < $1.value })?.key {
            usedNonces.removeValue(forKey: oldest)
        }
        return authentication.deviceID
    }

    func issueAuthorizationChallenge(for deviceID: String, now: Date = .now) throws -> ProposalAuthorizationChallenge {
        lock.lock(); defer { lock.unlock() }
        guard let device = devices[deviceID], !device.isRevoked else { throw HostPairingError(message: "设备未配对或已撤销。") }
        let challenge = UUID().uuidString
        let expiresAt = now.addingTimeInterval(90)
        authorizationChallenges = authorizationChallenges.filter { $0.value.expiresAt > now }
        authorizationChallenges = authorizationChallenges.filter { $0.value.deviceID != deviceID }
        while authorizationChallenges.count >= Self.maximumChallengeCount,
              let oldest = authorizationChallenges.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
            authorizationChallenges.removeValue(forKey: oldest)
        }
        authorizationChallenges[challenge] = (deviceID, expiresAt)
        return ProposalAuthorizationChallenge(challenge: challenge, expiresAt: expiresAt)
    }

    func consumeAuthorization(_ authorization: String, for deviceID: String, now: Date = .now) -> Bool {
        guard authorization.utf8.count <= 512, UUID(uuidString: deviceID) != nil else { return false }
        let parts = authorization.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              UUID(uuidString: parts[0]) != nil,
              !parts[1].isEmpty,
              parts[1].utf8.count <= 256 else { return false }
        lock.lock(); defer { lock.unlock() }
        authorizationChallenges = authorizationChallenges.filter { $0.value.expiresAt > now }
        guard let record = authorizationChallenges.removeValue(forKey: parts[0]),
              record.deviceID == deviceID, record.expiresAt > now,
              let device = devices[deviceID], !device.isRevoked,
              let publicKeyData = Data(base64Encoded: device.publicKey) else { return false }
        return RequestSigning.verifyAuthorization(publicKeyData: publicKeyData, signatureBase64: parts[1], challenge: parts[0])
    }

    private func persist() throws {
        try restoreKeychainAccessIfNeeded()
        let data = try JSONEncoder().encode(Array(devices.values))
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            let item = query.merging([
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]) { _, new in new }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            persistenceAvailable = false
            throw HostPairingError(message: "无法安全保存配对状态（\(status)）。")
        }
    }

    /// The Host can be started while macOS is locked. A Keychain read then fails with a
    /// transient interaction error, which must not permanently disable later pairing.
    /// This method runs while the caller holds `lock`.
    private func restoreKeychainAccessIfNeeded() throws {
        guard !persistenceAvailable else { return }
        let loaded = deviceLoader(keychainService, keychainAccount)
        guard loaded.available else {
            throw HostPairingError(message: "无法访问系统密钥串，配对状态未更改。")
        }

        // `devices` may contain the device being paired or revoked in this operation.
        // Keep that in-memory change authoritative while retaining other records that
        // were successfully read after the Mac was unlocked.
        devices.merge(loaded.devices) { inMemory, _ in inMemory }
        persistenceAvailable = true
    }

    private static func load(service: String, account: String) -> (devices: [String: PairedDeviceRecord], available: Bool) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return ([:], true) }
        guard status == errSecSuccess,
              let data = result as? Data,
              let decoded = try? JSONDecoder().decode([PairedDeviceRecord].self, from: data) else { return ([:], false) }
        let devices = Dictionary(decoded.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
        return (devices, true)
    }

    private static func isSixDigitCode(_ value: String) -> Bool {
        value.utf8.count == 6 && value.utf8.allSatisfy { (48...57).contains($0) }
    }
}

enum HostIdentity {
    static let name = "NCU StudyRocket Mac"
}
