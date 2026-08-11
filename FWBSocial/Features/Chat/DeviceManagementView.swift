import SwiftUI

// MARK: - Devices
//
// PLAN.md §5.4's "device management screen (list, approve pending, revoke, safety
// numbers, and a 'set up a new phone' flow that walks approval BEFORE the old device
// is wiped)".
//
// # The model this screen has to teach
//
// Device #1 self-approves (§4.3.3(A)): `register` computes
// `isRoot = (activeApprovedCount == 0)`, so a brand-new account's first registration
// becomes the trust root with no bootstrap ceremony. Every later device registers
// `pending` and needs approval from an already-approved one — which is also the
// recovery path, because a member who lost every approved device re-registers and
// self-promotes a fresh root, keeping the account.
//
// What they lose in that case is history, and this screen is where that is said out
// loud rather than discovered in a support ticket.

struct DeviceManagementView: View {
    @State private var chat = ChatService.shared
    @State private var handoff = HistoryHandoffService.shared
    @State private var errorMessage: String?
    @State private var busyDeviceId: UUID?
    @State private var revokeTarget: ChatDeviceDTO?

    var body: some View {
        Form {
            if !chat.pendingDevices.isEmpty {
                Section {
                    ForEach(chat.pendingDevices) { device in
                        pendingRow(device)
                    }
                } header: {
                    Text("Waiting for approval")
                } footer: {
                    Text("Only approve a device you're holding. Approving one gives it your message history.")
                }
            }

            if let transfer = handoff.outgoing, !transfer.isTerminal {
                Section {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        ProgressView(value: transfer.fraction)
                        Text("Handing over history — \(transfer.deliveredMessages) of \(transfer.totalMessages) messages")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                } header: {
                    Text("Transfer in progress")
                } footer: {
                    Text("Keep both devices on and this app open. If it's interrupted it picks up where it left off.")
                }
            }

            if let incoming = handoff.incoming, !incoming.isTerminal {
                Section {
                    ProgressView(value: incoming.fraction)
                    Text("Receiving history — \(incoming.deliveredMessages) of \(incoming.totalMessages) messages")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Receiving history")
                }
            }

            Section {
                ForEach(chat.myDevices.filter(\.isApproved)) { device in
                    deviceRow(device)
                }
            } header: {
                Text("Your devices")
            } footer: {
                Text("Each device has its own encryption keys. Revoking one stops it receiving anything new.")
            }

            Section {
                NavigationLink {
                    NewPhoneGuideView()
                } label: {
                    Label("Setting up a new phone", systemImage: "iphone.gen3.badge.plus")
                }
                .accessibilityIdentifier("devices.newPhone")
            }

            if let errorMessage {
                Section { FormErrorText(message: errorMessage) }
            }
        }
        .navigationTitle("Devices")
        .navigationBarTitleDisplayMode(.inline)
        .task { await chat.refreshMyDevices() }
        .refreshable { await chat.refreshMyDevices() }
        .confirmationDialog(
            "Revoke this device?",
            isPresented: .constant(revokeTarget != nil),
            titleVisibility: .visible,
            presenting: revokeTarget
        ) { device in
            Button("Revoke", role: .destructive) {
                Task {
                    do { try await chat.revokeDevice(device) } catch { errorMessage = error.localizedDescription }
                    revokeTarget = nil
                }
            }
            Button("Cancel", role: .cancel) { revokeTarget = nil }
        } message: { _ in
            Text("It stops receiving new messages immediately, and its copy of every group key is deleted. Messages already on it stay on it.")
        }
    }

    private func pendingRow(_ device: ChatDeviceDTO) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.deviceName).font(Theme.Typography.rowTitle)
                    Text(device.platform.uppercased())
                        .font(Theme.Typography.micro)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if busyDeviceId == device.id {
                    ProgressView()
                }
            }

            if !device.bindingVerified {
                // The server tells us whether the classical↔PQ binding actually
                // verified. Surfaced rather than swallowed: an unverifiable device is
                // not proof of an attack, but it is not something to approve blind.
                Label("This device's keys couldn't be fully verified.", systemImage: "exclamationmark.triangle")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.caution)
            }

            HStack(spacing: Theme.Spacing.md) {
                Button("Approve") {
                    Task {
                        busyDeviceId = device.id
                        defer { busyDeviceId = nil }
                        do { try await chat.approveDevice(device) } catch {
                            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        }
                    }
                }
                .buttonStyle(FWBPrimaryButtonStyle())
                .accessibilityIdentifier("devices.approve.\(device.id.uuidString)")

                Button("Reject", role: .destructive) { revokeTarget = device }
                    .buttonStyle(FWBSecondaryButtonStyle())
            }
            .disabled(busyDeviceId != nil)
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    private func deviceRow(_ device: ChatDeviceDTO) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: device.platform == "ios" ? "iphone" : "desktopcomputer")
                .foregroundStyle(Theme.Colors.brand)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text(device.deviceName).font(Theme.Typography.rowTitle)
                    if device.id == chat.thisDevice?.id {
                        StatusBadge("This device")
                    }
                }
                if let lastActive = device.lastActiveAt {
                    Text("Last used \(lastActive, format: .relative(presentation: .named))")
                        .font(Theme.Typography.micro)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if device.id != chat.thisDevice?.id {
                Button("Revoke", role: .destructive) { revokeTarget = device }
                    .font(Theme.Typography.caption)
            }
        }
    }
}

// MARK: - New-phone guide
//
// PLAN.md R4: `ThisDeviceOnly` keys do not migrate via Quick Start, iCloud restore or
// an encrypted backup, and members will not expect that. PLAN-ADDENDUM A2 narrows
// what is actually lost — approving from a live old device now hands over history —
// so this screen's job is to make sure the approval happens BEFORE the old phone is
// wiped or traded in.

struct NewPhoneGuideView: View {
    var body: some View {
        Form {
            Section {
                Text("Your chat keys live only on this phone. They're deliberately excluded from iCloud, from encrypted backups, and from Quick Start — which is what stops anyone restoring a backup and reading your messages.")
                    .font(Theme.Typography.body)
            } header: {
                Text("Why a new phone starts empty")
            }

            Section {
                step(1, "Set up the new phone and sign in to fwb social on it.")
                step(2, "It'll appear here, on this phone, waiting for approval.")
                step(3, "Approve it here. Your history transfers across — keep both phones on until it finishes.")
                step(4, "Only then wipe or trade in this phone.")
            } header: {
                Text("The order matters")
            } footer: {
                Text("If you wipe this phone first, the new one still works — you'll just start with an empty history, and there's no way to recover it. Not by us, not by anyone.")
            }

            Section {
                Text("If you lose every device, you can sign in again and set up a fresh one. Your account, friends and groups all come back. Your old messages don't.")
                    .font(Theme.Typography.preview)
                    .foregroundStyle(.secondary)
            } header: {
                Text("If you lose everything")
            }
        }
        .navigationTitle("New phone")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Text("\(number)")
                .font(Theme.Typography.badge)
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Theme.Colors.brand, in: Circle())
            Text(text).font(Theme.Typography.body)
        }
        .padding(.vertical, 2)
    }
}
