import SwiftUI

struct CameraCompatibilityView: View {
    /// On iPhone, the camera icons offer the custom icons purchase; without a store
    /// (the Mac app) the rows show text only.
    var iconStore: AppIconStore?
    @State private var offeredIcon: AppIconChoice?

    var body: some View {
        List {
            ForEach(CameraCompatibilityCatalog.sections) { section in
                Section {
                    ForEach(section.cameras) { camera in
                        CameraCandidateRow(camera: camera, showsIcons: iconStore != nil) { offeredIcon = $0 }
                    }
                } header: {
                    Text(section.title)
                } footer: {
                    Text(section.detail)
                }
            }

            Section("About this list") {
                Text("Dates are approximate model-introduction eras based on Panasonic's Image App support history, not exact manufacturing spans.")
                Text("Panasonic, LUMIX, and the camera model names belong to their respective owner. Retro LUMIX Sync is independent software and is not affiliated with or endorsed by Panasonic.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .navigationTitle("Cameras that work with this app")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $offeredIcon) { icon in
            if let iconStore {
                AppIconOfferSheet(icon: icon, store: iconStore)
            }
        }
#endif
    }
}

private struct CameraCandidateRow: View {
    let camera: CameraCandidate
    let showsIcons: Bool
    let offer: (AppIconChoice) -> Void

    var body: some View {
        HStack(spacing: 12) {
            if showsIcons {
                CameraIconTile(icons: AppIconChoice.icons(forCamera: camera.models), offer: offer)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(camera.models)
                    .font(.headline)
                HStack(spacing: 8) {
                    Text(camera.modelEra)
                    Text(camera.confidence.rawValue)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// The app icons that show this camera: one fills the tile, two to four share it in a
/// 2 × 2 grid, and a camera without an icon gets a faint placeholder.
private struct CameraIconTile: View {
    let icons: [AppIconChoice]
    let offer: (AppIconChoice) -> Void
    private let size: CGFloat = 52

    var body: some View {
        Group {
            switch icons.count {
            case 0:
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
                    .overlay {
                        Image(systemName: "camera")
                            .foregroundStyle(.tertiary)
                    }
                    .accessibilityHidden(true)
            case 1:
                iconButton(icons[0], side: size, cornerRadius: 12)
            default:
                let side = (size - 4) / 2
                LazyVGrid(columns: [GridItem(.fixed(side), spacing: 4), GridItem(.fixed(side), spacing: 4)], spacing: 4) {
                    ForEach(icons.prefix(4)) { icon in
                        iconButton(icon, side: side, cornerRadius: 5.5)
                    }
                }
            }
        }
        // One row of icons (two at most) sits in the middle of the tile; more fill it from the top.
        .frame(width: size, height: size, alignment: icons.count <= 2 ? .center : .topLeading)
    }

    private func iconButton(_ icon: AppIconChoice, side: CGFloat, cornerRadius: CGFloat) -> some View {
        Button { offer(icon) } label: {
            Image(icon.previewAssetName)
                .resizable()
                .scaledToFit()
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("\(icon.title) app icon")
        .accessibilityIdentifier("camera-icon-\(icon.rawValue)")
    }
}

#if os(iOS)
/// Offers one camera icon: buy the custom icons and switch to it, or switch if unlocked.
private struct AppIconOfferSheet: View {
    let icon: AppIconChoice
    @ObservedObject var store: AppIconStore
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    var body: some View {
        // Scrolls on small iPhones, where the medium sheet is shorter than the offer.
        ScrollView {
            offer
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.medium, .large])
        .task { await store.refresh() }
        // A failure shown here shouldn't come back as an alert on the App Icon screen.
        .onDisappear { store.dismissError() }
    }

    private var offer: some View {
        VStack(spacing: 14) {
            Image(icon.previewAssetName)
                .resizable()
                .scaledToFit()
                .frame(width: 112, height: 112)
                .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
                .padding(.top, 24)
            Text("\(icon.title) app icon")
                .font(.title2.bold())
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            if store.isAvailable(icon) {
                Button {
                    Task { await apply() }
                } label: {
                    Text("Use as app icon").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("offer-use-icon")
            } else {
                Button {
                    Task {
                        await store.purchase()
                        if store.isAvailable(icon) { await apply() }
                    }
                } label: {
                    HStack {
                        Text(store.price.map { "Unlock for \($0)" } ?? "Unlock custom icons")
                        if store.purchaseState == .purchasing { ProgressView() }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(store.price == nil || store.purchaseState == .purchasing || store.purchaseState == .restoring)
                .accessibilityIdentifier("offer-unlock-icons")
            }

            Button("Not now") { dismiss() }
                .accessibilityIdentifier("offer-not-now")

            if let status {
                Text(status.text)
                    .font(.caption)
                    .foregroundStyle(status.isProblem ? Color.red : Color.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("offer-status")
            }
        }
    }

    /// Why the icon isn't set yet: a failure, Ask to Buy, or no product in the App Store.
    /// The App Icon screen says the same in its footer and alert.
    private var status: (text: String, isProblem: Bool)? {
        if let errorMessage { return (errorMessage, true) }
        switch store.purchaseState {
        case let .failed(message):
            return (message, true)
        case .pending:
            return ("Waiting for approval. The icons unlock when the purchase goes through.", false)
        default:
            break
        }
        if store.price == nil, !store.isAvailable(icon) {
            return ("The App Store isn't offering the custom icons right now.", false)
        }
        return nil
    }

    private var message: String {
        if store.isAvailable(icon) {
            return "Use it as the Retro LUMIX Sync icon on your Home Screen."
        }
        let price = store.price ?? "a small one-time price"
        return "Set it as your app icon with the custom app icons: a one-time purchase of \(price) that unlocks every icon and supports development."
    }

    private func apply() async {
        do {
            try await icon.makeAppIcon()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
#endif

struct CameraCandidate: Identifiable, Hashable {
    enum Confidence: String, Hashable {
        case primaryTarget = "Primary test target"
        case closestCandidate = "Closest candidate"
        case strongCandidate = "Strong candidate"
        case imageAppCandidate = "Image App candidate"
        case laterCandidate = "Later, unverified candidate"
    }

    let models: String
    let modelEra: String
    let confidence: Confidence

    var id: String { models }
}

struct CameraCandidateSection: Identifiable, Hashable {
    let title: String
    let detail: String
    let cameras: [CameraCandidate]

    var id: String { title }
}

enum CameraCompatibilityCatalog {
    static let sections: [CameraCandidateSection] = [
        CameraCandidateSection(
            title: "GM family · 2013–2014",
            detail: "The GM1, GM1S, and GM5 are the first hardware targets because they are the closest relatives.",
            cameras: [
                camera("Panasonic DMC-GM1", "Introduced c. 2013", .closestCandidate),
                camera("Panasonic DMC-GM1S", "Introduced c. 2014", .primaryTarget),
                camera("Panasonic DMC-GM5", "Introduced c. 2014", .closestCandidate)
            ]
        ),
        CameraCandidateSection(
            title: "Early system cameras · 2013–2015",
            detail: "These cameras belong to the early Wi-Fi/Image App generation and are strong protocol candidates.",
            cameras: [
                camera("Panasonic DMC-GF6", "Introduced c. 2013", .strongCandidate),
                camera("Panasonic DMC-G6", "Introduced c. 2013", .strongCandidate),
                camera("Panasonic DMC-GX7", "Introduced c. 2013", .strongCandidate),
                camera("Panasonic DMC-GH4", "Introduced c. 2014", .strongCandidate),
                camera("Panasonic DMC-GF7", "Introduced c. 2015", .strongCandidate),
                camera("Panasonic DMC-G7 / G70", "Introduced c. 2015", .strongCandidate),
                camera("Panasonic DMC-GX8", "Introduced c. 2015", .strongCandidate)
            ]
        ),
        CameraCandidateSection(
            title: "Mature system cameras · 2016–2019",
            detail: "Panasonic retained Image App for these models, but authorization and camera commands may differ.",
            cameras: [
                camera("Panasonic DMC-GF8", "Introduced c. 2016", .imageAppCandidate),
                camera("Panasonic DMC-GX80 / GX85", "Introduced c. 2016", .imageAppCandidate),
                camera("Panasonic DMC-G80 / G81 / G85", "Introduced c. 2016", .imageAppCandidate),
                camera("Panasonic DC-GF9 / GX800 / GX850", "Introduced c. 2017", .imageAppCandidate),
                camera("Panasonic DC-GH5", "Introduced c. 2017", .imageAppCandidate),
                camera("Panasonic DC-G9", "Introduced c. 2017", .imageAppCandidate),
                camera("Panasonic DC-GH5S", "Introduced c. 2018", .imageAppCandidate),
                camera("Panasonic DC-GF10", "Introduced c. 2018", .imageAppCandidate),
                camera("Panasonic DC-GX9", "Introduced c. 2018", .imageAppCandidate),
                camera("Panasonic DC-G90 / G91 / G95 / G95D", "Model era c. 2019+", .laterCandidate)
            ]
        ),
        CameraCandidateSection(
            title: "Early compact cameras · 2013–2015",
            detail: "These fixed-lens cameras used Panasonic Image App during the same broad protocol era.",
            cameras: [
                camera("Panasonic DMC-FT5 / TS5", "Introduced c. 2013", .imageAppCandidate),
                camera("Panasonic DMC-TZ40 / TZ41 / TZ37 / ZS30 / ZS27", "Introduced c. 2013", .imageAppCandidate),
                camera("Panasonic DMC-SZ9", "Introduced c. 2013", .imageAppCandidate),
                camera("Panasonic DMC-LF1", "Introduced c. 2013", .strongCandidate),
                camera("Panasonic DMC-TZ60 / TZ61 / ZS40 / SZ8", "Introduced c. 2014", .imageAppCandidate),
                camera("Panasonic DMC-TZ55 / TZ56 / ZS35", "Introduced c. 2014", .imageAppCandidate),
                camera("Panasonic DMC-FZ1000", "Introduced c. 2014", .strongCandidate),
                camera("Panasonic DMC-LX100", "Introduced c. 2014", .strongCandidate),
                camera("Panasonic DMC-TZ70 / TZ71 / ZS50", "Introduced c. 2015", .imageAppCandidate),
                camera("Panasonic DMC-TZ57 / TZ58 / ZS45", "Introduced c. 2015", .imageAppCandidate),
                camera("Panasonic DMC-SZ10", "Introduced c. 2015", .imageAppCandidate),
                camera("Panasonic DMC-FT6 / TS6", "Introduced c. 2015", .imageAppCandidate),
                camera("Panasonic DMC-FZ300 / FZ330", "Introduced c. 2015", .imageAppCandidate)
            ]
        ),
        CameraCandidateSection(
            title: "Later compact cameras · 2016–2019",
            detail: "Media browsing may be similar, but these cameras require real-device capability probes.",
            cameras: [
                camera("Panasonic DMC-TZ100 / TZ101 / TZ110 / ZS100 / ZS110", "Introduced c. 2016", .imageAppCandidate),
                camera("Panasonic DMC-TZ80 / TZ81 / ZS60", "Introduced c. 2016", .imageAppCandidate),
                camera("Panasonic DMC-FZ2000 / FZ2500", "Introduced c. 2016", .imageAppCandidate),
                camera("Panasonic DMC-LX9 / LX10 / LX15", "Introduced c. 2016", .imageAppCandidate),
                camera("Panasonic DC-FZ80 / FZ82", "Introduced c. 2017", .imageAppCandidate),
                camera("Panasonic DC-TZ90 / TZ91 / TZ92 / TZ93 / ZS70", "Introduced c. 2017", .imageAppCandidate),
                camera("Panasonic DC-TZ200 / TZ200D / TZ202 / TZ202D / TZ220 / TZ220D / ZS200 / ZS200D / ZS220 / ZS220D", "Introduced c. 2018", .laterCandidate),
                camera("Panasonic DC-FT7 / TS7", "Introduced c. 2018", .laterCandidate),
                camera("Panasonic DC-LX100M2", "Introduced c. 2018", .laterCandidate),
                camera("Panasonic DC-FZ1000M2 / FZ10002", "Introduced c. 2019", .laterCandidate),
                camera("Panasonic DC-TZ95 / TZ95D / TZ96 / TZ96D / TZ97 / ZS80 / ZS80D", "Model era c. 2019+", .laterCandidate)
            ]
        ),
        CameraCandidateSection(
            title: "Recent Image App compacts · 2025–2026",
            detail: "Panasonic still lists these with Image App, but Retro LUMIX Sync does not assume they share the legacy protocol.",
            cameras: [
                camera("Panasonic DC-TZ99 / ZS99", "Introduced c. 2025", .laterCandidate),
                camera("Panasonic DC-TZ300 / ZS300", "Introduced c. 2026", .laterCandidate)
            ]
        )
    ]

    static var allCameras: [CameraCandidate] {
        sections.flatMap(\.cameras)
    }

    private static func camera(
        _ models: String,
        _ modelEra: String,
        _ confidence: CameraCandidate.Confidence
    ) -> CameraCandidate {
        CameraCandidate(models: models, modelEra: modelEra, confidence: confidence)
    }
}
