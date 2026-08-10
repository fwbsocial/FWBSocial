import Foundation

// MARK: - Push device registration endpoints
//
// Ported from Flux's `PushAPI.swift` (extension on `APIClient`, per house rule:
// endpoint methods live in their own file, never edited into `APIClient.swift`
// directly). Talks to the shared multi-app PushController shape
// (PLAN.md §2.1 `fwb_device_tokens`):
//   POST   /api/push/register-device    { token, appIdentifier } -> 200
//   DELETE /api/push/unregister-device  { token, appIdentifier } -> 204
//
// `appIdentifier` must be exactly the bundle id (`events.fwb.social`) — the
// APNs topic the backend targets — case-sensitive (PLAN.md §4.3.4).

extension APIClient {
    private struct PushDeviceBody: Encodable {
        let token: String
        let appIdentifier: String
    }

    /// Register this device's APNs token so the backend can target it.
    func registerPushDevice(token: String, appIdentifier: String) async throws {
        try await postVoid(
            "/api/push/register-device",
            body: PushDeviceBody(token: token, appIdentifier: appIdentifier))
    }

    /// Best-effort unregister on sign-out. DELETE with a JSON body (the shared
    /// `request` core carries the body through and treats 204 as success).
    func unregisterPushDevice(token: String, appIdentifier: String) async throws {
        let _: EmptyResponse = try await request(
            "DELETE", "/api/push/unregister-device",
            body: try FWBJSON.encoder.encode(
                PushDeviceBody(token: token, appIdentifier: appIdentifier)))
    }
}
