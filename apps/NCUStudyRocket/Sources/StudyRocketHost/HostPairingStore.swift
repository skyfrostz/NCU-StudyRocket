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
    private let lock = NSLock()
    private var devices: [String: PairedDeviceRecord]
    private var activeCode: String?
    private var codeExpiresAt: Date?
    private var failedAttempts = 0
    private var usedNonces: [String: Date] = [:]
    private var authorizationChallenges: [String: (deviceID: String, expiresAt: Date)] = [:]
    private let keychainService = "com.skyfrost.ncustudyrocket.host"
    private let keychainAccount = "paired-devices"

    init() {
        devices = Self.load(service: keychainService, account: keychainAccount)
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
        guard request.code == expectedCode else {
            failedAttempts += 1
            throw HostPairingError(message: "配对码不正确。")
        }
        guard let keyData = Data(base64Encoded: request.publicKey), (try? P256.Signing.PublicKey(rawRepresentation: keyData)) != nil else {
            throw HostPairingError(message: "iPhone 公钥格式无效。")
        }
        let id = UUID().uuidString
        devices[id] = PairedDeviceRecord(id: id, name: request.deviceName, publicKey: request.publicKey, createdAt: now, isRevoked: false)
        activeCode = nil
        codeExpiresAt = nil
        failedAttempts = 0
        persist()
        return PairResponse(deviceID: id, serverName: HostIdentity.name)
    }

    func revoke(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        guard let device = devices[id] else { return }
        devices[id] = PairedDeviceRecord(id: device.id, name: device.name, publicKey: device.publicKey, createdAt: device.createdAt, isRevoked: true)
        persist()
    }

    func verify(_ authentication: RequestAuthentication, method: String, path: String, body: Data, now: Date = .now) -> Bool {
        verifyAndIdentify(authentication, method: method, path: path, body: body, now: now) != nil
    }

    func verifyAndIdentify(_ authentication: RequestAuthentication, method: String, path: String, body: Data, now: Date = .now) -> String? {
        lock.lock(); defer { lock.unlock() }
        let current = now.timeIntervalSince1970
        guard abs(current - Double(authentication.timestamp)) <= 60,
              usedNonces[authentication.nonce] == nil,
              let device = devices[authentication.deviceID], !device.isRevoked,
              let publicKeyData = Data(base64Encoded: device.publicKey) else { return nil }
        guard RequestSigning.verify(publicKeyData: publicKeyData, signatureBase64: authentication.signature, method: method, path: path, timestamp: authentication.timestamp, nonce: authentication.nonce, bodyHash: RequestSigning.bodyHash(body)) else { return nil }
        usedNonces[authentication.nonce] = now
        usedNonces = usedNonces.filter { now.timeIntervalSince($0.value) < 300 }
        return authentication.deviceID
    }

    func issueAuthorizationChallenge(for deviceID: String, now: Date = .now) throws -> ProposalAuthorizationChallenge {
        lock.lock(); defer { lock.unlock() }
        guard let device = devices[deviceID], !device.isRevoked else { throw HostPairingError(message: "设备未配对或已撤销。") }
        let challenge = UUID().uuidString
        let expiresAt = now.addingTimeInterval(90)
        authorizationChallenges[challenge] = (deviceID, expiresAt)
        authorizationChallenges = authorizationChallenges.filter { $0.value.expiresAt > now }
        return ProposalAuthorizationChallenge(challenge: challenge, expiresAt: expiresAt)
    }

    func consumeAuthorization(_ authorization: String, for deviceID: String, now: Date = .now) -> Bool {
        let parts = authorization.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return false }
        lock.lock(); defer { lock.unlock() }
        guard let record = authorizationChallenges.removeValue(forKey: parts[0]),
              record.deviceID == deviceID, record.expiresAt > now,
              let device = devices[deviceID], !device.isRevoked,
              let publicKeyData = Data(base64Encoded: device.publicKey) else { return false }
        return RequestSigning.verifyAuthorization(publicKeyData: publicKeyData, signatureBase64: parts[1], challenge: parts[0])
    }

    private func persist() {
        let data = try? JSONEncoder().encode(Array(devices.values))
        guard let data else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
        let item = query.merging([kSecValueData as String: data]) { _, new in new }
        SecItemAdd(item as CFDictionary, nil)
    }

    private static func load(service: String, account: String) -> [String: PairedDeviceRecord] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let decoded = try? JSONDecoder().decode([PairedDeviceRecord].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
    }
}

enum HostIdentity {
    static let name = "NCU StudyRocket Mac"
}
