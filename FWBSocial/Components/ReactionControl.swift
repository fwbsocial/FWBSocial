import SwiftUI
import UIKit

// MARK: - Reaction control
//
// Adapted from MyStickyApp's `ReactionLikeControl`
// (Core/Extensions/ComicCardViews.swift, 501–636 — research report 03 rates it
// "cleanly reusable"), reskinned off `Theme` and repointed at the forum's
// reaction routes. The interaction is the same one that already works there:
//
//   tap        → toggle the default reaction (or clear the current one)
//   long-press → fan out all five, tap one to pick it
//
// **Optimistic, and it has to be.** The server's reaction routes return `.ok` /
// `.noContent` with **no body** — there is no echoed count or reaction to adopt,
// so the only way to render a response to the tap is to apply it locally and let
// the next fetch reconcile. On failure the previous state is restored exactly,
// which is why `previous` captures both fields rather than just the token.
//
// The fan is `@State`, not `@GestureState`: the house rule bans `@State` for
// *hold-to-act* latches, but this is not hold-to-act — holding opens a picker
// that stays open and commits on a separate tap. Nothing fires on release.

struct ReactionControl: View {

    /// The caller's current reaction token, or nil.
    let myReaction: String?
    /// The total across everyone.
    let count: Int
    /// Whether the member may react at all — `canReact` is folded into the
    /// channel's resolved access server-side, so a read-only surface passes false
    /// and gets a static tally instead of a control.
    var canReact: Bool = true

    /// Applies a reaction, or clears it when nil. Throwing restores the previous
    /// visual state.
    let apply: (FWBReaction?) async throws -> Void

    @Environment(ToastCenter.self) private var toasts

    @State private var isExpanded = false
    @State private var optimistic: String??
    @State private var optimisticDelta = 0

    /// The token being rendered: the optimistic override if there is one (note
    /// the double Optional — an override *to nil* is meaningful and distinct from
    /// "no override"), otherwise the server's.
    private var current: FWBReaction? {
        if case let .some(value) = optimistic { return FWBReaction.from(value) }
        return FWBReaction.from(myReaction)
    }

    private var displayCount: Int { max(0, count + optimisticDelta) }

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if isExpanded {
                fan
            } else {
                summary
            }
        }
        .animation(Theme.Motion.bubble, value: isExpanded)
        .animation(Theme.Motion.chrome, value: current)
        // **Drop the optimistic override as soon as the server's own numbers
        // arrive.** Without this the local delta is added on top of a count that
        // already includes it, and a single tap renders as 2 — observed in the
        // Phase 4 smoke, where reacting once and then posting a comment (which
        // refetches the post) double-counted.
        //
        // The view keeps its identity across a refetch, so `@State` survives the
        // new inputs; only an explicit reset clears it. Any change to either
        // input means the caller re-read the post, and the re-read is by
        // definition more authoritative than a guess made before it.
        .onChange(of: count) { _, _ in clearOptimistic() }
        .onChange(of: myReaction) { _, _ in clearOptimistic() }
    }

    private func clearOptimistic() {
        optimistic = nil
        optimisticDelta = 0
    }

    // MARK: - Collapsed

    private var summary: some View {
        Button {
            guard canReact else { return }
            // A second tap on the same reaction clears it; otherwise the default.
            commit(current == nil ? .like : nil)
        } label: {
            HStack(spacing: 6) {
                if let current {
                    Text(current.emoji).font(.system(size: 15))
                } else {
                    Image(systemName: "hand.thumbsup")
                        .font(.system(size: 14, weight: .medium))
                }
                if displayCount > 0 {
                    Text("\(displayCount)")
                        .font(Theme.Typography.caption.weight(.medium))
                        .contentTransition(.numericText())
                }
            }
            .foregroundStyle(current == nil ? Color.secondary : Theme.Colors.brand)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                current == nil ? Theme.Colors.field : Theme.Colors.brandSoft,
                in: Capsule())
            .fwbThemedContainer()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("reaction.toggle")
        .disabled(!canReact)
        .accessibilityLabel(current.map { "Reacted \($0.label)" } ?? "React")
        // The count is a `value`, not part of the label: VoiceOver re-announces a
        // changed value on its own, and the count moves optimistically on every
        // tap. Folded into the label it forced a re-read of the whole sentence.
        .accessibilityValue("\(displayCount) reactions")
        .accessibilityAddTraits(current == nil ? [] : .isSelected)
        // **The five reactions were unreachable without sight.** The fan opened
        // only on a long press, and VoiceOver does not synthesise one — so a
        // VoiceOver member could apply `like` and nothing else, ever. Custom
        // actions put all five (plus the undo) on the rotor, which is the
        // documented equivalent of a press-and-hold menu.
        .accessibilityActions {
            ForEach(FWBReaction.allCases) { reaction in
                Button(reaction.label) {
                    guard canReact else { return }
                    commit(current == reaction ? nil : reaction)
                }
            }
            if current != nil {
                Button("Remove my reaction") {
                    guard canReact else { return }
                    commit(nil)
                }
            }
        }
        .onLongPressGesture(minimumDuration: 0.28) {
            guard canReact else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            isExpanded = true
        }
    }

    // MARK: - Expanded fan

    private var fan: some View {
        HStack(spacing: Theme.Spacing.xs) {
            ForEach(FWBReaction.allCases) { reaction in
                Button {
                    // Picking the one already selected clears it — the fan should
                    // be able to undo, not only set.
                    commit(current == reaction ? nil : reaction)
                } label: {
                    Text(reaction.emoji)
                        .font(.system(size: 22))
                        .padding(6)
                        .background(
                            current == reaction ? Theme.Colors.brandSoft : Color.clear,
                            in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(reaction.label)
                // The chosen reaction is drawn with a brand-soft disc behind it and
                // nothing else, so without this trait all five announced
                // identically and there was no way to tell which one was yours.
                .accessibilityAddTraits(current == reaction ? .isSelected : [])
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.Colors.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.Colors.hairline, lineWidth: 1))
        .fwbThemedContainer()
        .transition(.scale(scale: 0.85, anchor: .leading).combined(with: .opacity))
        // Tapping anywhere else closes the fan without committing.
        .onTapGesture { }
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { isExpanded = false }
                // An invisible full-bleed tap target is a real accessibility
                // element to VoiceOver — an unlabelled one sitting over the
                // content. It exists for the mouse-analogue "tap outside to
                // dismiss" only, so it is hidden from the tree entirely.
                .accessibilityHidden(true))
    }

    // MARK: - Commit

    private func commit(_ reaction: FWBReaction?) {
        let previousToken = current?.rawValue
        let previousOverride = optimistic
        let previousDelta = optimisticDelta

        // The count moves only when reacting changes from "none" to "some" or
        // back — a swap is still one reaction from one person, which is exactly
        // what the server does with its swap-in-place row.
        let had = current != nil
        let willHave = reaction != nil
        optimistic = .some(reaction?.rawValue)
        optimisticDelta += (had == willHave) ? 0 : (willHave ? 1 : -1)
        isExpanded = false

        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        Task {
            do {
                try await apply(reaction)
            } catch {
                guard !isCancellationError(error) else { return }
                optimistic = previousOverride
                optimisticDelta = previousDelta
                // The server's own sentence, not a generic one: a reaction on a
                // locked thread and a reaction while signed out fail differently,
                // and only the server knows which happened.
                toasts.error(error.fwbMessage)
                _ = previousToken
            }
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 20) {
        ReactionControl(myReaction: nil, count: 0) { _ in }
        ReactionControl(myReaction: "heart", count: 12) { _ in }
        ReactionControl(myReaction: nil, count: 3, canReact: false) { _ in }
    }
    .padding()
    .environment(ToastCenter())
}
