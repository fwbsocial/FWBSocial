import SwiftUI

// MARK: - Add by friend code, in one place
//
// The friend-code entry flow was written inline in `FriendsView` — a Form section,
// two `@State`s and two async methods. Owner directive 2026-08-11 puts the same
// flow behind the Events tab's contextual action and behind the event roster's,
// which is three copies of a lookup whose most load-bearing property is that its
// failures are INDISTINGUISHABLE from each other.
//
// So it moves here once, and the three screens present it.
//
// **Every refusal returns one sentence.** The server collapses "no such code",
// "that's you" and "one of you blocked the other" into a single 404 on purpose,
// and the client must not undo that by reporting the error it happened to get.
// A code is eight characters; anything that distinguishes the failures turns this
// route into an oracle worth enumerating.

/// The entry field, the lookup result and the send button, as Form sections.
///
/// A `Section`-producing view rather than a whole screen, so `FriendsView` can keep
/// it as the first block of its own Form while the two event surfaces present it
/// alone in `AddFriendSheet`.
struct AddFriendByCodeSection: View {
    /// Called after a request is actually sent, so a host that shows a friends list
    /// can refetch it.
    var onSent: (() -> Void)?

    @State private var codeDraft = ""
    @State private var lookupResult: FriendCodeLookupResponse?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?

    /// The server trims and uppercases, then requires exactly eight characters.
    private var normalizedCode: String {
        codeDraft.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private var canLookUp: Bool { normalizedCode.count == 8 && !isWorking }

    var body: some View {
        Section {
            HStack {
                TextField("ABCD1234", text: $codeDraft)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .monospaced()
                    .submitLabel(.search)
                    .onSubmit { if canLookUp { Task { await lookup() } } }
                    .accessibilityIdentifier("friends.code")
                    .accessibilityLabel("Friend code")
                Button("Find") { Task { await lookup() } }
                    .disabled(!canLookUp)
                    .accessibilityIdentifier("friends.find")
                    .accessibilityLabel("Find this member")
            }

            if let lookupResult {
                HStack(spacing: Theme.Spacing.md) {
                    AvatarView(name: lookupResult.displayName, url: lookupResult.avatarUrl)
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(lookupResult.displayName).font(Theme.Typography.rowTitle)
                        if let username = lookupResult.username {
                            Text("@\(username)")
                                .font(Theme.Typography.micro)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Add") { Task { await sendRequest(to: lookupResult.userId) } }
                        .buttonStyle(FWBPrimaryButtonStyle())
                        .disabled(isWorking)
                        .accessibilityIdentifier("friends.add")
                        .accessibilityLabel("Send \(lookupResult.displayName) a friend request")
                }
                // Every row's Add button is otherwise the same word, so the whole
                // result reads as one thing rather than as an avatar, a name and a
                // button VoiceOver has to be walked through separately.
                .accessibilityElement(children: .contain)
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            if let errorMessage {
                FormErrorText(message: errorMessage)
            }
        } header: {
            Text("Add by friend code")
        } footer: {
            Text("Your own code is on your profile. Codes are exact — there's no search, on purpose.")
        }
    }

    // MARK: Actions

    private func lookup() async {
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        statusMessage = nil
        lookupResult = nil
        do {
            lookupResult = try await FriendsAPI.lookup(code: normalizedCode)
        } catch {
            guard !isCancellationError(error) else { return }
            // One message for every refusal — see the note at the top of the file.
            errorMessage = "No member with that code."
        }
    }

    private func sendRequest(to userId: UUID) async {
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        do {
            _ = try await FriendsAPI.sendRequest(to: userId, source: .friendCode)
            statusMessage = "Request sent."
            lookupResult = nil
            codeDraft = ""
            fwbDismissKeyboard()
            onSent?()
        } catch {
            guard !isCancellationError(error) else { return }
            // The SEND is not the lookup: "you're already friends" and "they've
            // blocked you" are answers the member needs, and the code is already
            // known to them by this point, so there is no oracle left to protect.
            errorMessage = error.fwbMessage
        }
    }
}

// MARK: - Standalone sheet

/// The same flow as its own screen, for the Events tab and the event roster, where
/// there is no friends list to sit above.
///
/// Presented inside a `DismissableSheet`, which supplies the `NavigationStack`, the
/// theme surface and the Done button.
struct AddFriendSheet: View {
    var onSent: (() -> Void)?

    var body: some View {
        Form {
            AddFriendByCodeSection(onSent: onSent)

            Section {
                Text("You can also add the people you actually met: for 48 hours after an event, everyone who checked in shows up on its roster.")
                    .font(Theme.Typography.preview)
                    .foregroundStyle(.secondary)
            }
        }
        // Background layer, never a tap gesture on the Form itself — a gesture on
        // the Form eats every row's own tap (house gotcha).
        .fwbDismissKeyboardOnTap()
        .navigationTitle("Add friend")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("addFriend.sheet")
    }
}
