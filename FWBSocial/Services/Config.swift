import Foundation

// MARK: - Environment configuration
//
// Single indirection point for the API base URL. `fwb-server` (per PLAN.md §1.5)
// serves production at `api.fwb.events`; local development targets a Vapor
// instance on localhost. Swap `current` below (or wire a build-setting /
// scheme-environment-variable switch) once there's a staging host to target —
// deliberately NOT baked into `APIClient` itself so the base URL can change
// without touching ported-kit code.

enum FWBEnvironment {
    case development
    case production

    var baseURL: String {
        switch self {
        case .development: return "http://localhost:8080"
        case .production:  return "https://api.fwb.events"
        }
    }
}

enum FWBConfig {
    /// The active environment. Defaults to `.development` — flip to `.production`
    /// once `fwb-server` is deployed and `api.fwb.events` resolves (PLAN.md §1.5).
    static let current: FWBEnvironment = .development

    static var baseURL: String { current.baseURL }

    /// Sent as `X-App-Id` on every request.
    static let appId = "fwb-ios"

    /// Must match the bundle id exactly, case-sensitive — it's the APNs topic
    /// (PLAN.md §4.3.4).
    static let bundleId = "events.fwb.social"
}
