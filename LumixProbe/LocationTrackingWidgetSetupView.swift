#if os(iOS)
import SwiftUI
import WidgetKit

struct LocationTrackingWidgetSetupButton: View {
    @State private var isShowingSetup = false

    var body: some View {
        Button {
            isShowingSetup = true
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add Home Screen widget")
                    Text("One tap on. One tap off.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "square.grid.2x2")
            }
        }
        .accessibilityIdentifier("add-tracking-widget")
        .sheet(isPresented: $isShowingSetup) {
            LocationTrackingWidgetSetupView()
        }
    }
}

struct LocationTrackingWidgetSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var hasWidget = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(spacing: 12) {
                        LocationTrackingWidgetContent(state: .off)
                            .padding(16)
                            .frame(width: 170, height: 180)
                            .background(.background, in: RoundedRectangle(cornerRadius: 24))
                            .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
                            .accessibilityHidden(true)

                        Text("One tap on. One tap off.")
                            .font(.title2.bold())
                        Text("Start and stop your location track from your Home Screen.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)

                    if hasWidget {
                        Label("Widget added", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .accessibilityIdentifier("tracking-widget-added")
                    }

                    if #available(iOS 18, *) {
                        step(1, title: "Touch and hold the app icon",
                             detail: "Go to your Home Screen and touch and hold Retro LUMIX Sync.")
                        step(2, title: "Choose the small widget",
                             detail: "Tap the square widget option in the menu. You’re ready to go.")
                        DisclosureGroup("Can’t find the widget option?") {
                            galleryInstructions
                                .padding(.top, 12)
                        }
                        .font(.subheadline)
                    } else {
                        galleryInstructions
                    }

                    Text("iOS adds widgets from the Home Screen. Each tap on this widget opens the app and turns tracking on or off. Your first start may ask for location permission.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Add Home Screen widget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("widget-setup-done")
                }
            }
            .task { await refreshWidgetStatus() }
            .onOpenURL { url in
                if LocationTrackingAction(url: url) != nil { dismiss() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { await refreshWidgetStatus() }
                }
            }
        }
    }

    private var galleryInstructions: some View {
        VStack(alignment: .leading, spacing: 16) {
            step(1, title: "Open the widget gallery",
                 detail: "Touch and hold an empty area on your Home Screen, then tap Edit → Add Widget.")
            step(2, title: "Find Retro LUMIX Sync",
                 detail: "Search for Retro LUMIX Sync and choose Geotagging.")
            step(3, title: "Tap Add Widget, then Done",
                 detail: "Place it wherever it’s easiest to reach.")
        }
    }

    private func step(_ number: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.headline)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.12), in: Circle())
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func refreshWidgetStatus() async {
        let widgets: [WidgetInfo]? = await withCheckedContinuation { continuation in
            WidgetCenter.shared.getCurrentConfigurations { result in
                continuation.resume(returning: try? result.get())
            }
        }
        guard let widgets else { return }
        hasWidget = widgets.contains { $0.kind == LocationTrackingWidgetState.kind }
    }
}
#endif
