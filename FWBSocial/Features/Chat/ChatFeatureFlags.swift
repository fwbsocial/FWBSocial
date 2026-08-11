import Foundation

// MARK: - Chat scope switches
//
// OWNER SCOPE DIRECTIVE, 2026-08-10, and the owner's follow-up answer the same day.
//
// Phase 6 ships **chat basics** — 1:1 and group conversations, text, photos and a
// viewer, tap-back reactions, unread counts and the badge — plus the non-negotiable
// E2EE infrastructure: device registration and approval with TOFU pinning, key
// management, the NSE fetch-and-decrypt preview, A2's history handoff, and the
// offline outbox with idempotent retry.
//
// Five surfaces were held pending the owner's decision. **Four are now approved and
// on**: typing indicators, delivered/read receipt display, reply-quoting, and
// delete-for-everyone. Link previews stay out of v1.
//
// # Not flags — genuinely not ported
//
// Nudges, Reunion, mutual-glow, presence, polls, song dedications, Genmoji and Stash
// are OUT, not held. PLAN.md §8 puts them permanently out of scope and none of their
// code came across, entangled files included — where a kept file referenced them,
// the reference was stripped rather than carried behind a switch. There is nothing
// to flip.

nonisolated enum ChatFeatureFlags {

    /// The "Alex is typing…" row and the outbound typing frames. **Approved.**
    static let typingIndicators = true

    /// Delivered / read ticks on a sent bubble. **Approved.**
    ///
    /// Worth noting even now it is on: the counts were always flowing regardless.
    /// `UnreadCountService` derives the badge, the per-thread count and the push
    /// badge from the same recipient rows, so this switch only ever governed the
    /// display.
    static let readReceiptDisplay = true

    /// Rich previews for URLs in a message body. **OUT of v1** — the owner's answer
    /// held this one back while approving the other four.
    ///
    /// Nothing is ported for it. Under E2EE it is also more than it looks: the
    /// preview has to be fetched by a client (the server cannot read the URL to
    /// unfurl it), which means either the sender leaks its reading to the target
    /// host at compose time, or every recipient does at render time. That is a
    /// product decision, not a missing view.
    static let linkPreviews = false

    /// Swipe-to-reply and the quoted-message preview in a bubble. **Approved.**
    static let replyQuoting = true

    /// Deleting a sent message for everyone. **Approved.**
    ///
    /// `DELETE /api/chat/messages/:id` is a HARD delete server-side, cascading the
    /// recipient and reaction rows, so the message stops being served to anyone. It
    /// still cannot reach a copy that already decrypted on someone else's phone —
    /// §4.7 is explicit — and the confirmation copy says exactly that rather than
    /// implying a reach the crypto does not have.
    static let deleteForEveryone = true

    /// Editing a sent message. **Blocked on the server, not on a decision.**
    ///
    /// The owner approved "edit + delete-for-everyone" together, and delete ships.
    /// Edit cannot: fwb-server exposes no route for it. `routes.swift`'s chat group
    /// has `PUT …/messages/:id/reactions` and `DELETE …/messages/:id` and nothing
    /// else on a message; `fwb_chat_messages.edited_at` exists as a column and
    /// `ChatMessageResponse` carries it, but no handler ever writes it.
    ///
    /// The client half is ready for it — the bubble already renders an "edited"
    /// marker off `editedAt` — so this becomes a one-screen change the day a
    /// `PATCH /api/chat/messages/:id` exists that takes fresh ciphertext and a fresh
    /// per-recipient wrapped-key set. Flagged to the server side rather than faked
    /// here: a client-only "edit" that deleted and re-sent would break the reply
    /// graph, change the message id, and re-notify everyone.
    static let editMessage = false
}
