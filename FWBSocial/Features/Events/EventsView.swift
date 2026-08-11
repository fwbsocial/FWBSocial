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
    /// The windows and the Luma status live in `EventsStore`, warmed at launch by
    /// `AppPrefetch` (owner directive 2026-08-11: a member never sees a tab
    /// load). They were `@State` here, so the countdown cards did not exist until
    /// the tab was first opened and were refetched on every return to it.
    ///
    /// The store keeps the failure unflattened for the reason this view already
    /// cared about: the vetting refusal is the likeliest failure on this screen
    /// and the server writes the sentence for it. See `ErrorStateView`.
    @State private var store = EventsStore.shared
    @State private var isAddingFriend = false

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
                if let status = store.lumaStatus, !status.verified {
                    LumaEmailCard(status: status) { await store.refresh() }
                }

                // The ONE spinner: before any data has ever arrived, and never
                // again. With the launch prefetch in place the member should not
                // reach it — every later refresh happens behind the cards.
                if !store.hasLoaded {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, Theme.Spacing.xxl)
                } else if let failure = store.loadError, store.windows.isEmpty {
                    ErrorStateView(error: failure) { Task { await store.refresh() } }
                } else if store.windows.isEmpty {
                    closedState
                } else {
                    // A refresh that failed over windows already on screen is one
                    // line, not a takeover — the countdowns behind it are real.
                    if let failure = store.loadError {
                        InlineErrorRow(message: failure.fwbMessage) {
                            Task { await store.refresh() }
                        }
                    }

                    ForEach(store.windows) { window in
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
        // Owner directive 2026-08-11: every page registers. Most of the time this
        // tab is honestly empty — there is no event inside its 48 hours — and the
        // screen's whole subject is adding the people you met. The friend code is
        // the path that works when the roster has closed, or when the person you
        // met is standing next to you now.
        .floatingAction(
            isVisible: true,
            systemImage: "person.badge.plus",
            label: "Add",
            voiceOverLabel: "Add friend by code"
        ) { isAddingFriend = true }
        .sheet(isPresented: $isAddingFriend) {
            DismissableSheet { AddFriendSheet() }
        }
        .navigationDestination(for: String.self) { lumaEventId in
            FriendingWindowView(
                lumaEventId: lumaEventId,
                eventName: store.windows.first { $0.lumaEventId == lumaEventId }?.eventName
            )
            // A pushed destination is a sibling in the stack, so it needs the
            // theme's surface of its own. See `fwbAppThemeSurface()`.
            .fwbAppThemeSurface()
        }
        // Warm, not load: `AppPrefetch` fired this at launch and it is a no-op
        // once the store holds an answer, so entering the tab shows the cards
        // that are already there rather than reloading them.
        .task { await store.warm() }
        .refreshable { await store.refresh() }
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
            message: store.lumaStatus?.verified == false
                ? "Once we can match you to an event check-in, the people you met there will show up here for 48 hours."
                : "When an event you checked into ends, you'll have 48 hours to add the people who were there."
        )
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
