import SwiftUI

/// A grid of app-icon variants. Currently a single "Default" cell — see
/// `AppearanceService.IconPreference`'s doc comment for why. Structurally
/// ready for a future alternate icon without changing this view.
struct AppIconPicker: View {
    @State private var appearance = AppearanceService.shared
    @State private var showError = false

    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 16)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(AppearanceService.IconPreference.allCases) { option in
                cell(option)
            }
        }
        .padding(.vertical, 4)
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
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.Colors.brandGradient)
                    .overlay(
                        Text("FWB")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(.white))
                    .frame(width: 64, height: 64)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(isActive ? Theme.Colors.brand : Theme.Colors.hairline, lineWidth: isActive ? 3 : 1))
                    .overlay(alignment: .bottomTrailing) {
                        if isActive {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(.white, Theme.Colors.brand)
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
