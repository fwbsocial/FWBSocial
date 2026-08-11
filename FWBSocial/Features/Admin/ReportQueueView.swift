import SwiftUI

// MARK: - Report queue (moderator + admin)
//
// Deliberately minimal. Plan §7 puts the full moderation UX in Phase 8; what
// ships here is the mechanism Guideline 1.2 actually requires — "act on reports
// within 24 hours" is only meetable if a moderator can see the queue and close
// items from the phone.
//
// The queue is **moderator tier**, not admin: plan §4.7 scopes moderators to
// "reports, content removal, warnings", with ban and settings reserved for
// admins. Ban is not offered here — it takes a required `disposition`
// (delete-all-content vs keep-tombstoned, commissioner decision 7) that deserves
// its own deliberate screen rather than a menu item next to "dismiss".
//
// Ordering is the server's: oldest first, because the SLA is about the oldest.

struct ReportQueueView: View {

    @Environment(ToastCenter.self) private var toasts
    @State private var auth = AuthService.shared

    @State private var queue: ReportQueueResponse?
    @State private var isLoading = false
    @State private var error: String?
    @State private var statusFilter: String?
    @State private var resolving: ReportResponse?

    private var items: [ReportResponse] { queue?.items ?? [] }

    var body: some View {
        List {
            if let queue {
                Section {
                    summary(queue)
                }
            }

            if let error {
                Section { FormErrorText(message: error) }
            }

            Section {
                Picker("Show", selection: $statusFilter) {
                    Text("Open").tag(String?.none)
                    Text("Actioned").tag(String?.some("actioned"))
                    Text("Dismissed").tag(String?.some("dismissed"))
                }
                .pickerStyle(.segmented)
                .onChange(of: statusFilter) { _, _ in
                    Task { await load() }
                }
            }

            if items.isEmpty && !isLoading {
                Section {
                    EmptyStateView(
                        icon: "checkmark.shield",
                        title: "Nothing waiting",
                        message: statusFilter == nil
                            ? "No open reports. That is the good outcome."
                            : "No reports with that status.")
                    .listRowBackground(Color.clear)
                }
            }

            ForEach(items) { report in
                ReportRow(report: report) {
                    resolving = report
                } assign: {
                    assign(report)
                }
            }

            if isLoading {
                Section {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            }
        }
        .navigationTitle("Reports")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $resolving) { report in
            ResolveReportSheet(report: report) { updated in
                apply(updated)
            }
        }
    }

    private func summary(_ queue: ReportQueueResponse) -> some View {
        HStack {
            stat("Open", value: "\(queue.openCount ?? 0)", color: Theme.Colors.brand)
            Divider()
            stat("Triaging", value: "\(queue.triagingCount ?? 0)", color: Theme.Colors.caution)
            Divider()
            // The number the SLA is actually about.
            stat("Oldest",
                 value: queue.oldestOpenAgeHours.map { "\(Int($0))h" } ?? "—",
                 color: (queue.slaBreachCount ?? 0) > 0 ? Theme.Colors.danger : .secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func stat(_ label: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(Theme.Typography.title)
                .foregroundStyle(color)
            Text(label)
                .font(Theme.Typography.micro)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func load() async {
        isLoading = true
        error = nil
        do {
            queue = try await APIClient.shared.reportQueue(status: statusFilter)
        } catch {
            guard !isCancellationError(error) else { isLoading = false; return }
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func assign(_ report: ReportResponse) {
        Task {
            do {
                let updated = try await APIClient.shared.assignReport(id: report.id, to: auth.user?.id)
                apply(updated)
                toasts.success("Assigned to you.")
            } catch {
                guard !isCancellationError(error) else { return }
                toasts.error(error.localizedDescription)
            }
        }
    }

    private func apply(_ updated: ReportResponse) {
        guard var current = queue else { return }
        var newItems = current.items
        if let idx = newItems.firstIndex(where: { $0.id == updated.id }) {
            // A resolved report leaves the default (open + triaging) view.
            if updated.isResolved && statusFilter == nil {
                newItems.remove(at: idx)
            } else {
                newItems[idx] = updated
            }
        }
        current = ReportQueueResponse(
            items: newItems,
            total: newItems.count,
            openCount: current.openCount,
            triagingCount: current.triagingCount,
            oldestOpenAgeHours: current.oldestOpenAgeHours,
            slaBreachCount: current.slaBreachCount)
        queue = current
        Task { await load() }
    }
}

// MARK: - Row

private struct ReportRow: View {
    let report: ReportResponse
    var resolve: () -> Void
    var assign: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.sm) {
                Text(report.reasonLabel)
                    .font(Theme.Typography.rowTitle)
                Spacer()
                if report.breaching {
                    StatusBadge("SLA \(report.ageLabel)", color: Theme.Colors.danger)
                } else {
                    Text(report.ageLabel)
                        .font(Theme.Typography.micro)
                        .foregroundStyle(.secondary)
                }
            }

            Text("On a \(report.targetNoun)"
                 + (report.targetAuthorDisplayName.map { " by \($0)" } ?? ""))
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)

            if let details = report.details, !details.isEmpty {
                Text(details)
                    .font(Theme.Typography.preview)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
            }

            HStack(spacing: Theme.Spacing.sm) {
                // A blocked-terms auto-flag has no human reporter; saying
                // "reported by system" stops a moderator hunting for one.
                Text(report.isSystemFlag
                     ? "Auto-flagged"
                     : "Reported by \(report.reporterDisplayName ?? "a member")")
                    .font(Theme.Typography.micro)
                    .foregroundStyle(.secondary)

                if report.hasEvidence == true {
                    Label("Snapshot", systemImage: "doc.text")
                        .font(Theme.Typography.micro)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if !report.isResolved {
                HStack(spacing: Theme.Spacing.md) {
                    if !report.isTriaging {
                        Button("Take", action: assign)
                            .font(Theme.Typography.caption)
                            .buttonStyle(.bordered)
                    }
                    Button("Resolve", action: resolve)
                        .font(Theme.Typography.caption)
                        .buttonStyle(.borderedProminent)
                    Spacer()
                }
            } else {
                Text("Resolved: \(ModerationOutcome(rawValue: report.resolution ?? "")?.label ?? report.status ?? "")")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.positive)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Resolve sheet

private struct ResolveReportSheet: View {
    let report: ReportResponse
    var onResolved: (ReportResponse) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts

    @State private var outcome: ModerationOutcome = .noAction
    @State private var note = ""
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Outcome") {
                    Picker("Outcome", selection: $outcome) {
                        ForEach(ModerationOutcome.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section {
                    TextField("Note for the audit log", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                } footer: {
                    // The moderation log is immutable server-side (§2.6, Q20).
                    Text("Recorded in the moderation log, which cannot be edited later.")
                }

                if outcome == .banned || outcome == .vettingRevoked {
                    Section {
                        Label(
                            outcome == .banned
                                ? "Banning is an admin action with a required content decision — do it from the member's profile, not here."
                                : "Revoking vetting removes forum and chat access until an admin restores it.",
                            systemImage: "exclamationmark.triangle")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.caution)
                    }
                }

                if let error {
                    Section { FormErrorText(message: error) }
                }
            }
            .fwbDismissKeyboardOnTap()
            .navigationTitle("Resolve")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(isSaving)
                }
            }
        }
    }

    private func save() {
        fwbDismissKeyboard()
        isSaving = true
        error = nil
        Task {
            do {
                let updated = try await APIClient.shared.resolveReport(
                    id: report.id, outcome: outcome, note: note)
                isSaving = false
                onResolved(updated)
                toasts.success("Report resolved.")
                dismiss()
            } catch {
                isSaving = false
                guard !isCancellationError(error) else { return }
                self.error = error.localizedDescription
            }
        }
    }
}
