import SwiftUI

// MARK: - Admin controls for an announcement
//
// Every admin action on an announcement is defined ONCE, here, and rendered by
// three surfaces: the feed card's kebab, the feed card's long press, and the
// detail screen's kebab. That is the point of the file — a kebab and a context
// menu that are built by hand in two places drift within a release, and the
// drift is invisible until an admin can publish by long-pressing but not by
// tapping.
//
// The actions themselves are closures rather than API calls, because the three
// surfaces need different things to happen afterwards: the feed reloads a page,
// the detail screen updates one row and sometimes pops itself. `AnnouncementActions`
// holds the shared network half; the callers supply the "and then" .

// MARK: Menu

/// What a surface can do with an announcement. Every field is required, so a new
/// action cannot be silently omitted by one caller.
@MainActor
struct AnnouncementMenuHandlers {
    var edit: () -> Void
    var publish: () -> Void
    var unpublish: () -> Void
    var pin: () -> Void
    var unpin: () -> Void
    var scheduleUnpin: () -> Void
    var confirmDelete: () -> Void
}

/// THE menu. Rendered inside `Menu { }` for the kebab and inside `.contextMenu { }`
/// for the long press, so the two cannot disagree.
struct AnnouncementMenuItems: View {
    let announcement: Announcement
    let handlers: AnnouncementMenuHandlers

    var body: some View {
        // Publish first: it is the one action with an audience, and on a draft it
        // is the only one anybody opened this menu for.
        if announcement.isDraft {
            Button {
                handlers.publish()
            } label: {
                Label("Publish", systemImage: "paperplane")
            }
        } else {
            Button {
                handlers.unpublish()
            } label: {
                Label("Move to draft", systemImage: "tray.and.arrow.down")
            }
        }

        Button {
            handlers.edit()
        } label: {
            Label("Edit", systemImage: "pencil")
        }

        Section {
            if announcement.pinned {
                Button {
                    handlers.unpin()
                } label: {
                    Label("Unpin", systemImage: "pin.slash")
                }
                Button {
                    handlers.scheduleUnpin()
                } label: {
                    // The ellipsis is the platform's promise that a picker
                    // follows rather than the pin vanishing on tap.
                    Label(announcement.pinnedUntil == nil ? "Unpin on…" : "Change unpin date…",
                          systemImage: "calendar.badge.clock")
                }
            } else {
                Button {
                    handlers.pin()
                } label: {
                    Label("Pin to top", systemImage: "pin")
                }
            }
        }

        Section {
            ShareLink(item: announcement.shareText) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }

        Section {
            // `.destructive` earns its colour: this is the only item here that
            // cannot be undone from the app. It still routes through a
            // confirmation — the role styles it, it does not guard it.
            Button(role: .destructive) {
                handlers.confirmDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

/// The kebab itself. A `Menu` rather than a `Button`, so it never participates in
/// the row's navigation tap.
struct AnnouncementKebabMenu: View {
    let announcement: Announcement
    let handlers: AnnouncementMenuHandlers

    var body: some View {
        Menu {
            AnnouncementMenuItems(announcement: announcement, handlers: handlers)
        } label: {
            Image(systemName: "ellipsis")
                .font(Theme.Typography.rowTitle)
                .foregroundStyle(.secondary)
                // An SF Symbol contributes nothing to VoiceOver on its own, and
                // "ellipsis" is not what this does.
                .accessibilityLabel("Announcement actions")
                .accessibilityHint("Publish, edit, pin, share or delete")
                // A glyph is a ~17pt target; the tap area has to be a control's.
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .menuOrder(.fixed)
        .accessibilityIdentifier("announcement.kebab")
    }
}

// MARK: - Shared network half

/// The admin write calls, in one place, so the feed and the detail screen cannot
/// report different things for the same action.
///
/// Every method hands the updated row back, because the two callers disagree
/// about what follows: the feed reloads a page (its admin list is the only feed
/// carrying drafts), while the detail screen takes the returned row directly —
/// refetching there would 404 the moment an admin moved something back to draft,
/// since the member detail route only serves published announcements.
@MainActor
struct AnnouncementActions {
    let toasts: ToastCenter

    func publish(_ announcement: Announcement, onDone: @escaping (Announcement?) -> Void) {
        Task {
            do {
                let result = try await APIClient.shared.publishAnnouncement(id: announcement.id)
                // Report what the push actually did rather than implying
                // delivery. Zero recipients is a normal outcome — nobody opted
                // in, APNs unconfigured, everyone toggled it off — and an admin
                // told only "published" has been misled.
                if result.pushSkippedAlreadySent == true {
                    toasts.success("Published — members were already notified")
                } else if let delivered = result.pushDelivered {
                    toasts.success("Published — notified \(delivered) device\(delivered == 1 ? "" : "s")")
                } else {
                    toasts.success("Published")
                }
                onDone(result.announcement)
            } catch {
                toasts.error(error.fwbMessage)
            }
        }
    }

    func unpublish(_ announcement: Announcement, onDone: @escaping (Announcement?) -> Void) {
        Task {
            do {
                let updated = try await APIClient.shared.unpublishAnnouncement(id: announcement.id)
                toasts.success("Moved back to draft")
                onDone(updated)
            } catch {
                toasts.error(error.fwbMessage)
            }
        }
    }

    /// Pin, unpin, and schedule are one call, because on the server they are one
    /// PATCH and keeping them one here is what stops the client inventing a state
    /// the server does not have (a lapse date on an unpinned row, say).
    func setPin(
        _ announcement: Announcement,
        pinned: Bool,
        until: Date? = nil,
        clearSchedule: Bool = false,
        onDone: @escaping (Announcement?) -> Void
    ) {
        Task {
            do {
                let updated = try await APIClient.shared.updateAnnouncement(
                    id: announcement.id,
                    UpdateAnnouncementRequest(
                        isPinned: pinned,
                        pinnedUntil: until,
                        clearPinnedUntil: clearSchedule ? true : nil))
                if !pinned {
                    toasts.success("Unpinned")
                } else if let until {
                    toasts.success("Pinned until \(Self.pinDateText(until))")
                } else if clearSchedule {
                    toasts.success("Pinned — no end date")
                } else {
                    toasts.success("Pinned to top")
                }
                onDone(updated)
            } catch {
                toasts.error(error.fwbMessage)
            }
        }
    }

    func delete(_ announcement: Announcement, onDone: @escaping () -> Void) {
        Task {
            do {
                try await APIClient.shared.deleteAnnouncement(id: announcement.id)
                toasts.success("Deleted")
                onDone()
            } catch {
                toasts.error(error.fwbMessage)
            }
        }
    }

    /// "Aug 15" — the form the pin badge and the toasts both use, so an admin
    /// reads the same date back that they scheduled.
    ///
    /// `nonisolated` because `Announcement` is too: the model formats this for its
    /// own badge, and a pure date format has no actor to be on.
    nonisolated static func pinDateText(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }
}

// MARK: - Unpin-on-date sheet

/// Schedules the automatic unpin.
///
/// A WRITING sheet, so it carries Cancel and a primary verb rather than the
/// house `DismissableSheet`'s Done — "Done" on a screen that has changed nothing
/// yet is a lie about what the button will do.
struct UnpinDateSheet: View {
    let announcement: Announcement
    /// `nil` means "remove the schedule and stay pinned".
    var onSchedule: (Date?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var date: Date

    /// Bounds: never in the past (a pin that expires before it is set is just an
    /// unpin, and the menu already has one), and never more than a year out (a
    /// mistyped year is indistinguishable from the permanent pin that having no
    /// schedule at all already expresses). The server enforces the upper bound
    /// too — this is the courtesy, not the guard.
    private let now = Date()
    private var range: ClosedRange<Date> {
        now...Calendar.current.date(byAdding: .year, value: 1, to: now)!
    }

    init(announcement: Announcement, onSchedule: @escaping (Date?) -> Void) {
        self.announcement = announcement
        self.onSchedule = onSchedule
        // Default a week out: long enough to be worth scheduling, short enough
        // that an admin who taps straight through has not pinned something for a
        // season by accident.
        let existing = announcement.pinnedUntil
        let fallback = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
        _date = State(initialValue: max(existing ?? fallback, Date()))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(
                        "Unpin on",
                        selection: $date,
                        in: range,
                        displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.compact)
                    .accessibilityIdentifier("announcement.unpinDate")
                } footer: {
                    Text("“\(announcement.displayTitle)” stays at the top of the feed until then, and drops back into the timeline on its own. Nobody is notified.")
                }

                if announcement.pinnedUntil != nil {
                    Section {
                        Button("Remove unpin date", role: .destructive) {
                            onSchedule(nil)
                            dismiss()
                        }
                    } footer: {
                        Text("Keeps it pinned until you unpin it by hand.")
                    }
                }
            }
            .navigationTitle("Unpin on a date")
            .navigationBarTitleDisplayMode(.inline)
            .fwbAppThemeSurface()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Schedule") {
                        onSchedule(date)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}
