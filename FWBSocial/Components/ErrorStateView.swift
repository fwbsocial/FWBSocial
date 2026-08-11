import Foundation
import SwiftUI

// MARK: - Failure presentation
//
// Phase 8 polish. Three defects recurred across ~20 surfaces and this file is the
// single answer to all three:
//
//   1. **A designed empty state drawn on a FAILED load.** `items.isEmpty &&
//      !isLoading` is true when the fetch threw, so the member was told "No open
//      reports. That is the good outcome." while the queue was 500ing. Empty is a
//      claim about the server's answer, and a failure is not an answer — every
//      empty state now sits behind `error == nil`.
//
//   2. **The server's message thrown away.** `APIClient` already reads both error
//      envelopes (flat `reason`, nested `error.message`) and puts the result in
//      `APIError.errorDescription`, so `error.localizedDescription` IS the server's
//      sentence — including the one that distinguishes "pending vetting" from
//      "banned". Replacing it with "We couldn't reach the server." is a downgrade,
//      and it was happening on the vetting-gated surfaces specifically.
//
//   3. **No offline branch.** A dropped connection and a 500 are different
//      problems with different remedies, and only one of them is worth retrying
//      immediately.
//
// House rule this encodes, in priority order: **loading → error → empty → content.**

// MARK: - Classification

extension Error {

    /// True when this failure is the network being unavailable rather than the
    /// server having an opinion.
    ///
    /// Unwraps `APIError.networkError`, which is where `URLSession`'s `URLError`
    /// ends up after `APIClient` boxes it — reading only the outer type is why no
    /// surface outside chat had an offline branch.
    var fwbIsOffline: Bool {
        func isOffline(_ error: Error) -> Bool {
            guard let urlError = error as? URLError else { return false }
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost,
                 .cannotConnectToHost, .cannotFindHost, .timedOut,
                 .dataNotAllowed, .internationalRoamingOff:
                return true
            default:
                return false
            }
        }
        if isOffline(self) { return true }
        // Cast first: inside an `Error` extension `self` is the generic `Self`, so
        // matching an `APIError` case against it directly does not typecheck.
        if let apiError = self as? APIError, case .networkError(let underlying) = apiError {
            return isOffline(underlying)
        }
        return false
    }

    /// The sentence to show the member.
    ///
    /// Prefers `LocalizedError.errorDescription` — which for `APIError` is the
    /// server's own envelope message — and falls back to `localizedDescription`
    /// rather than to a hardcoded string, so a message the server bothered to write
    /// always wins.
    var fwbMessage: String {
        if fwbIsOffline { return "You appear to be offline. Check your connection and try again." }
        if let localized = self as? LocalizedError, let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        return localizedDescription
    }
}

// MARK: - Full-surface error state

/// The designed failure state for a surface that has nothing to show because the
/// load failed.
///
/// Deliberately built on `EmptyStateView` rather than beside it: a member who has
/// learned what a centred glyph over a sentence means on one screen should not
/// have to learn a second vocabulary for the screen next to it. Only the glyph and
/// the tone change.
struct ErrorStateView: View {
    let error: Error
    var retry: (() -> Void)?

    var body: some View {
        EmptyStateView(
            icon: error.fwbIsOffline ? "wifi.slash" : "exclamationmark.triangle",
            title: error.fwbIsOffline ? "You're offline" : "Couldn't load that",
            message: error.fwbMessage,
            actionTitle: retry == nil ? nil : "Try again",
            action: retry)
        .accessibilityIdentifier("error.state")
    }
}

/// The same thing for a surface whose failure is carried as an already-resolved
/// string (a few screens keep `String?` rather than `Error?`).
struct ErrorMessageStateView: View {
    let message: String
    var isOffline: Bool = false
    var retry: (() -> Void)?

    var body: some View {
        EmptyStateView(
            icon: isOffline ? "wifi.slash" : "exclamationmark.triangle",
            title: isOffline ? "You're offline" : "Couldn't load that",
            message: message,
            actionTitle: retry == nil ? nil : "Try again",
            action: retry)
        .accessibilityIdentifier("error.state")
    }
}

// MARK: - Inline failure row

/// A compact failure line for a surface that still has content to show — a form,
/// or a list that loaded once and failed to refresh. Carries the server's message
/// and, optionally, its own retry.
struct InlineErrorRow: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Theme.Colors.danger)
                .accessibilityHidden(true)
            Text(message)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.danger)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let retry {
                Button("Try again", action: retry)
                    .font(Theme.Typography.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.Colors.brand)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("error.inline")
    }
}
