import Foundation

// MARK: - Push device registration endpoints
//
// Extension on `APIClient` per house rule: endpoint methods live in their own
// file, never edited into `APIClient.swift` directly.
//
// **Rewritten against the deployed contract.** The ported Flux kit called the
// AppTapTap fleet's shared shape (`POST /api/push/register-device` with an
// `appIdentifier` field). fwb-server does not have that route — see
// `Sources/App/Push/PushController.swift` and `routes.swift`:
//
//   POST   /api/push/devices   { token, bundle_id, environment } -> 200
//   DELETE /api/push/devices   { token }                         -> 204
//
// `bundle_id` must be exactly the bundle id (`events.fwb.social`) — the server
// stores it as `apns_topic`, which APNs matches case-sensitively. `environment`
// must say `sandbox` for a debug build, or the token is unusable and
// indistinguishable from a dead one.

extension APIClient {
    private struct RegisterDeviceBody: Encodable {
        let token: String
        let bundleId: String
        let environment: String
    }

    private struct UnregisterDeviceBody: Encodable {
        let token: String
    }

    /// Register this device's APNs token so the backend can target it. The
    /// server upserts on `token` and deliberately does NOT evict the member's
    /// other devices — multi-device is expected here (PLAN.md §4.3.3).
    func registerPushDevice(token: String, bundleId: String, environment: String) async throws {
        try await postVoid(
            "/api/push/devices",
            body: RegisterDeviceBody(token: token, bundleId: bundleId, environment: environment))
    }

    /// Best-effort unregister on sign-out. DELETE with a JSON body; the server
    /// scopes the delete to the caller so a replayed token can't unregister
    /// someone else's device.
    func unregisterPushDevice(token: String) async throws {
        let _: EmptyResponse = try await request(
            "DELETE", "/api/push/devices",
            body: try FWBJSON.encoder.encode(UnregisterDeviceBody(token: token)))
    }
}
