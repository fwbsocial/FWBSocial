import SwiftUI

// MARK: - Events tab
//
// PLAN.md §4.5.4 and commissioner decision 1: for **48 hours** after an event ends,
// everyone who checked in can see everyone else who checked in, and add them. Then
// the roster is gone and you keep only the people you actually added.
//
// **The deadline is the mechanic, not a limitation.** It is what stops the attendee
// list becoming a scrapeable member directory, and it is the reason decision 9 could
// remove member search entirely without removing discovery. So this screen leans
// into the countdown rather than hiding it.

struct EventsView: View {
    @Environment(AppState.self) private var appState
    @State private var windows: [FriendingWindowDTO] = []
    @State private var lumaStatus: LumaEmailStatusDTO?
    @State private var isLoading = true
    // Kept unflattened so the offline branch and the server's own refusal message
    // both survive as far as the view. See `ErrorStateView`.
    @State private var loadError: Error?

    var body: some View {
        @Bindable var appState = appState

        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                // No in-content title — the navigation bar's large title already
                // says "Events" (they doubled up once nav titles went display-face).
                Text("After an event, you've got 48 hours to add the people you met.")
                    .font(Theme.Typography.preview)
                    .foregroundStyle(.secondary)

                // The Luma-email card sits ABOVE the windows on purpose: an
                // unmatched member sees an empty Events tab and no explanation,
                // and this card is the explanation (§4.5.3).
                if let lumaStatus, !lumaStatus.verified {
                    LumaEmailCard(status: lumaStatus) { await load() }
                }

                if isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, Theme.Spacing.xxl)
                } else if let loadError {
                    ErrorStateView(error: loadError) { Task { await load() } }
                } else if windows.isEmpty {
                    closedState
                } else {
                    ForEach(windows) { window in
                        NavigationLink(value: window.lumaEventId) {
                            FriendingWindowCard(window: window)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("events.window.\(window.lumaEventId)")
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Events")
        .rootSurfaceChrome()
        .navigationDestination(for: String.self) { lumaEventId in
            FriendingWindowView(
                lumaEventId: lumaEventId,
                eventName: windows.first { $0.lumaEventId == lumaEventId }?.eventName
            )
            // A pushed destination is a sibling in the stack, so it needs the
            // theme's surface of its own. See `fwbAppThemeSurface()`.
            .fwbAppThemeSurface()
        }
        .task { await load() }
        .refreshable { await load() }
        // A `FRIENDING_WINDOW` push deep-links straight to the roster — the window
        // is 48 hours long and the push is the only thing that tells you it opened.
        .onChange(of: appState.pendingEventId) { _, id in
            guard let id else { return }
            appState.pendingEventId = nil
            if appState.eventPath.last != id { appState.eventPath.append(id) }
        }
    }

    /// No open window is the NORMAL state — most of the time there isn't an event
    /// in its 48 hours. It should read as "nothing right now", not as a failure.
    private var closedState: some View {
        EmptyStateView(
            icon: "calendar.badge.clock",
            title: "No open windows",
            message: lumaStatus?.verified == false
                ? "Once we can match you to an event check-in, the people you met there will show up here for 48 hours."
                : "When an event you checked into ends, you'll have 48 hours to add the people who were there."
        )
    }

    private func load() async {
        loadError = nil

        // The Luma status is genuinely optional — it only decides whether an
        // explanatory card appears — so its failure stays swallowed. The windows
        // are the screen, so theirs does not.
        //
        // It used to be `try?` on both, which destroyed the `APIError` before
        // anything could read it: a 403 "you aren't vetted yet" and a DNS failure
        // both came out as "We couldn't reach the server." The vetting refusal is
        // the single most likely failure on this screen and the server writes a
        // perfectly good sentence for it.
        async let statusTask = try? await EventsAPI.lumaEmailStatus()
        async let windowsTask = EventsAPI.openWindows()

        lumaStatus = await statusTask
        do {
            windows = try await windowsTask
        } catch {
            if !isCancellationError(error) { loadError = error }
        }
        isLoading = false
    }
}

// MARK: - Window card

private struct FriendingWindowCard: View {
    let window: FriendingWindowDTO

    var body: some View {
        FWBCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text(window.eventName)
                    .font(Theme.Typography.Sue.label)
                    .foregroundStyle(.primary)

                HStack(spacing: Theme.Spacing.sm) {
                    Label(
                        "\(window.attendeeCount) \(window.attendeeCount == 1 ? "person" : "people")",
                        systemImage: "person.2"
                    )
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)

                    StatusBadge(CountdownFormat.remaining(window.secondsRemaining), color: urgencyColor)
                }

                Text("Tap to see who else was there.")
                    .font(Theme.Typography.preview)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Amber inside the last six hours. The roster genuinely disappears, and a
    /// countdown that looks the same at 47 hours and at 20 minutes is not doing its
    /// job.
    private var urgencyColor: Color {
        window.secondsRemaining < 6 * 3600 ? Theme.Colors.caution : Theme.Colors.brand
    }
}

enum CountdownFormat {
    /// Coarse on purpose: "31 hours left" is what a member needs, and a ticking
    /// second counter on a 48-hour deadline is anxiety, not information.
    static func remaining(_ seconds: Int) -> String {
        guard seconds > 0 else { return "Closed" }
        let hours = seconds / 3600
        if hours >= 1 { return "\(hours) \(hours == 1 ? "hour" : "hours") left" }
        let minutes = max(1, seconds / 60)
        return "\(minutes) \(minutes == 1 ? "minute" : "minutes") left"
    }
}
