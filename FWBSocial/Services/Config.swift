import Foundation

// MARK: - Environment configuration
//
// Single indirection point for the API base URL. `fwb-server` (per PLAN.md §1.5)
// will eventually serve production at `api.fwb.events`; that CNAME is NOT wired
// yet (NXDOMAIN as of 2026-08-10), so production currently targets the Fly app
// hostname directly. Swap `production`'s value the day the custom domain is
// attached — deliberately NOT baked into `APIClient` itself so the base URL can
// change without touching ported-kit code.

// `nonisolated` because the whole target builds with
// SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor: without it these constants are
// MainActor-isolated and unreachable from the detached tasks and nonisolated
// delegate callbacks that legitimately need them (sign-out's captured-bearer
// request, the APNs delegate).
nonisolated enum FWBEnvironment {
    case development
    case production

    var baseURL: String {
        switch self {
        case .development: return "http://localhost:8080"
        // TODO: → "https://api.fwb.events" once Cloudflare DNS + the Fly cert
        // are in place (PLAN.md §1.5 / Phase 0). Until then this is the live
        // deployed server and it is what the app ships against.
        case .production:  return "https://fwb-server.fly.dev"
        }
    }
}

nonisolated enum FWBConfig {
    /// The active environment.
    static let current: FWBEnvironment = .production

    static var baseURL: String { current.baseURL }

    /// Sent as `X-App-Id` on every request.
    static let appId = "fwb-ios"

    /// Must match the bundle id exactly, case-sensitive — it's the APNs topic
    /// (PLAN.md §4.3.4), and the server stores it as `fwb_device_tokens.apns_topic`.
    static let bundleId = "events.fwb.social"

    /// APNs environment reported at device registration. A debug build's token
    /// is a sandbox token and is unusable — and indistinguishable from a dead
    /// one — unless it says so (fwb-server `PushController.RegisterDeviceRequest`).
    static var apnsEnvironment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    // MARK: - Hosted legal documents (PLAN.md §6.1)
    //
    // `fwb-web` is not deployed yet (Phase 3 deliverable, separate repo). These
    // are the canonical URLs the EULA screen links to and the versions recorded
    // in `fwb_user_agreements`. Bump `agreementsVersion` whenever the hosted
    // text changes materially — a row is a claim about a specific text, and a
    // boolean cannot answer "did they accept the version with the
    // zero-tolerance clause?".
    static let termsURL = URL(string: "https://fwb.events/terms")!
    static let privacyURL = URL(string: "https://fwb.events/privacy")!
    static let guidelinesURL = URL(string: "https://fwb.events/guidelines")!
    static let supportEmail = "hello@fwb.events"
    static let agreementsVersion = "2026-08-10"

    /// The age threshold the Declared Age Range gate asks about
    /// (commissioner decision Q16; PLAN.md §6.3).
    static let minimumAge = 18
}
