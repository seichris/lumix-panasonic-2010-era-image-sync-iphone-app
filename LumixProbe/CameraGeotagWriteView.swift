import CoreLocation
import SwiftUI

/// What the location-writing and clock screens need from the app.
struct CameraGeotagEnvironment {
    let makeCamera: @MainActor () -> any CameraGeotagControlling
    let samples: @MainActor () -> [LocationSample]
}

// MARK: - Verification

struct CameraGeotagVerificationResult: Identifiable, Equatable {
    enum Status: Equatable {
        case taggedNearTrack(distance: Double)
        case taggedFarFromTrack(distance: Double)
        case taggedWithoutTrackPosition
        case notTagged
        case alreadyTaggedUnchanged
        case alreadyTaggedChanged
        case outsidePeriodUntouched
        case outsidePeriodTagged
        case unknownCaptureTime(hasLocation: Bool)
        case failed(String)

        var isProblem: Bool {
            switch self {
            case .taggedFarFromTrack, .notTagged, .alreadyTaggedChanged, .outsidePeriodTagged, .failed: return true
            default: return false
            }
        }
    }

    let id: LumixPhoto.ID
    let filename: String
    let captureDate: Date?
    let location: PhotoGeotagLocation?
    let status: Status
}

/// Re-reads the original JPEGs from the card after a write and compares their
/// GPS data with the uploaded track. A camera `finish` alone proves nothing.
@MainActor
final class CameraGeotagVerifier: ObservableObject {
    static let nearTrackDistance: CLLocationDistance = 250

    @Published private(set) var results: [CameraGeotagVerificationResult] = []
    @Published private(set) var isRunning = false
    @Published private(set) var checkedCount = 0
    @Published private(set) var candidateCount = 0
    @Published private(set) var skippedCount = 0
    private var task: Task<Void, Never>?

    func start(
        store: CameraGalleryStore,
        period: ClosedRange<Date>,
        samples: [LocationSample],
        baseline: [LumixPhoto.ID: PhotoGeotagLocation?],
        limit: Int = 120
    ) {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.verify(store: store, period: period, samples: samples, baseline: baseline, limit: limit)
            self?.task = nil
        }
    }

    func cancel() { task?.cancel() }

    func verify(
        store: CameraGalleryStore,
        period: ClosedRange<Date>,
        samples: [LocationSample],
        baseline: [LumixPhoto.ID: PhotoGeotagLocation?],
        limit: Int
    ) async {
        isRunning = true
        results = []
        checkedCount = 0
        defer { isRunning = false }
        await store.reloadAllMedia()
        let photos = store.photos.filter { $0.kind == .photo && $0.originalJPEGResource != nil }
        let candidates = Array(photos.prefix(max(1, limit)))
        candidateCount = candidates.count
        skippedCount = max(0, photos.count - candidates.count)
        let trackSamples = LumixGeodata.usableSamples(samples, in: period)

        for photo in candidates {
            if Task.isCancelled { return }
            let state = await store.inspectOriginalMetadata(for: photo, force: true)
            checkedCount += 1
            results.append(Self.classify(photo, state: state, period: period, trackSamples: trackSamples, baseline: baseline))
        }
    }

    static func classify(
        _ photo: LumixPhoto,
        state: CameraPhotoMetadataInspectionState,
        period: ClosedRange<Date>,
        trackSamples: [LocationSample],
        baseline: [LumixPhoto.ID: PhotoGeotagLocation?]
    ) -> CameraGeotagVerificationResult {
        guard case let .resolved(inspection) = state else {
            let message: String
            if case let .failed(text) = state { message = text } else { message = "Not checked" }
            return .init(id: photo.id, filename: photo.displayFilename, captureDate: nil, location: nil, status: .failed(message))
        }
        let location = inspection.embeddedLocation
        let captureDate = inspection.exifCaptureDate
        func result(_ status: CameraGeotagVerificationResult.Status) -> CameraGeotagVerificationResult {
            .init(id: photo.id, filename: photo.displayFilename, captureDate: captureDate, location: location, status: status)
        }

        if let known = baseline[photo.id], let before = known {
            // The photo was already geotagged before the write; Panasonic says it is skipped.
            guard let location else { return result(.alreadyTaggedChanged) }
            let moved = before.location.distance(from: location.location) > 1
            return result(moved ? .alreadyTaggedChanged : .alreadyTaggedUnchanged)
        }
        guard let captureDate else { return result(.unknownCaptureTime(hasLocation: location != nil)) }
        guard period.contains(captureDate) else {
            return result(location == nil ? .outsidePeriodUntouched : .outsidePeriodTagged)
        }
        guard let location else { return result(.notTagged) }
        guard let expected = LocationTrackMatcher.match(captureDate: captureDate, samples: trackSamples) else {
            return result(.taggedWithoutTrackPosition)
        }
        let distance = expected.location.distance(from: location.location)
        return result(distance <= nearTrackDistance ? .taggedNearTrack(distance: distance) : .taggedFarFromTrack(distance: distance))
    }
}

/// Reads capture times from the card before a write. Some cameras (the GM1S)
/// list their media without dates, so the period's photos are otherwise unknown.
/// Newest photos come first; the scan stops after a run of photos older than the
/// period, since the camera numbers its files in shooting order.
@MainActor
final class CameraGeotagPeriodScanner: ObservableObject {
    static let olderPhotosBeforeStopping = 5

    /// A scan that ran to its end for periods starting at `periodStart` or later.
    struct Completion: Equatable {
        let periodStart: Date
        let checked: Int
        /// It stopped at photos older than the period rather than at the end of the card.
        let reachedOlderPhotos: Bool

        func covers(_ period: ClosedRange<Date>) -> Bool { period.lowerBound >= periodStart }
    }

    @Published private(set) var isRunning = false
    @Published private(set) var checkedCount = 0
    @Published private(set) var completion: Completion?
    private var task: Task<Void, Never>?

    func start(store: CameraGalleryStore, period: ClosedRange<Date>, limit: Int = 120) {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.scan(store: store, period: period, limit: limit)
            self?.task = nil
        }
    }

    func cancel() { task?.cancel() }

    func scan(store: CameraGalleryStore, period: ClosedRange<Date>, limit: Int) async {
        isRunning = true
        checkedCount = 0
        completion = nil
        defer { isRunning = false }
        if store.canLoadMore { await store.loadAllPages() }
        let photos = store.photos.filter { $0.kind == .photo && $0.originalJPEGResource != nil }
        var olderInARow = 0
        for photo in photos.prefix(max(1, limit)) {
            if Task.isCancelled { return }
            let state = await store.inspectOriginalMetadata(for: photo)
            checkedCount += 1
            guard case let .resolved(inspection) = state, let date = inspection.exifCaptureDate else { continue }
            olderInARow = date < period.lowerBound ? olderInARow + 1 : 0
            if olderInARow >= Self.olderPhotosBeforeStopping {
                completion = Completion(periodStart: period.lowerBound, checked: checkedCount, reachedOlderPhotos: true)
                return
            }
        }
        if !Task.isCancelled, photos.count <= limit {
            completion = Completion(periodStart: period.lowerBound, checked: checkedCount, reachedOlderPhotos: false)
        }
    }

    /// The capture time the app knows for a photo: read from its original, from
    /// the Photos import history, or from the camera's media list.
    static func knownCaptureDate(of photo: LumixPhoto, in store: CameraGalleryStore) -> Date? {
        if case let .resolved(inspection)? = store.metadataInspectionState(for: photo), let date = inspection.exifCaptureDate {
            return date
        }
        return store.importHistoryRecord(for: photo)?.verifiedCaptureDate ?? photo.captureDate
    }

    struct PeriodPhoto: Identifiable {
        let photo: LumixPhoto
        let captureDate: Date
        var id: LumixPhoto.ID { photo.id }
    }

    /// Photos whose known capture time falls inside the period, newest first, and
    /// how many photos have no known time.
    static func photos(in period: ClosedRange<Date>, store: CameraGalleryStore) -> (inside: [PeriodPhoto], unknown: Int) {
        var inside: [PeriodPhoto] = []
        var unknown = 0
        for photo in store.photos where photo.kind == .photo {
            guard let date = knownCaptureDate(of: photo, in: store) else {
                unknown += 1
                continue
            }
            if period.contains(date) { inside.append(PeriodPhoto(photo: photo, captureDate: date)) }
        }
        return (inside.sorted { $0.captureDate > $1.captureDate }, unknown)
    }
}

// MARK: - Write screen

struct CameraGeotagWriteView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var store: CameraGalleryStore
    @StateObject private var writer: CameraGeotagWriter
    @StateObject private var verifier = CameraGeotagVerifier()
    @StateObject private var periodScanner = CameraGeotagPeriodScanner()
    private let camera: any CameraGeotagControlling
    private let samples: [LocationSample]
    @State private var support: CameraLocationWriteSupport = .unknown
    @State private var isCheckingSupport = true
    @State private var periodStart: Date
    @State private var periodEnd: Date
    @State private var isConfirming = false
    @State private var baseline: [LumixPhoto.ID: PhotoGeotagLocation?] = [:]
    @State private var writtenPeriod: ClosedRange<Date>?

    private let trackRange: ClosedRange<Date>?

    init(store: CameraGalleryStore, coordinator: CameraModeCoordinator, environment: CameraGeotagEnvironment) {
        self.store = store
        let camera = environment.makeCamera()
        self.camera = camera
        _writer = StateObject(wrappedValue: CameraGeotagWriter(camera: camera, coordinator: coordinator))
        let usable = LumixGeodata.usableSamples(environment.samples())
        samples = usable
        if let first = usable.first, let last = usable.last {
            trackRange = first.timestamp...last.timestamp
            let latest = LumixGeodata.segments(of: usable).last ?? usable
            _periodStart = State(initialValue: latest.first?.timestamp ?? first.timestamp)
            _periodEnd = State(initialValue: latest.last?.timestamp ?? last.timestamp)
        } else {
            trackRange = nil
            _periodStart = State(initialValue: Date())
            _periodEnd = State(initialValue: Date())
        }
    }

    private var period: ClosedRange<Date> { periodStart...max(periodStart, periodEnd) }

    private var selection: Result<CameraGeodataSelection, Error> {
        Result { try CameraGeodataSelection(samples: samples, period: period) }
    }

    var body: some View {
        NavigationStack {
            List {
                supportSection
                if trackRange == nil {
                    Section {
                        Label("No recorded location track", systemImage: "location.slash")
                        Text("Record a location track while shooting, or import Google Timeline data, before writing locations to camera photos.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    periodSection
                    effectSection
                    writeSection
                    if writtenPeriod != nil { verificationSection }
                }
            }
            .navigationTitle("Write locations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .disabled(writer.phase.isActive)
                }
            }
            .interactiveDismissDisabled(writer.phase.isActive || verifier.isRunning)
            .task { await checkSupport() }
            .onDisappear { periodScanner.cancel() }
            .onChange(of: scenePhase) { _, phase in
                // Only a real background transition suspends polling; `.inactive` is transient.
                if phase == .background { writer.setAppActive(false) }
                if phase == .active { writer.setAppActive(true) }
            }
            .onChange(of: writer.phase) { _, phase in
                if case .finished = phase { writtenPeriod = period }
            }
            .confirmationDialog("Write locations to photos on the card?", isPresented: $isConfirming, titleVisibility: .visible) {
                Button("Write locations", role: .destructive) { startWrite() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The camera will change the original files on its SD card. This cannot be undone from Retro LUMIX Sync. Use a disposable or backed-up card when trying this for the first time.")
            }
        }
    }

    // MARK: Sections

    private var supportSection: some View {
        Section("Camera") {
            if isCheckingSupport {
                HStack { ProgressView(); Text("Checking the camera…") }
            } else {
                switch support {
                case let .supported(evidence):
                    Label("Can write locations from the app", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(evidence).font(.caption).foregroundStyle(.secondary)
                case let .unsupported(reason):
                    Label("Location writing unavailable", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.orange)
                    Text(reason + " Some models only write uploaded locations from the camera's own menu.")
                        .font(.caption).foregroundStyle(.secondary)
                case .unknown:
                    Label("Could not check the camera", systemImage: "questionmark.circle")
                        .foregroundStyle(.orange)
                }
            }
        }
        .accessibilityIdentifier("geotag-write-support")
    }

    @ViewBuilder
    private var periodSection: some View {
        if let trackRange {
            Section {
                DatePicker("From", selection: $periodStart, in: trackRange)
                    .accessibilityIdentifier("geotag-period-start")
                DatePicker("To", selection: $periodEnd, in: periodStart...trackRange.upperBound)
                    .accessibilityIdentifier("geotag-period-end")
                HStack {
                    Button("Latest segment") { selectLatestSegment() }
                    Spacer()
                    Button("Whole track") {
                        periodStart = trackRange.lowerBound
                        periodEnd = trackRange.upperBound
                    }
                }
                .buttonStyle(.borderless)
                .font(.callout)
                periodSummary
            } header: {
                Text("Track period")
            } footer: {
                Text("Times are shown in this iPhone's current time zone. The track is uploaded with absolute (UTC) times.")
            }
        }
    }

    @ViewBuilder
    private var periodSummary: some View {
        switch selection {
        case let .success(selection):
            LabeledContent("Location samples", value: "\(selection.sampleCount)")
                .accessibilityIdentifier("geotag-sample-count")
            LabeledContent("Continuous segments", value: "\(selection.segmentCount)")
            LabeledContent("Upload size", value: "\(selection.records.count) records")
            Text(periodDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let warning = timeZoneWarning {
                Label(warning, systemImage: "clock.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        case let .failure(error):
            Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    private var effectSection: some View {
        Section("What the camera will change") {
            VStack(alignment: .leading, spacing: 8) {
                Text("The camera decides which photos receive a location by comparing each photo's capture time on its own clock with the uploaded track. Retro LUMIX Sync cannot choose individual photos.")
                Text("Panasonic excludes photos that already contain location information, AVCHD videos, photos taken after the location data is sent, and photos taken while the camera clock was not set.")
                Text("Behavior for RAW and RAW+JPEG files has not been verified.")
                Text("Before uploading, the app tells the camera this iPhone's current time. That does not change the camera's clock; use Set camera clock before shooting for that.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            LabeledContent("Camera photos with a known time in this period") {
                Text(photoEstimate).monospacedDigit()
            }
            .font(.callout)
            .accessibilityIdentifier("geotag-photo-estimate")
            captureTimeScan
            periodPhotoList
        }
    }

    @ViewBuilder
    private var captureTimeScan: some View {
        if periodScanner.isRunning {
            HStack {
                ProgressView()
                Text("Reading capture times from the card (\(periodScanner.checkedCount) photos checked)…")
            }
            .font(.caption)
            Button("Stop reading", role: .cancel) { periodScanner.cancel() }
        } else if let completion = periodScanner.completion, completion.covers(period) {
            let unknown = CameraGeotagPeriodScanner.photos(in: period, store: store).unknown
            Text(completion.reachedOlderPhotos && unknown > 0
                 ? "Read the newest \(completion.checked) photos. The other \(unknown) come before them on the card, so they are taken to be older than this period."
                 : "Read capture times from \(completion.checked) photos on the card.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("geotag-capture-time-scan-result")
        } else if CameraGeotagPeriodScanner.photos(in: period, store: store).unknown > 0 {
            Button {
                periodScanner.start(store: store, period: period)
            } label: {
                Label("Read capture times from the card", systemImage: "clock.arrow.circlepath")
            }
            .disabled(writer.phase.isActive || verifier.isRunning)
            .accessibilityIdentifier("geotag-read-capture-times")
            Text("The camera's media list does not include capture times for every photo. Reading them downloads the start of each original JPEG, newest first, until the photos are older than this period. Nothing on the card changes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var periodPhotoList: some View {
        let inside = CameraGeotagPeriodScanner.photos(in: period, store: store).inside
        if !inside.isEmpty {
            DisclosureGroup("Photos in this period (\(inside.count))") {
                ForEach(inside.prefix(50)) { entry in
                    LabeledContent(entry.photo.displayFilename) {
                        Text(entry.captureDate.formatted(date: .abbreviated, time: .standard))
                    }
                    .font(.caption)
                }
                if inside.count > 50 {
                    Text("and \(inside.count - 50) more").font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .accessibilityIdentifier("geotag-period-photos")
        }
    }

    @ViewBuilder
    private var writeSection: some View {
        Section {
            switch writer.phase {
            case .idle:
                Button {
                    isConfirming = true
                } label: {
                    Label("Write locations to camera photos…", systemImage: "mappin.and.ellipse")
                }
                .disabled(!support.isSupported || (try? selection.get()) == nil || isCheckingSupport || periodScanner.isRunning)
                .accessibilityIdentifier("geotag-write-start")
            case let .preparing(message):
                HStack { ProgressView(); Text(message) }
                stopButton
            case let .writing(progress, cameraState):
                if let progress {
                    ProgressView(value: Double(progress), total: 100) {
                        Text("The camera is writing locations (\(cameraState))")
                    }
                } else {
                    HStack { ProgressView(); Text("The camera is writing locations (\(cameraState))…") }
                }
                if writer.wasInterrupted {
                    Text("Progress was re-read after Retro LUMIX Sync returned to the foreground.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                stopButton
            case .cancelling:
                HStack { ProgressView(); Text("Waiting for the camera to stop…") }
            case let .finished(report):
                Label("The camera reports that it finished", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("geotag-write-finished")
                Text("This is the camera's own report. It does not prove that the photos contain the right GPS data; check them below. \(report.recordCount) records from \(report.sampleCount) samples were uploaded.")
                    .font(.caption).foregroundStyle(.secondary)
                if report.wasInterrupted {
                    Text("Retro LUMIX Sync was in the background while the camera was writing.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case let .cancelled(message):
                Label(message, systemImage: "stop.circle").foregroundStyle(.orange)
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    .accessibilityIdentifier("geotag-write-failed")
            }
        } footer: {
            if !writer.steps.isEmpty {
                Text(writer.steps.joined(separator: "\n")).font(.caption2.monospaced())
            }
        }
    }

    private var stopButton: some View {
        Button("Stop", role: .destructive) { writer.cancel() }
            .accessibilityIdentifier("geotag-write-stop")
    }

    @ViewBuilder
    private var verificationSection: some View {
        Section {
            if verifier.isRunning {
                ProgressView(value: Double(verifier.checkedCount), total: Double(max(1, verifier.candidateCount))) {
                    Text("Reading original JPEGs from the card (\(verifier.checkedCount) of \(verifier.candidateCount))")
                }
                Button("Stop checking", role: .cancel) { verifier.cancel() }
            } else {
                Button {
                    guard let writtenPeriod else { return }
                    verifier.start(store: store, period: writtenPeriod, samples: samples, baseline: baseline)
                } label: {
                    Label(verifier.results.isEmpty ? "Check photos in this period" : "Check again", systemImage: "checklist")
                }
                .accessibilityIdentifier("geotag-verify")
            }
            if !verifier.results.isEmpty {
                Text(verificationSummary).font(.callout)
                    .accessibilityIdentifier("geotag-verification-summary")
                ForEach(verifier.results) { result in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.filename).font(.callout.weight(.medium))
                        Text(statusText(result)).font(.caption)
                            .foregroundStyle(result.status.isProblem ? .orange : .secondary)
                    }
                }
            }
        } header: {
            Text("Verify on the card")
        } footer: {
            Text("Downloads the start of each original JPEG from the card and reads its EXIF GPS. Positions are compared with this app's own interpolation of the track, which may differ slightly from the camera's choice.\(verifier.skippedCount > 0 ? " \(verifier.skippedCount) older photos were not checked." : "")")
        }
    }

    // MARK: Text

    private var periodDescription: String {
        let formatter = DateIntervalFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let interval = formatter.string(from: period.lowerBound, to: period.upperBound)
        return "\(interval) (\(Self.utcOffsetLabel(TimeZone.current.secondsFromGMT(for: period.lowerBound))))"
    }

    /// The camera compares the track with its own clock. When the period was
    /// recorded under a different UTC offset than now (travel, daylight saving),
    /// the camera's time-zone settings may not match the photos.
    private var timeZoneWarning: String? {
        let now = TimeZone.current.secondsFromGMT(for: Date())
        let start = TimeZone.current.secondsFromGMT(for: period.lowerBound)
        let end = TimeZone.current.secondsFromGMT(for: period.upperBound)
        guard start != now || end != now else { return nil }
        return "This period was recorded at \(Self.utcOffsetLabel(start)), but this iPhone is now at \(Self.utcOffsetLabel(now)). Check that the camera's home time zone and daylight-saving setting matched when the photos were taken."
    }

    private var photoEstimate: String {
        let (inside, unknown) = CameraGeotagPeriodScanner.photos(in: period, store: store)
        if let completion = periodScanner.completion, completion.covers(period), completion.reachedOlderPhotos {
            // The unread photos precede the scanned ones on the card.
            return "\(inside.count)"
        }
        if inside.isEmpty, unknown > 0 { return "Unknown (\(unknown) without a known time)" }
        return unknown > 0 ? "\(inside.count) (+\(unknown) unknown)" : "\(inside.count)"
    }

    private var verificationSummary: String {
        let results = verifier.results
        let near = results.filter { if case .taggedNearTrack = $0.status { return true }; return false }.count
        let far = results.filter { if case .taggedFarFromTrack = $0.status { return true }; return false }.count
        let missing = results.filter { $0.status == .notTagged }.count
        let outsideChanged = results.filter { $0.status == .outsidePeriodTagged || $0.status == .alreadyTaggedChanged }.count
        return "In the period: \(near) tagged near the track, \(far) tagged far from it, \(missing) without GPS. Outside the period or already geotagged: \(outsideChanged) with unexpected GPS. Checked \(verifier.checkedCount) photos."
    }

    private func statusText(_ result: CameraGeotagVerificationResult) -> String {
        let time = result.captureDate.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "no capture time"
        switch result.status {
        case let .taggedNearTrack(distance): return "\(time) · GPS written, \(Int(distance.rounded())) m from the track"
        case let .taggedFarFromTrack(distance): return "\(time) · GPS written, but \(Int(distance.rounded())) m from the track"
        case .taggedWithoutTrackPosition: return "\(time) · GPS present; no track position to compare"
        case .notTagged: return "\(time) · In the period but no GPS"
        case .alreadyTaggedUnchanged: return "\(time) · Already geotagged before; unchanged"
        case .alreadyTaggedChanged: return "\(time) · Already geotagged before; GPS changed"
        case .outsidePeriodUntouched: return "\(time) · Outside the period; no GPS"
        case .outsidePeriodTagged: return "\(time) · Outside the period but has GPS (it may have had GPS before)"
        case let .unknownCaptureTime(hasLocation): return hasLocation ? "GPS present; capture time unreadable" : "No GPS; capture time unreadable"
        case let .failed(message): return "Could not check: \(message)"
        }
    }

    static func utcOffsetLabel(_ seconds: Int) -> String {
        let sign = seconds < 0 ? "−" : "+"
        let minutes = abs(seconds) / 60
        return String(format: "UTC%@%02d:%02d", sign, minutes / 60, minutes % 60)
    }

    // MARK: Actions

    private func selectLatestSegment() {
        guard let latest = LumixGeodata.segments(of: samples).last,
              let first = latest.first, let last = latest.last else { return }
        periodStart = first.timestamp
        periodEnd = last.timestamp
    }

    private func checkSupport() async {
        isCheckingSupport = true
        defer { isCheckingSupport = false }
        if let fetched = try? await camera.capabilityInfo() {
            support = CameraLocationWriteSupport.evaluate(fetched)
        } else {
            support = CameraLocationWriteSupport.evaluate(store.capabilities)
        }
    }

    private func startWrite() {
        guard case let .success(selection) = selection else { return }
        // Remember which photos were already known to carry GPS before the write.
        var known: [LumixPhoto.ID: PhotoGeotagLocation?] = [:]
        for photo in store.photos where photo.kind == .photo {
            if case let .resolved(inspection)? = store.metadataInspectionState(for: photo) {
                known[photo.id] = inspection.embeddedLocation
            }
        }
        baseline = known
        writer.start(selection)
    }
}

// MARK: - Clock screen

struct CameraClockSyncView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var synchronizer: CameraClockSynchronizer

    init(coordinator: CameraModeCoordinator, environment: CameraGeotagEnvironment) {
        _synchronizer = StateObject(wrappedValue: CameraClockSynchronizer(camera: environment.makeCamera(), coordinator: coordinator))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Sets the camera's date and time from this iPhone. Do this before shooting so photos are stamped with the right time. Panasonic's app offers this for the GM1S and similar models; some other models set the time automatically or reject this command.")
                        .font(.callout)
                    Text("This is separate from writing locations: before a track upload, the app only tells the camera the current time without changing its clock.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Camera clock") {
                    if let reading = synchronizer.lastReading {
                        LabeledContent("Camera reports", value: reading.raw)
                            .accessibilityIdentifier("camera-clock-reading")
                        if let difference = reading.difference(from: synchronizer.lastReadingAt ?? Date()) {
                            LabeledContent("Difference from this iPhone", value: Self.differenceLabel(difference))
                        }
                        Text("The difference assumes the camera reports UTC time plus its time zone, the format it accepts. Its reply format has not been verified on a GM1S.")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else if let problem = synchronizer.clockReadProblem {
                        Label(problem, systemImage: "clock.badge.questionmark")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("camera-clock-read-problem")
                    } else {
                        Button("Read camera clock") { Task { await synchronizer.readCameraClock() } }
                            .disabled(synchronizer.phase.isActive)
                    }
                    LabeledContent("Time zone sent", value: CameraGeotagWriteView.utcOffsetLabel(synchronizer.rawOffsetMinutes * 60))
                    if synchronizer.isDaylightSavingTime {
                        Label("Daylight saving time is in effect. The camera receives the standard offset, so turn on Daylight Saving in the camera's World Time setting, or its displayed time will be an hour off.", systemImage: "sun.max")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    switch synchronizer.phase {
                    case .idle, .cancelled, .failed:
                        Button {
                            synchronizer.start()
                        } label: {
                            Label("Set camera clock", systemImage: "clock.arrow.2.circlepath")
                        }
                        .accessibilityIdentifier("camera-clock-set")
                        if case let .failed(message) = synchronizer.phase {
                            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                        }
                        if synchronizer.phase == .cancelled {
                            Text("Cancelled. The camera clock was not changed.").font(.caption).foregroundStyle(.secondary)
                        }
                    case .reading:
                        HStack { ProgressView(); Text("Reading the camera…") }
                    case let .waiting(until):
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let remaining = max(0, Int(until.timeIntervalSince(context.date).rounded(.up)))
                            Text("Setting the clock at \(until.formatted(date: .omitted, time: .standard)) (in \(remaining) s)")
                                .monospacedDigit()
                        }
                        Button("Cancel", role: .cancel) { synchronizer.cancel() }
                    case .setting:
                        HStack { ProgressView(); Text("Setting the camera clock…") }
                    case let .finished(result):
                        Label("Camera clock set", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .accessibilityIdentifier("camera-clock-finished")
                        LabeledContent("Sent", value: result.sentValue)
                        if let difference = result.differenceAfter {
                            LabeledContent("Camera now differs by", value: Self.differenceLabel(difference))
                        } else {
                            Text("The camera's clock could not be read back. Check the time on the camera.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Set again") { synchronizer.start() }
                    }
                } footer: {
                    Text("The clock is set on the next whole minute, matching Panasonic's app. Photos taken before keep their old time; keep the camera clock adjustment for importing those.")
                }
            }
            .navigationTitle("Camera clock")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        synchronizer.cancel()
                        dismiss()
                    }
                }
            }
            .task { await synchronizer.readCameraClock() }
        }
    }

    static func differenceLabel(_ seconds: TimeInterval) -> String {
        let rounded = Int(seconds.rounded())
        if abs(rounded) < 2 { return "Under 2 seconds" }
        let direction = rounded > 0 ? "ahead" : "behind"
        let magnitude = abs(rounded)
        if magnitude < 120 { return "\(magnitude) s \(direction)" }
        return "\(magnitude / 60) min \(magnitude % 60) s \(direction)"
    }
}
