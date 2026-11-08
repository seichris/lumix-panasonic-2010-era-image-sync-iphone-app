import SwiftUI
#if os(iOS)
import UIKit
#endif

enum AppIconChoice: String, CaseIterable, Identifiable {
    case primary
    case lens = "AppIcon"
    case blackCamera = "BlackCamera"
    case gm1sOrange = "GM1SOrange"
    case gm1Silver = "GM1Silver"
    case gm1AllBlack = "GM1AllBlack"
    case gx85 = "GX85"
    case gx9 = "GX9"
    case g85 = "G85"
    case fz80 = "FZ80"
    case fz300 = "FZ300"
    case fz1000 = "FZ1000"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .primary:
            "Blue Camera"
        case .lens:
            "Lens"
        case .blackCamera:
            "Black Camera"
        case .gm1sOrange:
            "GM1S Orange"
        case .gm1Silver:
            "GM1 Silver"
        case .gm1AllBlack:
            "GM1 All Black"
        case .gx85:
            "GX85"
        case .gx9:
            "GX9"
        case .g85:
            "G85 / G80"
        case .fz80:
            "FZ80 / FZ82"
        case .fz300:
            "FZ300"
        case .fz1000:
            "FZ1000"
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
        default:
            rawValue + "IconPreview"
        }
    }

    /// Lens and Black Camera were free before the custom icons purchase; someone already
    /// using one of them when it arrived keeps both. The camera model icons always need it.
    var wasFreeBefore: Bool {
        self == .lens || self == .blackCamera
    }

    /// The camera this icon shows, as `CameraCandidate.models` names it in the camera list.
    var cameraModels: String? {
        switch self {
        case .primary, .lens, .blackCamera: nil
        case .gm1sOrange: "Panasonic DMC-GM1S"
        case .gm1Silver, .gm1AllBlack: "Panasonic DMC-GM1"
        case .gx85: "Panasonic DMC-GX80 / GX85"
        case .gx9: "Panasonic DC-GX9"
        case .g85: "Panasonic DMC-G80 / G81 / G85"
        case .fz80: "Panasonic DC-FZ80 / FZ82"
        case .fz300: "Panasonic DMC-FZ300 / FZ330"
        case .fz1000: "Panasonic DMC-FZ1000"
        }
    }

    /// The icons that show a camera from the camera list, in picker order.
    static func icons(forCamera models: String) -> [AppIconChoice] {
        allCases.filter { $0.cameraModels == models }
    }

#if os(iOS)
    /// Makes this the Home Screen icon; iOS confirms the change with its own message.
    @MainActor
    func makeAppIcon() async throws {
        try await UIApplication.shared.setAlternateIconName(alternateIconName)
    }
#endif

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

            if !store.ownsPurchase {
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
                Text(store.ownsPurchase
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
                Text(store.isGrandfathered
                     ? "Lens and Black Camera stay free for you. The camera model icons are a one-time purchase that supports development."
                     : "Lens, Black Camera, and the camera model icons are a one-time purchase that supports development. Blue Camera is always free.")
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
