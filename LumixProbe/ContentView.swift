import MapKit
import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = ProbeViewModel()
    @State private var presentedSheet: ConnectionSheet?
    @State private var isConfirmingTrackClear = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("An independent alternative to Panasonic Image App for compatible older cameras.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("image-app-alternative-text")
                }

                if !model.isCameraConnected {
                    CameraConnectionGuide(
                        statusMessage: model.connectionStatusMessage,
                        scanQRCode: { presentedSheet = .qrScanner }
                    )
                }

                Section("Camera") {
                    if model.isCameraConnected {
                        Label("Connected to camera", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    TextField("Camera IP", text: $model.host)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.numbersAndPunctuation)
                    Text("The default address for this camera generation is 192.168.54.1.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Compatibility") {
                    NavigationLink {
                        CameraCompatibilityView()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Potentially compatible cameras")
                            Text("GM-family and Panasonic Image App models by era")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("camera-compatibility-link")
                }

                GeotaggingControls(
                    logger: model.locationLogger,
                    cameraClockOffsetMinutes: $model.cameraClockOffsetMinutes,
                    clearTrack: { isConfirmingTrackClear = true }
                )

                Section("Personalize") {
                    NavigationLink {
                        AppIconPickerView()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("App icon")
                            Text("Choose Lens, Blue Camera, or Black Camera")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("app-icon-link")
                }

                Section("Protocol tests") {
                    Button("Probe getstate") { model.probeState() }
                    Button("Request camera access") { model.requestAccess() }
                    Button("Run full probe") { model.runFullProbe() }
                        .fontWeight(.semibold)
                    Button("Probe media server directly") { model.browseFirstFiveDirectly() }
                    Button("Browse final 5 records") { model.browseLastFive() }
                    Button("Download first original JPEG") { model.downloadFirstOriginal() }
                        .disabled(model.isRunning)
                    LabeledContent("Last result") {
                        Text(model.lastResult)
                            .accessibilityIdentifier("lastResult")
                    }
                }
                .disabled(model.isRunning)

                if let photo = model.downloadedPhoto {
                    DownloadedPhotoGeotagPreview(
                        photo: photo,
                        logger: model.locationLogger,
                        cameraClockOffsetMinutes: model.cameraClockOffsetMinutes,
                        isSaving: model.isSavingPhoto,
                        save: model.saveDownloadedToPhotos
                    )
                }

                if !model.resources.isEmpty {
                    Section("Advertised resources") {
                        ForEach(model.resources) { resource in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(resource.profileName ?? "Unknown profile").font(.headline)
                                Text(resource.title ?? resource.url.lastPathComponent).font(.subheadline)
                                Text(resource.url.absoluteString)
                                    .font(.caption2.monospaced())
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }

                Section {
                    HStack {
                        Text("Raw probe log").font(.headline)
                        Spacer()
                        Button("Clear") { model.clearLog() }.font(.caption)
                    }
                    Text(model.log)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("GM1 Sync")
            .overlay {
                if model.isRunning { ProgressView().controlSize(.large) }
            }
            .task { await model.refreshConnectionStatus() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await model.refreshConnectionStatus() }
            }
            .sheet(item: $presentedSheet) { destination in
                switch destination {
                case .qrScanner:
                    QRCodeScannerSheet { payload in
                        Task { await model.joinCameraWiFi(qrPayload: payload) }
                    }
                }
            }
            .alert("Clear location track?", isPresented: $isConfirmingTrackClear) {
                Button("Clear", role: .destructive) { model.locationLogger.clear() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Saved location samples will be removed from this iPhone. Downloaded camera originals are not affected.")
            }
        }
    }
}

private struct GeotaggingControls: View {
    @ObservedObject var logger: GeotagLocationLogger
    @Binding var cameraClockOffsetMinutes: Double
    let clearTrack: () -> Void

    var body: some View {
        Section("Geotagging") {
            if logger.isLogging {
                Label("Location log running", systemImage: "location.fill")
                    .foregroundStyle(.green)
                Button("Stop location log", role: .destructive) { logger.stop() }
                    .accessibilityIdentifier("stop-location-log")
            } else {
                Button { logger.start() } label: {
                    Label("Start location log", systemImage: "location.circle.fill")
                }
                .accessibilityIdentifier("start-location-log")
            }

            Text(logger.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)

            if !logger.samples.isEmpty {
                LabeledContent("Track samples", value: "\(logger.samples.count)")
                if let latest = logger.latestSample {
                    LabeledContent("Latest accuracy", value: "±\(Int(latest.horizontalAccuracy.rounded())) m")
                }
                Button("Clear saved location track", role: .destructive, action: clearTrack)
                    .disabled(logger.isLogging)
            }

            Stepper(value: $cameraClockOffsetMinutes, in: -720...720, step: 1) {
                LabeledContent("Camera clock adjustment") {
                    Text(clockOffsetLabel)
                }
            }
            .accessibilityIdentifier("camera-clock-adjustment")

            Text("Start before shooting. The visible location session continues while this iPhone is locked. Use a positive adjustment when the camera is behind the iPhone, or a negative one when it is ahead.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var clockOffsetLabel: String {
        let minutes = Int(cameraClockOffsetMinutes)
        if minutes == 0 { return "None" }
        return String(format: "%+d min", minutes)
    }
}

private struct DownloadedPhotoGeotagPreview: View {
    let photo: DownloadedPhoto
    @ObservedObject var logger: GeotagLocationLogger
    let cameraClockOffsetMinutes: Double
    let isSaving: Bool
    let save: () -> Void

    private var match: GeotagMatch? {
        guard let captureDate = photo.captureDate else { return nil }
        return LocationTrackMatcher.match(
            captureDate: captureDate,
            samples: logger.samples,
            cameraClockOffset: cameraClockOffsetMinutes * 60
        )
    }

    var body: some View {
        Section("Downloaded photo") {
            Text(photo.originalFilename)
                .font(.headline)

            if let captureDate = photo.captureDate {
                LabeledContent("Camera time") {
                    Text(captureDate.formatted(date: .abbreviated, time: .standard))
                }
            } else {
                Label("No EXIF capture time", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("This file can still be saved unchanged, but it cannot be matched automatically to the location track.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let match {
                MatchedLocationMap(match: match)
                Label(match.quality.rawValue, systemImage: qualityIcon(match.quality))
                    .foregroundStyle(qualityColor(match.quality))
                LabeledContent("Position") {
                    Text(String(format: "%.5f, %.5f", match.latitude, match.longitude))
                        .font(.caption.monospaced())
                }
                LabeledContent("Accuracy", value: "±\(Int(match.horizontalAccuracy.rounded())) m")
                LabeledContent("Method", value: match.method.rawValue)
                LabeledContent("Nearest sample", value: timeDifferenceLabel(match.nearestSampleTimeDifference))
            } else if photo.captureDate != nil {
                Label("No nearby location sample", systemImage: "location.slash")
                    .foregroundStyle(.orange)
                Text("Record a location track near the photo time or adjust the camera clock. Matches farther than 15 minutes are rejected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(match == nil ? "Save original without location" : "Save original with this location", action: save)
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)
                .accessibilityIdentifier("save-downloaded-photo")

            Text("Photos receives the original camera file as its unadjusted resource. The map location is attached to the Photos asset; the downloaded JPEG bytes and the camera SD card are not modified.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func timeDifferenceLabel(_ interval: TimeInterval) -> String {
        if interval < 1 { return "same moment" }
        if interval < 60 { return "\(Int(interval.rounded())) sec away" }
        return "\(Int((interval / 60).rounded())) min away"
    }

    private func qualityIcon(_ quality: GeotagMatch.Quality) -> String {
        switch quality {
        case .excellent: return "checkmark.circle.fill"
        case .good: return "checkmark.circle"
        case .uncertain: return "exclamationmark.triangle"
        }
    }

    private func qualityColor(_ quality: GeotagMatch.Quality) -> Color {
        quality == .uncertain ? .orange : .green
    }
}

private struct MatchedLocationMap: View {
    let match: GeotagMatch

    var body: some View {
        Map(initialPosition: .region(region)) {
            Marker("Matched location", coordinate: match.location.coordinate)
        }
        .frame(height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("Map preview of the matched photo location")
        .id("\(match.latitude)-\(match.longitude)")
    }

    private var region: MKCoordinateRegion {
        MKCoordinateRegion(
            center: match.location.coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
    }
}

private enum ConnectionSheet: String, Identifiable {
    case qrScanner

    var id: String { rawValue }
}
