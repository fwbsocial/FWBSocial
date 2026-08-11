import Testing
import Foundation
@testable import FWBSocial

// MARK: - Chat smoke against a live server
//
// Hosted in the app target, so it drives the REAL services — real CryptoKit, real
// keychain, real `APIClient` — rather than a mock of them. That matters here more
// than usual: the thing most likely to be wrong in this port is the exact bytes of
// the device key-binding signature, and only a live server can say whether they
// verify.
//
// **Opt-in.** These create and delete a real account, so they skip unless
// `FWB_SMOKE=1` is set. A routine `xcodebuild test` must not register accounts on
// anyone's server.
//
//   FWB_SMOKE=1                       run against `FWBConfig.baseURL` (production)
//   FWB_SMOKE=1 FWB_SMOKE_BASE=…      run against a local server instead
//
// # What can and cannot be tested where
//
// Production has **no admin account** — `ADMIN_BOOTSTRAP_EMAIL` is deliberately
// unset until the commissioner names the admins (fwb-server HANDOFF). Vetting is
// granted only by an admin or a matched Luma check-in, so there is no
// member-reachable path to a vetted account there, and every `/api/chat/*` route
// except device registration answers 403. Escalating our own account to admin on
// the commissioner's live server to work around that would be privilege escalation,
// not testing.
//
// So this file splits along that line, and the split is itself the finding:
//
//   • `deviceEnrolmentAgainstProduction` — runs on production, because
//     `PUT /api/chat/devices` sits OUTSIDE the vetting gate by design (§4.6). It is
//     the one chat route a pending member can reach, and it happens to be the one
//     carrying the riskiest adaptation in the port.
//   • the round-trip tests — need two vetted, mutually-friended accounts, so they
//     need a local server with a seeded admin.

@Suite(.serialized)
struct ChatSmokeTests {

    // Gated with `.enabled(if:)`, NOT a `#require` inside the body: a failed
    // `#require` is a FAILING test, not a skipped one, so guarding that way turned
    // every routine `xcodebuild test` red. The trait skips.

    private static var baseURL: String {
        ProcessInfo.processInfo.environment["FWB_SMOKE_BASE"] ?? FWBConfig.baseURL
    }

    // MARK: - Device enrolment
    //
    // The assertion that matters is `bindingVerified`.
    //
    // fwb-server's `DeviceKeyVerifier` actually VERIFIES `key_signature` — an
    // approved divergence from Commune, whose server only checked the field was
    // present (PORT_PROVENANCE §4.3). And it verifies over
    // `Data(base64Encoded: quantum_public_key)`, i.e. the DECODED key bytes.
    //
    // Cove signs `"commune.keybinding.v1|" + quantumPublicKeyBase64` instead. Port
    // that payload verbatim and every registration 400s. Sign the right bytes but
    // emit the signature in the wrong encoding and you get `.invalid` rather than
    // `.verified`. Omit the signing key entirely and you get `.unverifiable` —
    // accepted, but silently unverified, which is the worst outcome because it
    // looks like it worked.
    //
    // A green `bindingVerified` is the only proof that all three are right, and it
    // cannot be obtained from a unit test.

    @Test(
        "Device enrolment: keys generate, the PQ binding verifies server-side, and device #1 self-approves",
        .enabled(if: ProcessInfo.processInfo.environment["FWB_SMOKE"] == "1")
    )
    @MainActor
    func deviceEnrolmentAgainstProduction() async throws {
        try await TempAccount.run(baseURL: Self.baseURL) {
            await ChatService.shared.registerDeviceIfNeeded()

            let device = try #require(ChatService.shared.thisDevice, "enrolment produced no device row")
            #expect(ChatService.shared.enrolmentError == nil)

            // §4.3.3(A): `isRoot = (activeApprovedCount == 0)`. A brand-new
            // account's first registration self-promotes to the trust root and is
            // auto-approved, which is why there is no bootstrap ceremony to design.
            //
            // Read `thisDeviceIsRoot`, NOT `device.isRoot`: the server computes
            // `is_root` at registration and the LIST route hardcodes false, so the
            // DTO's copy goes stale as soon as the device list refreshes. (This
            // assertion is how that was found.)
            #expect(ChatService.shared.thisDeviceIsRoot, "device #1 should self-approve as the TOFU root")
            #expect(device.isApproved)
            #expect(device.isActive)

            // THE assertion. See the comment above.
            #expect(device.bindingVerified, "the server could not verify key_signature over quantum_public_key")

            #expect(!device.quantumPublicKey.isEmpty, "the PQ key is mandatory server-side")
            #expect(device.signingPublicKey?.isEmpty == false, "without a signing key the binding is unverifiable")

            // Idempotency: the upsert key is (user_id, identity_key), and the
            // identity key is stable in the keychain. Re-registering must reconcile,
            // not proliferate rows — otherwise every launch adds a device.
            await ChatService.shared.registerDeviceIfNeeded()
            let devices = try await ChatAPI.myDevices()
            #expect(devices.count == 1, "re-registration created a second device row")
            #expect(devices.first?.id == device.id)
        }
    }

    @Test(
        "A pending member reaches device registration but not the rest of chat",
        .enabled(if: ProcessInfo.processInfo.environment["FWB_SMOKE"] == "1")
    )
    @MainActor
    func vettingGateShape() async throws {
        try await TempAccount.run(baseURL: Self.baseURL) {
            // Outside the gate — this is the §4.6 exception, and it must keep
            // working.
            await ChatService.shared.registerDeviceIfNeeded()
            #expect(ChatService.shared.thisDevice != nil)

            // Inside the gate. A pending member gets a 403 with a sentence the
            // client can render, not a bare status.
            await #expect(throws: (any Error).self) {
                _ = try await ChatAPI.conversations()
            }
        }
    }
}

// MARK: - Temp account

/// Registers a throwaway account and deletes it again. Deletion is the point:
/// `deleteAccount` scrambles the identifying columns AND revokes every chat device,
/// so a smoke run leaves no orphaned device row still receiving wrapped keys.
@MainActor
private struct TempAccount {
    let email: String
    let password: String

    /// Registers, runs `body`, and ALWAYS deletes the account — awaited, not fired
    /// into a detached task. A `defer { Task { … } }` is not a teardown: the process
    /// can exit before it runs, and what it leaks is a real account on the
    /// commissioner's server.
    static func run(baseURL: String, _ body: () async throws -> Void) async throws {
        let account = try await register(baseURL: baseURL)
        do {
            try await body()
        } catch {
            await account.cleanUp()
            throw error
        }
        await account.cleanUp()
    }

    static func register(baseURL: String) async throws -> TempAccount {
        let stamp = Int(Date().timeIntervalSince1970)
        let noise = Int.random(in: 1000 ... 9999)
        let email = "smoke-\(stamp)-\(noise)@fwb-smoke.invalid"
        let password = "correct horse battery staple \(noise)"

        struct Body: Encodable {
            let email: String
            let password: String
            let displayName: String
            let username: String?
        }

        // Clear any key material a previous run left behind, so each test enrols a
        // genuinely fresh identity rather than re-registering the last one's.
        await ChatService.shared.destroyLocalKeyMaterial()

        let response: AuthTokenResponse = try await APIClient.shared.request(
            "POST", "/api/auth/register",
            body: try FWBJSON.encoder.encode(Body(
                email: email,
                password: password,
                displayName: "Smoke \(noise)",
                username: nil
            )),
            retryOnUnauth: false
        )
        APIClient.shared.accessToken = response.resolvedAccessToken
        APIClient.shared.refreshToken = response.refreshToken
        await AuthService.shared.restoreSession()

        return TempAccount(email: email, password: password)
    }

    func cleanUp() async {
        try? await APIClient.shared.delete("/api/auth/account")
        APIClient.shared.accessToken = nil
        APIClient.shared.refreshToken = nil
        await ChatService.shared.destroyLocalKeyMaterial()
    }
}
