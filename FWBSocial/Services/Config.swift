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
        // Custom domain live 2026-08-10: grey-cloud CNAME → fwb-server.fly.dev,
        // Fly cert issued. The fly.dev hostname remains a valid fallback.
        case .production:  return "https://api.fwb.events"
        }
    }
}

nonisolated enum FWBConfig {
    /// The active environment.
    static let current: FWBEnvironment = .production

    /// The API host.
    ///
    /// `FWB_API_BASE` overrides it, **in DEBUG builds only**. This exists for the
    /// end-to-end smoke: an E2EE round trip needs two vetted accounts, vetting is
    /// granted only by an admin or a Luma check-in, and production deliberately has
    /// no admin — so the round trip has to run against a local server, and the base
    /// URL is the one thing that has to change to let it.
    ///
    /// Compiled out of Release so a shipped build cannot be pointed anywhere by an
    /// environment variable.
    static var baseURL: String {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["FWB_API_BASE"], !override.isEmpty {
            return override
        }
        #endif
        return current.baseURL
    }

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
    // Legal pages deploy to the legal.fwb.events subdomain (apex stays on the
    // commissioner's Squarespace site — owner directive 2026-08-10).
    static let termsURL = URL(string: "https://legal.fwb.events/terms")!
    static let privacyURL = URL(string: "https://legal.fwb.events/privacy")!
    static let guidelinesURL = URL(string: "https://legal.fwb.events/guidelines")!
    static let supportEmail = "hello@fwb.events"
    static let agreementsVersion = "2026-08-10"

    /// The age threshold the Declared Age Range gate asks about
    /// (commissioner decision Q16; PLAN.md §6.3).
    static let minimumAge = 18
}
