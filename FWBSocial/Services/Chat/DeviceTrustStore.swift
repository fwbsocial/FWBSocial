import CryptoKit
import Foundation

// MARK: - Safety number
//
// Ported verbatim from Cove (the construction, not the domain string). Derives a
// stable, human-comparable number from a conversation's device identity keys, à la
// Signal. Both parties computing over the SAME sorted set get the SAME number;
// comparing it out of band — read aloud, or side by side — detects a MITM that
// swapped any device key.
//
// SHA-512 iterated 5,200× over (domain ‖ sorted key bytes); the first 30 bytes are
// chunked into six 5-byte groups, each reduced mod 100000 into a zero-padded
// 5-digit group. The iteration is what makes grinding a collision into a chosen
// number expensive.

nonisolated enum SafetyNumber {
    private static let iterations = 5200
    private static let groupCount = 6
    private static let domain = Data("fwb.chat.safetynumber.v1".utf8)

    static func string(forIdentityKeysBase64 keys: [String]) -> String? {
        let cleaned = keys.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }

        // Order-independent: sort the RAW key bytes before hashing, so the two ends
        // agree without agreeing on an ordering.
        let sorted = cleaned
            .compactMap { Data(base64Encoded: $0) }
            .sorted { $0.lexicographicallyPrecedes($1, by: <) }
        guard !sorted.isEmpty else { return nil }

        var input = domain
        for key in sorted { input.append(key) }

        var digest = Data(SHA512.hash(data: input))
        for _ in 1 ..< iterations {
            var next = digest
            next.append(input)
            digest = Data(SHA512.hash(data: next))
        }

        var groups: [String] = []
        for group in 0 ..< groupCount {
            let start = digest.startIndex + group * 5
            var value: UInt64 = 0
            for byte in digest[start ..< (start + 5)] { value = (value << 8) | UInt64(byte) }
            groups.append(String(format: "%05d", value % 100_000))
        }
        return groups.joined(separator: " ")
    }
}

// MARK: - Verdicts

nonisolated enum DeviceTrustVerdict: Equatable, Sendable {
    /// Binding verified and the pin matched.
    case trusted
    /// Binding verified, first sight, and this peer had no pinned devices — a
    /// genuine first contact. Pinned now.
    case firstContact
    /// Binding verified, first sight, but this peer ALREADY had pinned devices —
    /// they added a device. Usable, and surfaced: this is the case Signal shows as
    /// "Alex's safety number has changed", and staying silent about it is how a
    /// server-injected device slips past a client that only watches for changes to
    /// devices it already knows.
    case newDeviceForKnownPeer
    /// The device published a `signing_public_key` but its `key_signature` did not
    /// verify over its `quantum_public_key`. NEVER wrap to this.
    case signatureInvalid
    /// A previously pinned device now presents a DIFFERENT identity or signing key.
    /// Do not use until the member re-accepts out of band.
    case securityCodeChanged

    /// Whether this device may be wrapped to without further user action.
    var isUsable: Bool {
        switch self {
        case .trusted, .firstContact, .newDeviceForKnownPeer: return true
        case .signatureInvalid, .securityCodeChanged: return false
        }
    }

    /// Whether the member should be told, even though the send proceeds.
    var advisory: String? {
        switch self {
        case .newDeviceForKnownPeer: return "added a new device"
        case .trusted, .firstContact, .signatureInvalid, .securityCodeChanged: return nil
        }
    }
}

/// A per-device note surfaced on the conversation. Advisory kinds do not block a
/// send; blocking kinds mean that device was skipped and its owner cannot read the
/// message on it.
nonisolated struct DeviceTrustWarning: Sendable, Identifiable, Equatable {
    enum Kind: String, Sendable {
        case signatureInvalid
        case securityCodeChanged
        case newDevice
        case quantumRequiredButMissing
    }

    var id: UUID { deviceId }
    let deviceId: UUID
    let deviceName: String
    let ownerId: UUID
    let kind: Kind

    var isBlocking: Bool {
        switch kind {
        case .signatureInvalid, .securityCodeChanged, .quantumRequiredButMissing: return true
        case .newDevice: return false
        }
    }

    var message: String {
        switch kind {
        case .signatureInvalid:
            return "\(deviceName) couldn't be verified and was skipped."
        case .securityCodeChanged:
            return "\(deviceName)'s security code changed. Verify it before messaging that device."
        case .newDevice:
            return "\(deviceName) is a new device on this conversation."
        case .quantumRequiredButMissing:
            return "\(deviceName) can't do quantum-secure encryption and was skipped."
        }
    }
}

// MARK: - Pin record

nonisolated struct DevicePin: Codable, Sendable, Equatable {
    let deviceId: UUID
    let ownerId: UUID
    let identityKey: String
    var signingPublicKey: String?
    var quantumPublicKey: String?
    var quantumKeySignature: String?
    let firstSeen: Date
    var lastVerified: Date
}

// MARK: - Trust store
//
// Ported from Cove's `DeviceTrustStore` (586 LoC). Two layers survive intact:
//
//   1. SIGNATURE VERIFICATION (stateless). Each device publishes
//      `signing_public_key` and a `key_signature` over its `quantum_public_key`.
//      A device that fails this is never wrapped to. Note this binds the PQ key to
//      the signing key *the response itself carries* — it does not by itself prove
//      the signing key belongs to the real member. That is what layer 2 and the
//      out-of-band safety-number compare are for.
//
//   2. TOFU PIN (stateful, keychain). First successful sight pins
//      (deviceId → identityKey + signingPublicKey). Any later sight where either
//      differs is `securityCodeChanged`: no silent trust, explicit re-acceptance.
//
// **What did NOT survive, and why it matters.** Cove also ran an approval-CHAIN
// check: every non-root peer device had to carry an `approval_signature` made by an
// already-trusted device of the same member over the new device's identity key, so
// a server could not inject a device by flipping `is_approved`. fwb-server's
// `ChatDeviceResponse` returns neither `enrolled_by_device_id` nor
// `approval_signature`, so that layer has nothing to run on. The replacement is
// `newDeviceForKnownPeer` above: an injected device is a first sight for a peer we
// already know, which is surfaced rather than silently pinned. That is weaker than
// a signature chain and it is recorded as a gap, not papered over.

actor DeviceTrustStore {
    static let shared = DeviceTrustStore()

    /// Hard-fail devices that publish no signing key rather than soft-allowing them.
    /// FWB has no legacy devices — the first registration on this server will be by
    /// this client — so there is nothing to grandfather and the rollout soft-allow
    /// Cove needed is closed from day one.
    nonisolated static let requireSignedDevices = true

    private let pinStoreKey = "fwb.chat.devicetrust.pins.v1"
    private let verifiedMarksKey = "fwb.chat.devicetrust.verified.v1"

    private init() {}

    // MARK: - Evaluation

    /// Verify a peer device's key binding and reconcile it against the TOFU pin.
    /// Mutates the pin store only on a usable, non-conflicting verdict — NEVER on a
    /// mismatch, which must be accepted explicitly via `acceptKeyChange`.
    func evaluate(_ device: ChatDeviceDTO) -> DeviceTrustVerdict {
        // 1. Signature layer.
        if let signingKey = device.signingPublicKey, !signingKey.isEmpty {
            guard let signature = Data(base64Encoded: device.keySignature),
                  let payload = ChatEncryptionService.keyBindingSignaturePayload(
                      quantumPublicKeyBase64: device.quantumPublicKey
                  ),
                  ChatEncryptionService.shared.verifySignature(
                      signature, of: payload, publicKeyBase64: signingKey
                  )
            else { return .signatureInvalid }
        } else if Self.requireSignedDevices {
            return .signatureInvalid
        }

        // 2. TOFU pin layer.
        let all = loadAll()
        guard let existing = all[device.id.uuidString] else {
            // First sight. Whether this is benign depends entirely on whether we
            // already know OTHER devices of the same member.
            let peerAlreadyKnown = all.values.contains { $0.ownerId == device.userId }
            upsert(DevicePin(
                deviceId: device.id,
                ownerId: device.userId,
                identityKey: device.identityKey,
                signingPublicKey: device.signingPublicKey,
                quantumPublicKey: device.quantumPublicKey.isEmpty ? nil : device.quantumPublicKey,
                quantumKeySignature: device.keySignature.isEmpty ? nil : device.keySignature,
                firstSeen: Date(),
                lastVerified: Date()
            ))
            return peerAlreadyKnown ? .newDeviceForKnownPeer : .firstContact
        }

        // The identity key is the long-term device key. A change is a security-code
        // event, full stop.
        guard existing.identityKey == device.identityKey else { return .securityCodeChanged }

        if let pinned = existing.signingPublicKey, !pinned.isEmpty {
            guard device.signingPublicKey == pinned else {
                // Changed or disappeared on a device that previously had one. We
                // cannot distinguish a legitimate rotation from a substitution
                // offline, so we take the conservative reading.
                return .securityCodeChanged
            }
        }

        // Refresh the watermark and the cached PQ binding — the PQ key can
        // legitimately rotate under an unchanged signing identity, and the binding
        // signature verified above.
        var refreshed = existing
        refreshed.lastVerified = Date()
        if device.signingPublicKey?.isEmpty == false { refreshed.signingPublicKey = device.signingPublicKey }
        if !device.quantumPublicKey.isEmpty {
            refreshed.quantumPublicKey = device.quantumPublicKey
            refreshed.quantumKeySignature = device.keySignature
        }
        upsert(refreshed)
        return .trusted
    }

    /// Explicitly accept a changed device, after the member verified it out of band.
    /// Re-pins the CURRENT keys so later sights are trusted.
    func acceptKeyChange(for device: ChatDeviceDTO) {
        upsert(DevicePin(
            deviceId: device.id,
            ownerId: device.userId,
            identityKey: device.identityKey,
            signingPublicKey: device.signingPublicKey,
            quantumPublicKey: device.quantumPublicKey.isEmpty ? nil : device.quantumPublicKey,
            quantumKeySignature: device.keySignature.isEmpty ? nil : device.keySignature,
            firstSeen: pin(for: device.id)?.firstSeen ?? Date(),
            lastVerified: Date()
        ))
    }

    func isPinned(_ deviceId: UUID) -> Bool { pin(for: deviceId) != nil }

    func pinnedRecord(for deviceId: UUID) -> DevicePin? { pin(for: deviceId) }

    func forget(_ deviceId: UUID) {
        var all = loadAll()
        all.removeValue(forKey: deviceId.uuidString)
        save(all)
    }

    // MARK: - Manual verification marks

    /// Record that the member verified a conversation's safety number. We store the
    /// EXACT string that was verified, so if the device set later changes the stored
    /// value no longer matches and the UI re-prompts — a "verified" badge that
    /// survived a new device would be a lie.
    func setVerified(_ verified: Bool, conversationId: UUID, safetyNumber: String) {
        var marks = loadVerifiedMarks()
        if verified {
            marks[conversationId.uuidString] = safetyNumber
        } else {
            marks.removeValue(forKey: conversationId.uuidString)
        }
        saveVerifiedMarks(marks)
    }

    func isVerified(conversationId: UUID, currentSafetyNumber: String) -> Bool {
        loadVerifiedMarks()[conversationId.uuidString] == currentSafetyNumber
    }

    /// Account deletion only. Sign-out deliberately does NOT clear pins — see
    /// `ChatService.handleSignOut` and PLAN.md §4.3.3(C).
    func clearAll() {
        ChatKeychain.delete(forKey: pinStoreKey)
        ChatKeychain.delete(forKey: verifiedMarksKey)
    }

    // MARK: - Storage

    private func pin(for deviceId: UUID) -> DevicePin? { loadAll()[deviceId.uuidString] }

    private func upsert(_ record: DevicePin) {
        var all = loadAll()
        all[record.deviceId.uuidString] = record
        save(all)
    }

    private func loadAll() -> [String: DevicePin] {
        guard let data = ChatKeychain.load(forKey: pinStoreKey) else { return [:] }
        if let all = try? JSONDecoder().decode([String: DevicePin].self, from: data) { return all }
        // A single corrupt entry must NOT blank the whole store: that would silently
        // re-TOFU every device, so a key substitution made in the meantime would go
        // undetected. Skip only the bad entries.
        guard let raw = try? JSONDecoder().decode([String: FailableDecodable<DevicePin>].self, from: data) else {
            return [:]
        }
        return raw.compactMapValues(\.value)
    }

    private func save(_ all: [String: DevicePin]) {
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? ChatKeychain.save(data, forKey: pinStoreKey)
    }

    private func loadVerifiedMarks() -> [String: String] {
        guard let data = ChatKeychain.load(forKey: verifiedMarksKey) else { return [:] }
        if let marks = try? JSONDecoder().decode([String: String].self, from: data) { return marks }
        guard let raw = try? JSONDecoder().decode([String: FailableDecodable<String>].self, from: data) else {
            return [:]
        }
        return raw.compactMapValues(\.value)
    }

    private func saveVerifiedMarks(_ marks: [String: String]) {
        guard let data = try? JSONEncoder().encode(marks) else { return }
        try? ChatKeychain.save(data, forKey: verifiedMarksKey)
    }
}

/// Decodes to nil rather than throwing, so a dictionary decode can skip corrupt
/// entries instead of failing wholesale.
private nonisolated struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? decoder.singleValueContainer().decode(T.self)
    }
}
