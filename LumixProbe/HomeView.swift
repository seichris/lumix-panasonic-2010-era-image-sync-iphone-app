#if os(iOS)
import SwiftUI

/// What someone comes to the app to do with the camera. The job decides the camera's
/// Wi-Fi function: browsing, shooting, and the camera tools use Remote Shooting & View;
/// receiving photos while shooting uses Send Images While Recording (`PushTransferView`).
enum CameraJob: String, Hashable, Identifiable {
    case photos
    case liveView
    case writeLocations
    case setClock

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photos: return "Get photos from the card"
        case .liveView: return "Shoot from your iPhone"
        case .writeLocations: return "Write locations to camera photos"
        case .setClock: return "Set the camera clock"
        }
    }

    var subtitle: String {
        switch self {
        case .photos: return "Browse the card and import originals"
        case .liveView: return "Live view, photos, and video"
        case .writeLocations: return "The camera adds your track's GPS to its photos"
        case .setClock: return "Match the camera's time to this iPhone"
        }
    }

    var systemImage: String {
        switch self {
        case .photos: return "photo.on.rectangle"
        case .liveView: return "camera.viewfinder"
        case .writeLocations: return "mappin.and.ellipse"
        case .setClock: return "clock.arrow.2.circlepath"
        }
    }

    /// The tool the camera screen opens first, for jobs that are a camera tool.
    var tool: CameraTool? {
        switch self {
        case .writeLocations: return .writeLocations
        case .setClock: return .setClock
        case .photos, .liveView: return nil
        }
    }
}

enum CameraTool: Hashable {
    case writeLocations
    case setClock
}

enum AppRoute: Hashable {
    case camera(CameraJob)
    case geotagging
    case compatibleCameras
    case appIcon
    case developerSettings
}

/// The first screen: the location log, then the jobs that need the camera.
struct HomeView: View {
    @ObservedObject var model: ProbeViewModel
    @ObservedObject var logger: GeotagLocationLogger
    let openCompatibleCameras: () -> Void
    let openReceive: () -> Void

    /// The camera names in the header link here; the home screen opens the camera list.
    static let compatibleCamerasURL = URL(string: "gm1sync://compatible-cameras")!
    private static let exampleCameras = ["GM1", "GX7", "LX100"]

    var body: some View {
        List {
            header
            LocationLogCard(logger: logger)
            cameraJobs
            aboutSection
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .contentMargins(.top, 0, for: .scrollContent)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Retro LUMIX Sync")
                    .font(.largeTitle.bold())
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("landing-title")

                Text(alternativeText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .environment(\.openURL, OpenURLAction { url in
                        guard url == Self.compatibleCamerasURL else { return .systemAction }
                        openCompatibleCameras()
                        return .handled
                    })
                    .accessibilityIdentifier("image-app-alternative-text")
            }

            Spacer(minLength: 0)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    /// "…like the GM1, GX7, and LX100.", with each camera name underlined and linked to the camera list.
    private var alternativeText: AttributedString {
        var text = AttributedString("An independent alternative to Panasonic Image App for 2010-era Lumix cameras, like the ")
        let names = Self.exampleCameras
        for (index, name) in names.enumerated() {
            var link = AttributedString(name)
            link.link = Self.compatibleCamerasURL
            link.underlineStyle = .single
            text += link
            if index < names.count - 2 {
                text += AttributedString(", ")
            } else if index == names.count - 2 {
                text += AttributedString(", and ")
            }
        }
        text += AttributedString(".")
        return text
    }

    private var cameraJobs: some View {
        Section {
            NavigationLink(value: AppRoute.camera(.photos)) {
                CameraJobLabel(title: CameraJob.photos.title, subtitle: CameraJob.photos.subtitle,
                               systemImage: CameraJob.photos.systemImage)
            }
            .accessibilityIdentifier("open-camera-photos")

            NavigationLink(value: AppRoute.camera(.liveView)) {
                CameraJobLabel(title: CameraJob.liveView.title, subtitle: CameraJob.liveView.subtitle,
                               systemImage: CameraJob.liveView.systemImage)
            }
            .accessibilityIdentifier("open-live-view")

            // Receiving opens full screen, so this row is a button styled like the links above.
            Button(action: openReceive) {
                CameraJobLabel(title: "Receive photos as you shoot", subtitle: "Each photo is saved as you take it",
                               systemImage: "square.and.arrow.down.on.square", showsChevron: true)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("open-push-transfer")

            NavigationLink(value: AppRoute.camera(.writeLocations)) {
                CameraJobLabel(title: CameraJob.writeLocations.title, subtitle: CameraJob.writeLocations.subtitle,
                               systemImage: CameraJob.writeLocations.systemImage)
            }
            .accessibilityIdentifier("home-open-location-writer")

            NavigationLink(value: AppRoute.camera(.setClock)) {
                CameraJobLabel(title: CameraJob.setClock.title, subtitle: CameraJob.setClock.subtitle,
                               systemImage: CameraJob.setClock.systemImage)
            }
            .accessibilityIdentifier("home-open-camera-clock")
        } header: {
            // The connection sits in the header so it stays visible above the camera jobs.
            HStack {
                Text("With your camera")
                Spacer(minLength: 8)
                if model.isCameraConnected {
                    Label("Connected to \(model.rememberedCameraNetwork?.ssid ?? "the camera")", systemImage: "circle.fill")
                        .labelStyle(ConnectionDotLabelStyle())
                        .font(.caption)
                        .lineLimit(1)
                        .accessibilityIdentifier("home-camera-connected")
                }
            }
        } footer: {
            if !model.isCameraConnected {
                Text("Pick what you want to do. Retro LUMIX Sync then shows which camera Wi‑Fi mode to choose.")
            }
        }
    }

    private var aboutSection: some View {
        Section {
            Link(destination: Self.githubRepositoryURL) {
                VStack(alignment: .leading, spacing: 3) {
                    Label("View this app's code on GitHub", systemImage: "curlybraces")
                    Text("View source code and report issues")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("github-repository-link")

            NavigationLink(value: AppRoute.compatibleCameras) {
                aboutRow("Potentially compatible cameras", detail: "GM-family and Panasonic Image App models by era")
            }
            .accessibilityIdentifier("camera-compatibility-link")

            NavigationLink(value: AppRoute.appIcon) {
                aboutRow("App icon", detail: "Choose Blue Camera, Lens, or Black Camera")
            }
            .accessibilityIdentifier("app-icon-link")

            NavigationLink(value: AppRoute.developerSettings) {
                aboutRow("Developer settings", detail: "Camera address, connection, and protocol tests")
            }
            .accessibilityIdentifier("developer-settings-link")
        } header: {
            Text("About")
        } footer: {
            Text(Self.appVersionText)
                .font(.footnote.monospacedDigit())
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                .accessibilityIdentifier("app-version")
        }
    }

    private func aboutRow(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private static var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "Retro LUMIX Sync · Version \(version) (\(build))"
    }

    private static let githubRepositoryURL = URL(
        string: "https://github.com/seichris/lumix-panasonic-2010-era-image-sync-iphone-app"
    )!
}

private struct ConnectionDotLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
                .font(.system(size: 8))
                .foregroundStyle(.green)
            configuration.title
        }
    }
}

struct CameraJobLabel: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var showsChevron = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

/// Start or stop the location log from the home screen; everything else about
/// geotagging lives on the Geotagging settings screen.
struct LocationLogCard: View {
    @ObservedObject var logger: GeotagLocationLogger

    var body: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: logger.isLogging ? "location.fill" : "location")
                    .font(.title2)
                    .foregroundStyle(logger.isLogging ? Color.green : Color.accentColor)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(logger.isLogging ? "Location log running" : "Location log")
                        .font(.headline)
                    Text(statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if logger.isLogging {
                    Button("Stop", role: .destructive) { logger.stop() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("stop-location-log")
                } else {
                    Button("Start") { logger.start() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("start-location-log")
                }
            }
            .padding(.vertical, 4)

            NavigationLink(value: AppRoute.geotagging) {
                Text("Geotagging settings")
                    .font(.subheadline)
            }
            .accessibilityIdentifier("open-geotagging-settings")
        } header: {
            Text("Geotagging")
        } footer: {
            Text("Geotagging adds where each photo was taken. While the log runs, this iPhone records its location, and imported photos get the place that matches their capture time.")
        }
    }

    private var statusLine: String {
        if let problem { return problem }
        if logger.isLogging {
            let points = "\(logger.samples.count) points"
            guard let accuracy = logger.latestSample?.horizontalAccuracy, accuracy >= 0 else { return points }
            return "±\(Int(accuracy.rounded())) m · \(points)"
        }
        return logger.samples.isEmpty ? "Off. Start it before you shoot." : "Off · \(logger.samples.count) saved points"
    }

    /// The logger's message when it needs attention, such as missing permission.
    private var problem: String? {
        let message = logger.statusMessage
        let markers = ["disabled", "Allow location access", "permission", "Could not", "failed", "unavailable"]
        return markers.contains(where: message.contains) ? message : nil
    }
}

/// Everything about geotagging: the location log, the widget, automatic start,
/// Google Timeline imports, clearing the track, and the camera clock adjustment.
struct GeotaggingSettingsView: View {
    @ObservedObject var model: ProbeViewModel
    @State private var isConfirmingTrackClear = false

    var body: some View {
        List {
            GeotaggingControls(
                logger: model.locationLogger,
                autoStartGeotagging: $model.autoStartGeotagging,
                cameraClockOffsetMinutes: $model.cameraClockOffsetMinutes,
                clearTrack: { isConfirmingTrackClear = true }
            )
        }
        .navigationTitle("Geotagging")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Clear location track?", isPresented: $isConfirmingTrackClear) {
            Button("Clear", role: .destructive) { model.locationLogger.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved location samples will be removed from this iPhone. Downloaded camera originals are not affected.")
        }
    }
}

/// A camera job: the camera steps for its Wi-Fi mode until the camera is connected,
/// then the camera screen. Losing the connection shows the steps again.
struct CameraJobView<Camera: View>: View {
    let job: CameraJob
    @ObservedObject var model: ProbeViewModel
    let reconnect: () -> Void
    let scanQRCode: () -> Void
    let joinManually: () -> Void
    @ViewBuilder let camera: () -> Camera

    var body: some View {
        if model.isCameraConnected {
            camera()
        } else {
            CameraSetupView(job: job, model: model, reconnect: reconnect,
                            scanQRCode: scanQRCode, joinManually: joinManually)
        }
    }
}

struct CameraSetupView: View {
    let job: CameraJob
    @ObservedObject var model: ProbeViewModel
    let reconnect: () -> Void
    let scanQRCode: () -> Void
    let joinManually: () -> Void

    var body: some View {
        List {
            Section {
                step(1, "Choose Wi‑Fi → Wi‑Fi Function → New Connection → Remote Shooting & View.")
                step(2, "The camera shows its network name, password, and a QR code.")
                Text("Connected this camera before? Choose Wi‑Fi Function → Select a destination from History instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("On the camera")
            }

            Section {
                if let ssid = model.rememberedCameraNetwork?.ssid {
                    actionButton("Join \(ssid)", systemImage: "wifi", prominent: true, action: reconnect)
                        .accessibilityIdentifier("reconnect-remembered-camera")
                    actionButton("Scan another camera QR code", systemImage: "qrcode.viewfinder", action: scanQRCode)
                        .accessibilityIdentifier("scan-camera-qr-code")
                } else {
                    actionButton("Scan camera QR code", systemImage: "qrcode.viewfinder", prominent: true, action: scanQRCode)
                        .accessibilityIdentifier("scan-camera-qr-code")
                }
                actionButton("Enter wi-fi name and password", systemImage: "keyboard", action: joinManually)
                    .accessibilityIdentifier("join-camera-wifi-manually")
                Label(model.connectionStatusMessage, systemImage: "wifi.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("On this iPhone")
            }
        }
        .navigationTitle(job.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.subheadline.monospacedDigit().bold())
                .foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline)
        }
    }

    @ViewBuilder
    private func actionButton(_ title: String, systemImage: String, prominent: Bool = false,
                              action: @escaping () -> Void) -> some View {
        let button = Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
        if prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }
}

/// The connected camera: its photos and its live view, switched at the top.
struct CameraScreen: View {
    enum Mode: Hashable {
        case photos
        case liveView
    }

    let job: CameraJob
    @ObservedObject var store: CameraGalleryStore
    @ObservedObject var model: ProbeViewModel
    @ObservedObject var modeCoordinator: CameraModeCoordinator
    let makeRemoteShootingSession: @MainActor () -> RemoteShootingSession
    let geotagEnvironment: CameraGeotagEnvironment
    let openPushTransfer: () -> Void
    @State private var mode: Mode
    /// A camera tool the job asked for, opened once by the gallery.
    @State private var pendingTool: CameraTool?

    init(
        job: CameraJob,
        store: CameraGalleryStore,
        model: ProbeViewModel,
        modeCoordinator: CameraModeCoordinator,
        makeRemoteShootingSession: @escaping @MainActor () -> RemoteShootingSession,
        geotagEnvironment: CameraGeotagEnvironment,
        openPushTransfer: @escaping () -> Void
    ) {
        self.job = job
        self.store = store
        self.model = model
        self.modeCoordinator = modeCoordinator
        self.makeRemoteShootingSession = makeRemoteShootingSession
        self.geotagEnvironment = geotagEnvironment
        self.openPushTransfer = openPushTransfer
        _mode = State(initialValue: job == .liveView ? .liveView : .photos)
        _pendingTool = State(initialValue: job.tool)
    }

    var body: some View {
        Group {
            switch mode {
            case .photos:
                CameraGalleryView(
                    store: store,
                    model: model,
                    modeCoordinator: modeCoordinator,
                    geotagEnvironment: geotagEnvironment,
                    openPushTransfer: openPushTransfer,
                    pendingTool: $pendingTool
                )
            case .liveView:
                RemoteShootingView(makeSession: makeRemoteShootingSession)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Camera view", selection: $mode) {
                    Text("Photos").tag(Mode.photos)
                    Text("Live view").tag(Mode.liveView)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)
                // Live view needs the camera to itself: not while importing or while
                // another activity, such as writing locations, holds it.
                .disabled(store.isImporting || (mode == .photos && modeCoordinator.exclusiveActivity != nil))
                .accessibilityIdentifier("camera-view-picker")
            }
        }
    }
}
#endif
