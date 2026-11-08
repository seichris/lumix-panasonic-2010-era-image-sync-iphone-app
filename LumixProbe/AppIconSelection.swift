import SwiftUI
#if os(iOS)
import UIKit
#endif

enum AppIconChoice: String, CaseIterable, Identifiable {
    case primary
    case lens = "AppIcon"
    case blackCamera = "BlackCamera"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .primary:
            "Blue Camera"
        case .lens:
            "Lens"
        case .blackCamera:
            "Black Camera"
        }
    }

    var alternateIconName: String? {
        self == .primary ? nil : rawValue
    }

    var previewAssetName: String {
        switch self {
        case .primary:
            "BlueCameraIconPreview"
        case .lens:
            "DefaultIconPreview"
        case .blackCamera:
            "BlackCameraIconPreview"
        }
    }

    @MainActor
    static var current: AppIconChoice {
#if os(iOS)
        guard let iconName = UIApplication.shared.alternateIconName else {
            return .primary
        }
        return AppIconChoice(rawValue: iconName) ?? .primary
#else
        return .primary
#endif
    }
}

struct AppIconPickerView: View {
#if os(iOS)
    @ObservedObject var store: AppIconStore
#endif
    @State private var selectedIcon: AppIconChoice = .primary
    @State private var pendingIcon: AppIconChoice?
    @State private var errorMessage: String?

    var body: some View {
#if os(iOS)
        List {
            Section {
                Text("Choose how Retro LUMIX Sync appears on your Home Screen. Your selection can be changed again at any time.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !store.isUnlocked {
                unlockSection
            }

            Section {
                ForEach(AppIconChoice.allCases) { icon in
                    Button {
                        if store.isAvailable(icon) {
                            select(icon)
                        } else {
                            // A locked icon starts the purchase, then becomes the icon.
                            Task {
                                await store.purchase()
                                if store.isAvailable(icon) { select(icon) }
                            }
                        }
                    } label: {
                        HStack(spacing: 14) {
                            Image(icon.previewAssetName)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 58, height: 58)
                                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                                        .stroke(.quaternary, lineWidth: 0.5)
                                }

                            Text(icon.title)
                                .foregroundStyle(.primary)

                            Spacer()

                            if pendingIcon == icon {
                                ProgressView()
                            } else if icon == selectedIcon {
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.tint)
                            } else if !store.isAvailable(icon) {
                                Image(systemName: "lock.fill")
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(pendingIcon != nil || icon == selectedIcon || store.purchaseState == .purchasing)
                    .accessibilityIdentifier("app-icon-\(icon.rawValue)")
                    .accessibilityValue(iconAccessibilityValue(icon))
                }
            } header: {
                Text("App icon")
            } footer: {
                Text(store.ownsPurchase && !store.isGrandfathered
                     ? "Thank you for supporting Retro LUMIX Sync. iOS confirms each icon change with a system message."
                     : "iOS confirms each icon change with a system message.")
            }
        }
        .navigationTitle("App Icon")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            selectedIcon = AppIconChoice.current
        }
        .task { await store.refresh() }
        .alert("Couldn’t change app icon", isPresented: errorIsPresented) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Please try again.")
        }
        .alert("Purchase didn’t go through", isPresented: purchaseErrorIsPresented) {
            Button("OK") { store.dismissError() }
        } message: {
            if case let .failed(message) = store.purchaseState { Text(message) }
        }
#else
        ContentUnavailableView(
            "Blue Camera icon",
            systemImage: "app.fill",
            description: Text("Retro LUMIX Sync uses the Blue Camera logo on Mac. Alternate icon choices are available on iPhone.")
        )
        .navigationTitle("App Icon")
#endif
    }

#if os(iOS)
    /// Lens and Black Camera are a one-time purchase that supports development.
    private var unlockSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Custom app icons")
                    .font(.headline)
                Text("Lens and Black Camera are a one-time purchase that supports development. Blue Camera is always free.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)

            Button {
                Task { await store.purchase() }
            } label: {
                HStack {
                    Text(store.price.map { "Unlock for \($0)" } ?? "Unlock custom icons")
                    Spacer()
                    if store.purchaseState == .purchasing { ProgressView() }
                }
            }
            .disabled(store.price == nil || store.purchaseState == .purchasing || store.purchaseState == .restoring)
            .accessibilityIdentifier("unlock-custom-icons")

            Button {
                Task { await store.restore() }
            } label: {
                HStack {
                    Text("Restore purchase")
                    Spacer()
                    if store.purchaseState == .restoring { ProgressView() }
                }
            }
            .disabled(store.purchaseState == .purchasing || store.purchaseState == .restoring)
            .accessibilityIdentifier("restore-custom-icons")
        } footer: {
            if store.purchaseState == .pending {
                Text("Waiting for approval. The icons unlock when the purchase goes through.")
            } else if store.price == nil {
                Text("The App Store isn't offering the custom icons right now.")
            }
        }
    }

    private func iconAccessibilityValue(_ icon: AppIconChoice) -> String {
        if icon == selectedIcon { return "Selected" }
        return store.isAvailable(icon) ? "Not selected" : "Locked"
    }

    private var purchaseErrorIsPresented: Binding<Bool> {
        Binding(
            get: { if case .failed = store.purchaseState { return true } else { return false } },
            set: { isPresented in if !isPresented { store.dismissError() } }
        )
    }
#endif

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { isPresented in
                if !isPresented { errorMessage = nil }
            }
        )
    }

    private func select(_ icon: AppIconChoice) {
#if os(iOS)
        guard icon != selectedIcon else { return }
        pendingIcon = icon

        UIApplication.shared.setAlternateIconName(icon.alternateIconName) { error in
            Task { @MainActor in
                if let error {
                    errorMessage = error.localizedDescription
                } else {
                    selectedIcon = AppIconChoice.current
                }
                pendingIcon = nil
            }
        }
#else
        errorMessage = "App icon choices are only available on iPhone."
#endif
    }
}
