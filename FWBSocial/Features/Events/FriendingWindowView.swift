import SwiftUI

// MARK: - The attendee-match screen
//
// The flagship loop (PLAN.md §7): the roster of everyone who checked into an event,
// for the 48 hours after it ends, with one button per person.
//
// # What the client does and does not decide
//
// **Every privacy rule here is the server's.** `is_discoverable = false` members are
// already absent from the response, blocks in either direction are already omitted,
// banned and rejected accounts are already gone, and the caller is already excluded
// from their own roster. The client renders what it is given and adds no filtering
// of its own — a second, client-side notion of who belongs on a roster is how the
// two drift apart, and the drift always favours showing someone who asked not to be
// shown.
//
// The one thing the client owns is the BUTTON STATE, and even that comes from the
// server's `requestState` so a member cannot send a second request to someone who
// already has one pending.

struct FriendingWindowView: View {
    let lumaEventId: String
    let eventName: String?

    @State private var attendees: [EventAttendeeDTO] = []
    @State private var isLoading = true
    @State private var isClosed = false
    @State private var pending: Set<UUID> = []
    @State private var sent: Set<UUID> = []
    @State private var errorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: Theme.Spacing.md)]

    var body: some View {
        ScrollView {
            if isLoading {
                ProgressView().padding(.top, Theme.Spacing.xxl)
            } else if isClosed {
                closedState
            } else if attendees.isEmpty {
                EmptyStateView(
                    icon: "person.2.slash",
                    title: "Nobody else to show",
                    message: "Either you're the first one here, or the others have chosen not to appear on attendee lists."
                )
            } else {
                LazyVGrid(columns: columns, spacing: Theme.Spacing.md) {
                    ForEach(attendees) { attendee in
                        AttendeeCard(
                            attendee: attendee,
                            isSending: pending.contains(attendee.userId),
                            hasSent: sent.contains(attendee.userId),
                            onAdd: { Task { await add(attendee) } }
                        )
                    }
                }
                .padding()
            }

            if let errorMessage {
                FormErrorText(message: errorMessage).padding(.horizontal)
            }
        }
        .navigationTitle(eventName ?? "Who was there")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    /// One state for all three of the server's refusals — no such event, window not
    /// open, you weren't there. Telling them apart would make this route an oracle
    /// for "did this event happen" and "who was at it", which is exactly what the
    /// disappearing roster exists to prevent.
    private var closedState: some View {
        EmptyStateView(
            icon: "clock.badge.xmark",
            title: "This window has closed",
            message: "Attendee lists are only up for 48 hours after an event. You've still got everyone you added."
        )
    }

    private func load() async {
        do {
            attendees = try await EventsAPI.attendees(lumaEventId: lumaEventId)
            isClosed = false
        } catch let APIError.httpError(code, _) where code == 404 {
            isClosed = true
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }

    private func add(_ attendee: EventAttendeeDTO) async {
        pending.insert(attendee.userId)
        defer { pending.remove(attendee.userId) }
        do {
            // `source: "event"` is load-bearing: it stamps `context` and `event_id`
            // on the request, which is what makes the resulting friendship carry
            // `source = event` and record where the two of them met.
            _ = try await FriendsAPI.sendRequest(to: attendee.userId, source: .event, eventId: lumaEventId)
            sent.insert(attendee.userId)
        } catch {
            errorMessage = "Couldn't send that request. They may no longer be available."
        }
    }
}

// MARK: - Attendee card

private struct AttendeeCard: View {
    let attendee: EventAttendeeDTO
    let isSending: Bool
    let hasSent: Bool
    let onAdd: () -> Void

    var body: some View {
        FWBCard(padding: Theme.Spacing.md) {
            VStack(spacing: Theme.Spacing.sm) {
                AvatarView(name: attendee.displayName, url: attendee.avatarUrl)
                    .frame(width: 56, height: 56)

                VStack(spacing: 2) {
                    Text(attendee.displayName)
                        .font(Theme.Typography.rowTitle)
                        .lineLimit(1)
                    if let bio = attendee.bio, !bio.isEmpty {
                        Text(bio)
                            .font(Theme.Typography.micro)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)

                action
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var action: some View {
        switch resolvedState {
        case .friends:
            Label("Friends", systemImage: "checkmark")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
        case .outgoing:
            Text("Requested")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
        case .incoming:
            // They already asked. Accepting from here would need the request id,
            // which the roster does not carry — so this points at the one screen
            // that has it rather than pretending the button can resolve it.
            NavigationLink {
                FriendsView()
            } label: {
                Text("They asked you")
                    .font(Theme.Typography.caption.weight(.semibold))
            }
        case .none:
            Button(action: onAdd) {
                if isSending {
                    ProgressView()
                } else {
                    Text("Add friend")
                }
            }
            .buttonStyle(FWBPrimaryButtonStyle())
            .disabled(isSending)
            .accessibilityIdentifier("events.add.\(attendee.userId.uuidString)")
        }
    }

    /// The optimistic local `hasSent` wins over the server's state, so the button
    /// settles the moment the request lands instead of waiting for a refetch.
    private var resolvedState: EventAttendeeDTO.RequestState {
        hasSent ? .outgoing : attendee.state
    }
}
