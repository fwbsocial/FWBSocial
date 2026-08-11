import SwiftUI
import UIKit

/// A grid of app-icon variants — "Default" (the primary `FWBSocial.icon`, which
/// follows the Home Screen's icon appearance) and "Dark" (`FWBSocialDark.icon`,
/// forced dark). Both cells show the icon's REAL composed render, extracted from
/// the compiled asset catalog — see `AppearanceService.IconPreference.previewImage`.
struct AppIconPicker: View {
    @State private var appearance = AppearanceService.shared
    @State private var showError = false

    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 16)]

    var body: some View {
        Group {
            if UIApplication.shared.supportsAlternateIcons {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(AppearanceService.IconPreference.allCases) { option in
                        cell(option)
                    }
                }
                .padding(.vertical, 4)
            } else {
                // Honest, and specific. The old copy showed a live-looking grid
                // whose taps quietly failed.
                Text("Alternate icons aren’t available on this device.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { appearance.reconcileIconPreference() }
        .alert("Couldn't change app icon", isPresented: $showError, presenting: appearance.lastIconError) { _ in
            Button("OK", role: .cancel) {}
        } message: { Text($0) }
    }

    private func cell(_ option: AppearanceService.IconPreference) -> some View {
        let isActive = appearance.iconPreference == option
        return Button {
            Task {
                do { try await appearance.setIconPreference(option) }
                catch { showError = true }
            }
        } label: {
            VStack(spacing: 6) {
                Image(option.previewImage)
                    .resizable()
                    .aspectRatio(1, contentMode: .fit)
                    .frame(width: 64, height: 64)
                    .fwbCorner(14)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(isActive ? Theme.Colors.brand : Theme.Colors.hairline,
                                          lineWidth: isActive ? 3 : 1))
                    .overlay(alignment: .bottomTrailing) {
                        if isActive {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(Theme.Colors.onBrand, Theme.Colors.brand)
                                .offset(x: 4, y: 4)
                        }
                    }
                Text(option.label)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(isActive ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(option.label) icon")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview {
    AppIconPicker().padding()
}
