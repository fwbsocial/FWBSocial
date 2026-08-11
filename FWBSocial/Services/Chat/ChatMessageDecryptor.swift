import CryptoKit
import Foundation
import Security

// MARK: - Shared crypto constants
//
// Compiled into BOTH the app and `FWBSocialNotificationService`. An extension
// cannot import its host app, and these five values must be byte-identical on both
// sides or the NSE decrypts nothing and every banner silently degrades to
// "New message" (PLAN.md R5). They live here, next to the code that is already
// shared, rather than in a file only one target compiles.

nonisolated enum ChatCryptoConstants {
    /// HPKE `info` for the X-Wing key wrap. Must match on wrap and unwrap.
    static let hpkeInfo = Data("FWBChat-PQHPKE-MessageKey-v1".utf8)

    /// HKDF salt for the classical (ephemeral P-256 ECDH) wrap.
    static let classicalWrapSalt = Data("FWBChat-P256-MessageKey-v1".utf8)

    /// Keychain account for this device's X-Wing private key.
    static let quantumKeyTag = "fwb.chat.device.quantum.xwing"

    /// Keychain account for this device's chat device id.
    static let deviceIdTag = "fwb.chat.device.id"

    /// Keychain service namespacing every chat key item. Must match `ChatKeychain`.
    static let keychainService = "events.fwb.social.chatkeys"
}

// MARK: - Decryptor
//
// SHARED between the app target and the NSE so the extension can decrypt ONE
// message body for a rich push preview without importing the host app. CryptoKit +
// Security only — no Secure Enclave, no UIKit, no SwiftUI.
//
// The NSE path is QUANTUM-ONLY by construction: it reads the `AfterFirstUnlock`
// X-Wing private key from the shared keychain group, but never the Secure Enclave
// identity key (which is `WhenUnlocked` + `.privateKeyUsage` and unavailable to a
// background extension on a locked phone). A classical-wrapped message therefore
// cannot be previewed here and falls back to the generic banner upstream — which is
// the correct trade, since `require_quantum` defaults TRUE server-side so classical
// wraps are the rare exception.
//
// KEYCHAIN NOTE (house gotcha `reference_commune_nse_keychain_no_migration`): the
// reads below are deliberately GROUPLESS. A groupless `SecItemCopyMatching` searches
// every access group the calling process is entitled to, so it finds the app-written
// items from inside the extension. Do NOT add `kSecAttrAccessGroup` here, and do NOT
// re-save the quantum key from the NSE — a re-save under a different group would
// orphan every message already wrapped to the original.

nonisolated enum ChatMessageDecryptor {

    // Auth-token coordinates. MUST match `KeychainHelper`.
    private static let tokenService = "events.fwb.social.auth"
    private static let accessTokenAccount = "fwb.accessToken"

    /// The bearer access token, or nil when signed out / before first unlock.
    static var authToken: String? {
        genericPassword(account: accessTokenAccount, service: tokenService)
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    /// This device's chat device id, for the `?device=` query on the NSE fetch.
    static var deviceId: String? {
        genericPassword(account: ChatCryptoConstants.deviceIdTag, service: ChatCryptoConstants.keychainService)
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Diagnostic: can this process reach the X-Wing private key? Proves the
    /// keychain-sharing wiring on device, where getting it wrong is otherwise
    /// invisible.
    static var hasQuantumKey: Bool {
        genericPassword(account: ChatCryptoConstants.quantumKeyTag, service: ChatCryptoConstants.keychainService) != nil
    }

    private static func genericPassword(account: String, service: String?) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let service { query[kSecAttrService as String] = service }
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    // MARK: - Decrypt

    enum Failure: Error {
        case badPackage
        case badBody
        case noQuantumKey
    }

    /// Unwrap a quantum-wrapped per-message key, then AES-GCM-open the sealed body.
    /// Throws → the caller shows the generic fallback. Never crashes, never blanks.
    static func decryptText(wrappedKeyBase64: String, encryptedContentBase64: String) throws -> String {
        let key = try unwrapMessageKeyQuantum(wrappedKeyBase64)
        return try openBody(encryptedContentBase64, with: key)
    }

    /// Package layout, mirroring `ChatEncryptionService.wrapKeyQuantum`:
    ///   `[4 bytes big-endian length][HPKE encapsulated key][HPKE ciphertext]`
    static func unwrapMessageKeyQuantum(_ packageBase64: String) throws -> SymmetricKey {
        guard let package = Data(base64Encoded: packageBase64), package.count > 4 else {
            throw Failure.badPackage
        }
        // Alignment-safe big-endian read: a `Data` slice carries no 4-byte alignment
        // guarantee, so `load(as: UInt32.self)` would be undefined behaviour.
        let header = Array(package.prefix(4))
        let keyLength = (Int(header[0]) << 24) | (Int(header[1]) << 16) | (Int(header[2]) << 8) | Int(header[3])
        guard keyLength > 0, package.count > 4 + keyLength else { throw Failure.badPackage }

        let encapsulated = package[4 ..< (4 + keyLength)]
        let ciphertext = package[(4 + keyLength)...]

        guard let privateKeyData = genericPassword(
            account: ChatCryptoConstants.quantumKeyTag,
            service: ChatCryptoConstants.keychainService
        ) else { throw Failure.noQuantumKey }

        let privateKey = try XWingMLKEM768X25519.PrivateKey(integrityCheckedRepresentation: privateKeyData)
        var recipient = try HPKE.Recipient(
            privateKey: privateKey,
            ciphersuite: .XWingMLKEM768X25519_SHA256_AES_GCM_256,
            info: ChatCryptoConstants.hpkeInfo,
            encapsulatedKey: Data(encapsulated)
        )
        return SymmetricKey(data: try recipient.open(Data(ciphertext)))
    }

    /// The sealed body IS `nonce(12) ‖ ciphertext ‖ tag` — exactly an
    /// `AES.GCM.SealedBox(combined:)`.
    static func openBody(_ base64: String, with key: SymmetricKey) throws -> String {
        guard let combined = Data(base64Encoded: base64), combined.count > 12 else {
            throw Failure.badBody
        }
        let box = try AES.GCM.SealedBox(combined: combined)
        let plaintext = try AES.GCM.open(box, using: key)
        guard let string = String(data: plaintext, encoding: .utf8) else { throw Failure.badBody }
        return string
    }
}
