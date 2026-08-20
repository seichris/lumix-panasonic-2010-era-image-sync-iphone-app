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
    @State private var selectedIcon: AppIconChoice = .primary
    @State private var pendingIcon: AppIconChoice?
    @State private var errorMessage: String?

    var body: some View {
#if os(iOS)
        List {
            Section {
                Text("Choose how GM1 Sync appears on your Home Screen. Your selection can be changed again at any time.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(AppIconChoice.allCases) { icon in
                    Button {
                        select(icon)
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
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(pendingIcon != nil || icon == selectedIcon)
                    .accessibilityIdentifier("app-icon-\(icon.rawValue)")
                    .accessibilityValue(icon == selectedIcon ? "Selected" : "Not selected")
                }
            } header: {
                Text("App icon")
            } footer: {
                Text("iOS confirms each icon change with a system message.")
            }
        }
        .navigationTitle("App Icon")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            selectedIcon = AppIconChoice.current
        }
        .alert("Couldn’t change app icon", isPresented: errorIsPresented) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Please try again.")
        }
#else
        ContentUnavailableView(
            "Blue Camera icon",
            systemImage: "app.fill",
            description: Text("GM1 Sync uses the Blue Camera logo on Mac. Alternate icon choices are available on iPhone.")
        )
        .navigationTitle("App Icon")
#endif
    }

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
