import CryptoKit
import Foundation
import Security
import StudyRocketShared

@main
enum HostPairingStoreChecks {
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() throws {
        let service = "com.skyfrost.ncustudyrocket.host.checks.\(UUID().uuidString)"
        let account = "paired-devices"
        let keychainQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        defer { SecItemDelete(keychainQuery as CFDictionary) }

        let privateKey = P256.Signing.PrivateKey()
        let publicKey = privateKey.publicKey.rawRepresentation.base64EncodedString()
        let store = HostPairingStore(service: service, account: account)
        var code = store.generateCode()

        let recoveryService = "com.skyfrost.ncustudyrocket.host.recovery-checks.\(UUID().uuidString)"
        let recoveryQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: recoveryService,
            kSecAttrAccount as String: account
        ]
        defer { SecItemDelete(recoveryQuery as CFDictionary) }
        let preservedDevice = PairedDeviceRecord(
            id: UUID().uuidString,
            name: "Existing iPhone",
            publicKey: publicKey,
            createdAt: .now.addingTimeInterval(-60),
            isRevoked: false
        )
        var recoveryLoadCount = 0
        let recoveryStore = HostPairingStore(service: recoveryService, account: account) { _, _ in
            recoveryLoadCount += 1
            return recoveryLoadCount == 1
                ? ([:], false)
                : ([preservedDevice.id: preservedDevice], true)
        }
        let recoveryCode = recoveryStore.generateCode()
        _ = try recoveryStore.pair(PairRequest(code: recoveryCode, deviceName: "Recovered iPhone", publicKey: publicKey))
        let recoveredRecords = HostPairingStore(service: recoveryService, account: account).list()
        check(recoveredRecords.count == 2, "pairing recovers after a transient Keychain read failure without losing existing devices")
        check(recoveredRecords.contains(where: { $0.id == preservedDevice.id }), "recovery preserves devices read after the Mac is unlocked")

        do {
            _ = try store.pair(PairRequest(code: "１２３４５６", deviceName: "iPhone", publicKey: publicKey))
            check(false, "pairing rejects non-ASCII digits")
        } catch {}
        do {
            _ = try store.pair(PairRequest(code: code, deviceName: " \n ", publicKey: publicKey))
            check(false, "pairing rejects blank device names")
        } catch {}
        do {
            _ = try store.pair(PairRequest(code: code, deviceName: "iPhone", publicKey: String(repeating: "A", count: 257)))
            check(false, "pairing rejects oversized public keys")
        } catch {}

        code = store.generateCode()
        let paired = try store.pair(PairRequest(code: code, deviceName: "  My iPhone  ", publicKey: publicKey))
        check(store.list().first?.name == "My iPhone", "pairing trims and persists the device name")
        check(HostPairingStore(service: service, account: account).list().count == 1, "paired devices reload from Keychain")

        let body = Data("{}".utf8)
        let timestamp = Int64(Date().timeIntervalSince1970)
        let nonce = UUID().uuidString
        let signature = try RequestSigning.sign(
            privateKey: privateKey,
            method: "GET",
            path: "/v1/health",
            timestamp: timestamp,
            nonce: nonce,
            bodyHash: RequestSigning.bodyHash(body)
        )
        let authentication = RequestAuthentication(deviceID: paired.deviceID, timestamp: timestamp, nonce: nonce, signature: signature)
        check(store.verify(authentication, method: "GET", path: "/v1/health", body: body), "valid signed request is accepted")
        check(!store.verify(authentication, method: "GET", path: "/v1/health", body: body), "replayed nonce is rejected")

        let malformedNonce = "not-a-uuid"
        let malformedSignature = try RequestSigning.sign(
            privateKey: privateKey,
            method: "GET",
            path: "/v1/health",
            timestamp: timestamp,
            nonce: malformedNonce,
            bodyHash: RequestSigning.bodyHash(body)
        )
        check(!store.verify(RequestAuthentication(deviceID: paired.deviceID, timestamp: timestamp, nonce: malformedNonce, signature: malformedSignature), method: "GET", path: "/v1/health", body: body), "non-UUID nonce is rejected")

        let first = try store.issueAuthorizationChallenge(for: paired.deviceID)
        let second = try store.issueAuthorizationChallenge(for: paired.deviceID)
        let firstAuthorization = "\(first.challenge)|\(try RequestSigning.signAuthorization(privateKey: privateKey, challenge: first.challenge))"
        let secondAuthorization = "\(second.challenge)|\(try RequestSigning.signAuthorization(privateKey: privateKey, challenge: second.challenge))"
        check(!store.consumeAuthorization(firstAuthorization, for: paired.deviceID), "issuing a new challenge invalidates the prior challenge")
        check(store.consumeAuthorization(secondAuthorization, for: paired.deviceID), "latest authorization challenge is accepted once")
        check(!store.consumeAuthorization(secondAuthorization, for: paired.deviceID), "authorization challenge cannot be replayed")

        try store.revoke(paired.deviceID)
        let reloaded = HostPairingStore(service: service, account: account)
        check(reloaded.list().first?.isRevoked == true, "revocation persists to Keychain")
        let revokedNonce = UUID().uuidString
        let revokedSignature = try RequestSigning.sign(
            privateKey: privateKey,
            method: "GET",
            path: "/v1/health",
            timestamp: timestamp,
            nonce: revokedNonce,
            bodyHash: RequestSigning.bodyHash(body)
        )
        check(!reloaded.verify(RequestAuthentication(deviceID: paired.deviceID, timestamp: timestamp, nonce: revokedNonce, signature: revokedSignature), method: "GET", path: "/v1/health", body: body), "revoked device is rejected")
        print("HostPairingStoreChecks: passed")
    }
}
