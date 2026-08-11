import CryptoKit
import Foundation

// MARK: - Chat encryption
//
// Ported from Cove's `EncryptionService` (PLAN.md §4.3.2 keep-set, ~887 LoC) with
// the crypto intact — post-quantum wrapping included, fail-closed under
// `require_quantum`. This is debugged, production-proven code, not new
// cryptography, and the port keeps it that way.
//
// Key hierarchy, unchanged from the source:
//   identity key        P-256 KeyAgreement in the Secure Enclave. ECDH only —
//                       it CANNOT sign, which is why there is a second key.
//   signing key         P-256 Signing in the Secure Enclave. Signs the
//                       classical↔PQ binding and device-approval signatures.
//   quantum key         X-Wing (ML-KEM-768 + X25519) private key in the keychain.
//   per-message key     random AES-256, wrapped once per recipient device.
//   group key           random AES-256 per version, wrapped per device.
//
// THREE ADAPTATIONS from Cove, each load-bearing:
//
//  1. **`keyBindingSignaturePayload` signs the RAW PQ key bytes.** Cove signed
//     `"commune.keybinding.v1|" + quantumPublicKeyBase64` and its server only
//     checked the field was present. fwb-server VERIFIES the signature for real
//     (`DeviceKeyVerifier.verifyBinding`, an approved divergence recorded in
//     PORT_PROVENANCE §4.3) and it verifies over `Data(base64Encoded:
//     quantum_public_key)` — the decoded key bytes. Signing Cove's payload here
//     would make every single device registration 400. The client's own peer
//     verification uses the same rule, so both ends agree.
//
//  2. Signatures are emitted in **DER**, which is CryptoKit's default and what
//     fwb-server tries first. It accepts raw 64-byte r‖s as a fallback; DER is
//     the cheaper path.
//
//  3. Keychain tags and the HPKE `info` string are namespaced to FWB. Nothing
//     migrates from Cove — this is a separate app with separate accounts.

/// Thread-safe via actor isolation. Crypto runs off the main thread; every public
/// method is safe to call from any context.
actor ChatEncryptionService {
    static let shared = ChatEncryptionService()

    // Keychain tags. `fwb.chat.*` so they can never be confused with the auth
    // tokens (which live under `KeychainHelper.authService`).
    private let identityKeyTag = "fwb.chat.device.identity.p256"
    private let signingKeyTag = "fwb.chat.device.signing.p256"
    private let signingKeyIsSoftwareTag = "fwb.chat.device.signing.p256.isSoftware"
    private let quantumKeyTag = ChatCryptoConstants.quantumKeyTag
    private let deviceIdTag = ChatCryptoConstants.deviceIdTag

    private init() {}

    // MARK: - Identity key (P-256 KeyAgreement, Secure Enclave)

    /// Generate the device identity key. The private key never leaves the Secure
    /// Enclave where one exists; the Simulator falls back to a software key.
    @discardableResult
    func generateIdentityKeyPair() throws -> String {
        ChatKeychain.delete(forKey: identityKeyTag)

        if SecureEnclave.isAvailable {
            guard let accessControl = SecAccessControlCreateWithFlags(
                kCFAllocatorDefault,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                [.privateKeyUsage],
                nil
            ) else { throw ChatCryptoError.encryptionFailed }

            let privateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: accessControl)
            try ChatKeychain.save(privateKey.dataRepresentation, forKey: identityKeyTag)
            return privateKey.publicKey.rawRepresentation.base64EncodedString()
        } else {
            let privateKey = P256.KeyAgreement.PrivateKey()
            try ChatKeychain.save(privateKey.rawRepresentation, forKey: identityKeyTag)
            return privateKey.publicKey.rawRepresentation.base64EncodedString()
        }
    }

    var hasIdentityKey: Bool { ChatKeychain.load(forKey: identityKeyTag) != nil }

    /// This device's identity public key (base64, raw representation). Generates on
    /// first use so callers never have to sequence generation explicitly.
    func identityPublicKeyBase64() throws -> String {
        guard hasIdentityKey else { return try generateIdentityKeyPair() }
        if SecureEnclave.isAvailable {
            return try loadSEIdentityKey().publicKey.rawRepresentation.base64EncodedString()
        }
        return try loadSoftwareIdentityKey().publicKey.rawRepresentation.base64EncodedString()
    }

    // MARK: - Device id

    func storeDeviceId(_ id: UUID) throws {
        guard let data = id.uuidString.data(using: .utf8) else { throw ChatCryptoError.encodingFailed }
        try ChatKeychain.save(data, forKey: deviceIdTag)
    }

    func deviceId() -> UUID? {
        guard let data = ChatKeychain.load(forKey: deviceIdTag),
              let string = String(data: data, encoding: .utf8) else { return nil }
        return UUID(uuidString: string)
    }

    // MARK: - Signing key (P-256 Signing, Secure Enclave)

    var hasSigningKey: Bool { ChatKeychain.load(forKey: signingKeyTag) != nil }

    /// True when the signing key is a software key because no Secure Enclave was
    /// available (the Simulator). Surfaced so the UI can say "not hardware-backed"
    /// rather than implying a guarantee this device cannot make.
    var signingKeyIsSoftwareBacked: Bool { ChatKeychain.load(forKey: signingKeyIsSoftwareTag) != nil }

    @discardableResult
    func generateSigningKeyPair() throws -> String {
        ChatKeychain.delete(forKey: signingKeyTag)
        ChatKeychain.delete(forKey: signingKeyIsSoftwareTag)

        if SecureEnclave.isAvailable {
            guard let accessControl = SecAccessControlCreateWithFlags(
                kCFAllocatorDefault,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                [.privateKeyUsage],
                nil
            ) else { throw ChatCryptoError.encryptionFailed }

            let privateKey = try SecureEnclave.P256.Signing.PrivateKey(accessControl: accessControl)
            try ChatKeychain.save(privateKey.dataRepresentation, forKey: signingKeyTag)
            return privateKey.publicKey.x963Representation.base64EncodedString()
        } else {
            let privateKey = P256.Signing.PrivateKey()
            try ChatKeychain.save(privateKey.rawRepresentation, forKey: signingKeyTag)
            try ChatKeychain.save(Data([1]), forKey: signingKeyIsSoftwareTag)
            return privateKey.publicKey.x963Representation.base64EncodedString()
        }
    }

    /// Base64 x9.63 signing public key — the form fwb-server tries first.
    func signingPublicKeyBase64() throws -> String {
        guard hasSigningKey else { return try generateSigningKeyPair() }
        if signingKeyIsSoftwareBacked {
            return try loadSoftwareSigningKey().publicKey.x963Representation.base64EncodedString()
        }
        return try loadSESigningKey().publicKey.x963Representation.base64EncodedString()
    }

    /// ECDSA-P256 signature over `data`, **DER-encoded**.
    func sign(_ data: Data) throws -> Data {
        if signingKeyIsSoftwareBacked {
            return try loadSoftwareSigningKey().signature(for: data).derRepresentation
        }
        return try loadSESigningKey().signature(for: data).derRepresentation
    }

    /// Verify a DER (or raw) ECDSA-P256 signature against a base64 x9.63 public key.
    /// Returns false rather than throwing on any malformed input, so one bad peer
    /// device can never break a whole send — the caller decides how to react.
    nonisolated func verifySignature(_ signature: Data, of data: Data, publicKeyBase64: String) -> Bool {
        guard let keyData = Data(base64Encoded: publicKeyBase64) else { return false }
        let publicKey: P256.Signing.PublicKey
        if let key = try? P256.Signing.PublicKey(x963Representation: keyData) {
            publicKey = key
        } else if let key = try? P256.Signing.PublicKey(derRepresentation: keyData) {
            publicKey = key
        } else if let key = try? P256.Signing.PublicKey(rawRepresentation: keyData) {
            publicKey = key
        } else {
            return false
        }

        let parsed: P256.Signing.ECDSASignature
        if let sig = try? P256.Signing.ECDSASignature(derRepresentation: signature) {
            parsed = sig
        } else if let sig = try? P256.Signing.ECDSASignature(rawRepresentation: signature) {
            parsed = sig
        } else {
            return false
        }
        return publicKey.isValidSignature(parsed, for: data)
    }

    // MARK: - Signature payloads

    /// **The exact bytes fwb-server verifies** for `key_signature`, and therefore
    /// the exact bytes this client signs and checks against peers:
    /// the RAW (base64-decoded) X-Wing public key.
    ///
    /// See `DeviceKeyVerifier.verifyBinding` — `publicKey.isValidSignature(signature,
    /// for: Data(base64Encoded: quantumPublicKey))`. Adding Cove's domain-separation
    /// prefix here would 400 every registration. The binding is still
    /// domain-separated in practice by the key's own structure and by the fact that
    /// the signing key signs nothing else in this shape.
    nonisolated static func keyBindingSignaturePayload(quantumPublicKeyBase64: String) -> Data? {
        Data(base64Encoded: quantumPublicKeyBase64)
    }

    /// The bytes an approving device signs over a newly enrolled device's identity
    /// key. **Client-only** — fwb-server stores `approval_signature` without
    /// verifying it (deliberately: the server holds no key that could check it, and
    /// the trust decision belongs to the device). Both ends of this check are ours,
    /// so it keeps Cove's domain separation, renamed.
    nonisolated static func deviceApprovalSignaturePayload(identityKeyBase64: String) -> Data {
        Data(("fwb.chat.deviceapproval.v1|" + identityKeyBase64).utf8)
    }

    // MARK: - Quantum key (X-Wing: ML-KEM-768 + X25519)

    /// Generate the X-Wing key pair, or return the existing one's public key.
    ///
    /// **Reuse is not an optimization.** Regenerating would rotate this device's PQ
    /// public key on every re-registration, tripping every peer's TOFU
    /// "security code changed" guard and stranding the account.
    func generateQuantumKeyPairIfNeeded() throws -> String {
        if let existing = ChatKeychain.load(forKey: quantumKeyTag),
           let key = try? XWingMLKEM768X25519.PrivateKey(integrityCheckedRepresentation: existing) {
            return key.publicKey.rawRepresentation.base64EncodedString()
        }
        let privateKey = try XWingMLKEM768X25519.PrivateKey.generate()
        try ChatKeychain.save(privateKey.integrityCheckedRepresentation, forKey: quantumKeyTag)
        return privateKey.publicKey.rawRepresentation.base64EncodedString()
    }

    var hasQuantumKey: Bool { ChatKeychain.load(forKey: quantumKeyTag) != nil }

    // MARK: - Key wrapping

    /// Wrap a symmetric key for one recipient device.
    ///
    /// Under `requireQuantum` the classical fallback is **forbidden**: a missing PQ
    /// key on the recipient, or a runtime failure of the quantum wrap, throws so the
    /// caller hard-skips that device rather than silently shipping a non-PQ wrap.
    /// fwb-server defaults `require_quantum` to TRUE and PLAN.md §2.4 is explicit
    /// that FluxDM's relaxed default must not be carried across.
    func wrapKey(
        _ key: SymmetricKey,
        recipientIdentityKeyBase64: String,
        recipientQuantumKeyBase64: String?,
        requireQuantum: Bool
    ) throws -> (wrapped: String, isQuantumSecure: Bool) {
        if let quantumKeyBase64 = recipientQuantumKeyBase64,
           let quantumKeyData = Data(base64Encoded: quantumKeyBase64), !quantumKeyData.isEmpty {
            do {
                return (try wrapKeyQuantum(key, recipientQuantumKeyData: quantumKeyData), true)
            } catch {
                if requireQuantum { throw ChatCryptoError.quantumRequiredButUnavailable }
            }
        } else if requireQuantum {
            throw ChatCryptoError.quantumRequiredButUnavailable
        }
        return (try wrapKeyClassical(key, recipientIdentityKeyBase64: recipientIdentityKeyBase64), false)
    }

    func unwrapKey(_ packageBase64: String, isQuantumSecure: Bool) throws -> SymmetricKey {
        isQuantumSecure
            ? try ChatMessageDecryptor.unwrapMessageKeyQuantum(packageBase64)
            : try unwrapKeyClassical(packageBase64)
    }

    // MARK: Quantum wrap

    private func wrapKeyQuantum(_ key: SymmetricKey, recipientQuantumKeyData: Data) throws -> String {
        let recipientPublicKey = try XWingMLKEM768X25519.PublicKey(rawRepresentation: recipientQuantumKeyData)
        var sender = try HPKE.Sender(
            recipientKey: recipientPublicKey,
            ciphersuite: .XWingMLKEM768X25519_SHA256_AES_GCM_256,
            info: ChatCryptoConstants.hpkeInfo
        )
        let ciphertext = try sender.seal(key.withUnsafeBytes { Data($0) })
        let encapsulated = sender.encapsulatedKey

        // [4-byte big-endian encapsulated-key length][encapsulated key][ciphertext]
        var package = Data()
        var length = UInt32(encapsulated.count).bigEndian
        package.append(Data(bytes: &length, count: 4))
        package.append(encapsulated)
        package.append(ciphertext)
        return package.base64EncodedString()
    }

    // MARK: Classical wrap (ephemeral P-256 ECDH, forward secret)

    private func wrapKeyClassical(_ key: SymmetricKey, recipientIdentityKeyBase64: String) throws -> String {
        guard let recipientKeyData = Data(base64Encoded: recipientIdentityKeyBase64) else {
            throw ChatCryptoError.invalidPublicKey
        }
        let recipientPublicKey = try P256.KeyAgreement.PublicKey(rawRepresentation: recipientKeyData)

        let ephemeral = P256.KeyAgreement.PrivateKey()
        let sharedSecret = try ephemeral.sharedSecretFromKeyAgreement(with: recipientPublicKey)
        let wrappingKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: ChatCryptoConstants.classicalWrapSalt,
            sharedInfo: Data(),
            outputByteCount: 32
        )

        let sealed = try AES.GCM.seal(key.withUnsafeBytes { Data($0) }, using: wrappingKey)
        guard let combined = sealed.combined else { throw ChatCryptoError.encryptionFailed }

        var package = Data()
        package.append(ephemeral.publicKey.x963Representation)   // 65 bytes uncompressed
        package.append(combined)
        return package.base64EncodedString()
    }

    private func unwrapKeyClassical(_ packageBase64: String) throws -> SymmetricKey {
        guard let package = Data(base64Encoded: packageBase64), package.count > 65 else {
            throw ChatCryptoError.invalidEncryptedData
        }
        let ephemeralPublicKey = try P256.KeyAgreement.PublicKey(x963Representation: package.prefix(65))
        let sealedData = package.dropFirst(65)

        let sharedSecret: SharedSecret
        if SecureEnclave.isAvailable {
            sharedSecret = try loadSEIdentityKey().sharedSecretFromKeyAgreement(with: ephemeralPublicKey)
        } else {
            sharedSecret = try loadSoftwareIdentityKey().sharedSecretFromKeyAgreement(with: ephemeralPublicKey)
        }
        let wrappingKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: ChatCryptoConstants.classicalWrapSalt,
            sharedInfo: Data(),
            outputByteCount: 32
        )
        let box = try AES.GCM.SealedBox(combined: sealedData)
        return SymmetricKey(data: try AES.GCM.open(box, using: wrappingKey))
    }

    // MARK: - Content

    nonisolated func generateContentKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

    /// Seal a UTF-8 string into ONE base64 blob: `nonce(12) ‖ ciphertext ‖ tag`.
    /// This is exactly `AES.GCM.SealedBox.combined`, which is what makes the NSE's
    /// standalone decryptor a byte-for-byte mirror rather than a second format.
    nonisolated func seal(_ plaintext: String, with key: SymmetricKey) throws -> String {
        guard let data = plaintext.data(using: .utf8) else { throw ChatCryptoError.encodingFailed }
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else { throw ChatCryptoError.encryptionFailed }
        return combined.base64EncodedString()
    }

    nonisolated func open(_ base64: String, with key: SymmetricKey) throws -> String {
        try ChatMessageDecryptor.openBody(base64, with: key)
    }

    nonisolated func sealMedia(_ data: Data, with key: SymmetricKey) throws -> Data {
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else { throw ChatCryptoError.encryptionFailed }
        return combined
    }

    nonisolated func openMedia(_ data: Data, with key: SymmetricKey) throws -> Data {
        try AES.GCM.open(try AES.GCM.SealedBox(combined: data), using: key)
    }

    // MARK: - Key cache (TTL)

    private struct CacheEntry {
        let key: SymmetricKey
        let cachedAt: Date
    }

    private var keyCache: [String: CacheEntry] = [:]
    private let keyCacheTTL: TimeInterval = 1800   // 30 minutes

    func cacheKey(_ key: SymmetricKey, for identifier: String) {
        keyCache[identifier] = CacheEntry(key: key, cachedAt: Date())
    }

    func cachedKey(for identifier: String) -> SymmetricKey? {
        guard let entry = keyCache[identifier] else { return nil }
        guard Date().timeIntervalSince(entry.cachedAt) <= keyCacheTTL else {
            keyCache.removeValue(forKey: identifier)
            return nil
        }
        return entry.key
    }

    func clearKeyCache() { keyCache.removeAll() }

    // MARK: - Sign-out
    //
    // PLAN.md §4.3.3(C) records the inherited logout keychain-churn defect: Cove
    // deleted every device key on sign-out, so signing back in on the SAME device
    // minted a fresh identity, stranded the old device row, and sealed history to
    // keys that no longer existed. FWB does NOT delete keys on sign-out — see
    // `ChatService.handleSignOut`. This method exists for account deletion, where
    // the device rows are being revoked server-side anyway and leaving private keys
    // behind would be the wrong trade.

    func destroyAllKeys() {
        ChatKeychain.delete(forKey: identityKeyTag)
        ChatKeychain.delete(forKey: signingKeyTag)
        ChatKeychain.delete(forKey: signingKeyIsSoftwareTag)
        ChatKeychain.delete(forKey: quantumKeyTag)
        ChatKeychain.delete(forKey: deviceIdTag)
        keyCache.removeAll()
    }

    // MARK: - Key loading

    private func loadSEIdentityKey() throws -> SecureEnclave.P256.KeyAgreement.PrivateKey {
        guard let data = ChatKeychain.load(forKey: identityKeyTag) else { throw ChatCryptoError.missingDeviceKey }
        return try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: data)
    }

    private func loadSoftwareIdentityKey() throws -> P256.KeyAgreement.PrivateKey {
        guard let data = ChatKeychain.load(forKey: identityKeyTag) else { throw ChatCryptoError.missingDeviceKey }
        return try P256.KeyAgreement.PrivateKey(rawRepresentation: data)
    }

    private func loadSESigningKey() throws -> SecureEnclave.P256.Signing.PrivateKey {
        guard let data = ChatKeychain.load(forKey: signingKeyTag) else { throw ChatCryptoError.missingDeviceKey }
        return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data)
    }

    private func loadSoftwareSigningKey() throws -> P256.Signing.PrivateKey {
        guard let data = ChatKeychain.load(forKey: signingKeyTag) else { throw ChatCryptoError.missingDeviceKey }
        return try P256.Signing.PrivateKey(rawRepresentation: data)
    }
}

// MARK: - Errors

nonisolated enum ChatCryptoError: LocalizedError, Equatable {
    case missingDeviceKey
    case invalidPublicKey
    case invalidEncryptedData
    case encodingFailed
    case decodingFailed
    case encryptionFailed
    case noKeyForMessage
    /// `require_quantum` is on for this conversation but the recipient device has
    /// no usable PQ key (or the wrap failed). Fail closed — skip the device, never
    /// downgrade to a classical wrap.
    case quantumRequiredButUnavailable
    case noUsableRecipientDevices

    var errorDescription: String? {
        switch self {
        case .missingDeviceKey:             return "This device's encryption key is missing."
        case .invalidPublicKey:             return "Invalid public key."
        case .invalidEncryptedData:         return "Couldn't decrypt — the data is corrupted."
        case .encodingFailed:               return "Couldn't encode the message."
        case .decodingFailed:               return "Couldn't decode the decrypted data."
        case .encryptionFailed:             return "Encryption failed."
        case .noKeyForMessage:              return "This device has no key for that message."
        case .quantumRequiredButUnavailable:
            return "This conversation requires quantum-secure encryption, which that device can't provide."
        case .noUsableRecipientDevices:
            return "None of the recipient's devices could be verified, so the message wasn't sent."
        }
    }
}
