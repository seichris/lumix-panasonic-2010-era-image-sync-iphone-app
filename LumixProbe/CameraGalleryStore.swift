import Foundation

protocol CameraGalleryClient: Sendable {
    func prepareForBrowsing() async throws -> Int
    func fetchCapabilities() async throws -> CameraCapabilities
    func browsePhotos(start: Int, count: Int) async throws -> LumixPhotoPage
    func browseMetadata(itemID: String) async throws -> LumixPhoto
    func downloadJPEGData(_ resource: LumixResource) async throws -> Data
    func download(_ resource: LumixResource) async throws -> URL
    func downloadMetadataPrefix(_ resource: LumixResource) async throws -> URL
    func makeAVCHDPlaybackSession(
        for resource: LumixResource,
        availableResources: [LumixResource]
    ) async throws -> any CameraPlaybackSession
}

extension LumixClient: CameraGalleryClient {}

extension CameraGalleryClient {
    func fetchCapabilities() async throws -> CameraCapabilities {
        CameraCapabilities(model: nil, version: nil, date: nil, entries: [])
    }

    func browseMetadata(itemID: String) async throws -> LumixPhoto {
        throw LumixError.missingBrowseResult
    }

    func downloadMetadataPrefix(_ resource: LumixResource) async throws -> URL {
        try await download(resource)
    }

    func makeAVCHDPlaybackSession(
        for resource: LumixResource,
        availableResources: [LumixResource]
    ) async throws -> any CameraPlaybackSession {
        throw LumixError.videoPlaybackNotSupported
    }
}

enum CameraGalleryPhase: Equatable {
    case idle
    case loading
    case loaded
    case empty
    case failed(String)
}

enum CameraPhotoImportState: Equatable {
    case downloading
    case saving
    case saved
    case failed(CameraImportFailure)

    var isWorking: Bool {
        self == .downloading || self == .saving
    }
}

struct CameraImportFailure: Equatable, Sendable {
    let filename: String
    let message: String
}

struct CameraBatchProgress: Equatable {
    let total: Int
    var completed: Int
    var saved: Int
    var failed: Int
    var currentTitle: String?

    var fractionCompleted: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }

    var attempted: Int { saved + failed }
}

struct CameraPhotoMetadataInspection: Equatable, Sendable {
    let galleryCaptureDate: Date?
    let itemMetadataCaptureDate: Date?
    let exifCaptureDate: Date?
    let embeddedLocation: PhotoGeotagLocation?
    let itemMetadataError: String?

    var captureDateSource: String? {
        if exifCaptureDate != nil { return "Original JPEG EXIF" }
        if itemMetadataCaptureDate != nil { return "Camera metadata" }
        if galleryCaptureDate != nil { return "Camera gallery listing" }
        return nil
    }

    var diagnosticSummary: String {
        let gallery = galleryCaptureDate?.ISO8601Format() ?? "missing"
        let item = itemMetadataCaptureDate?.ISO8601Format() ?? "missing"
        let exif = exifCaptureDate?.ISO8601Format() ?? "missing"
        let gps = embeddedLocation.map { "\($0.latitude), \($0.longitude)" } ?? "missing"
        let metadataFailure = itemMetadataError.map { "; item metadata request: \($0)" } ?? ""
        return "Gallery time: \(gallery); item metadata time: \(item); JPEG EXIF time: \(exif); embedded GPS: \(gps)\(metadataFailure)"
    }
}

enum CameraPhotoMetadataInspectionStage: String, Equatable, Sendable {
    case requestingItemMetadata
    case downloadingOriginalJPEG
    case readingOriginalJPEG

    var title: String {
        switch self {
        case .requestingItemMetadata: "Checking photo metadata…"
        case .downloadingOriginalJPEG: "Downloading original JPEG metadata…"
        case .readingOriginalJPEG: "Reading original JPEG metadata…"
        }
    }
}

enum CameraPhotoMetadataInspectionState: Equatable, Sendable {
    case checking(CameraPhotoMetadataInspectionStage)
    case resolved(CameraPhotoMetadataInspection)
    case failed(String)
}

private enum CameraPhotoMetadataInspectionError: LocalizedError {
    case downloadTimedOut

    var errorDescription: String? {
        "The camera did not finish sending the original JPEG in time. Reconnect the camera Wi-Fi and try again."
    }
}

@MainActor
final class CameraGalleryStore: ObservableObject {
    @Published private(set) var phase: CameraGalleryPhase = .idle
    @Published private(set) var photos: [LumixPhoto] = []
    @Published private(set) var totalCount = 0
    @Published private(set) var isLoadingNextPage = false
    @Published private(set) var paginationError: String?
    @Published var selectedPhotoIDs: Set<LumixPhoto.ID> = []
    @Published private(set) var importStates: [LumixPhoto.ID: CameraPhotoImportState] = [:]
    @Published private(set) var batchProgress: CameraBatchProgress?
    @Published private(set) var isImporting = false
    @Published private(set) var importHistory: [String: CameraImportHistoryRecord] = [:]
    @Published private(set) var isReconcilingImportHistory = false
    @Published private(set) var importHistoryReconciliationError: String?
    @Published private(set) var hasCompletePhotoLibraryImportHistory = false
    @Published private(set) var capabilities: CameraCapabilities?
    @Published private(set) var metadataInspectionStates: [LumixPhoto.ID: CameraPhotoMetadataInspectionState] = [:]

    private struct PageRequest: Equatable {
        let start: Int
        let count: Int
    }

    private let clientProvider: @MainActor () -> any CameraGalleryClient
    private let sourceIdentifierProvider: @MainActor () -> String
    private var client: any CameraGalleryClient
    private let importer: any CameraMediaImporting
    private let importHistoryStore: any CameraImportHistoryStoring
    private let importReconciler: any CameraImportReconciling
    private let photoMetadataReader: @Sendable (URL) -> PhotoOriginalMetadata
    private let metadataInspectionDownloadTimeout: Duration
    private let mediaCache: LumixMediaCache
    private let pageSize: Int
    private var nextPageRequest: PageRequest?
    private var loadGeneration = UUID()
    private var initialLoadTask: Task<Void, Never>?
    private var initialLoadTaskID: UUID?
    private var paginationTask: Task<Void, Never>?
    private var paginationTaskID: UUID?
    private var importTask: Task<Void, Never>?
    private var importTaskID: UUID?
    private var sessionResetTask: Task<Void, Never>?
    private var sessionResetTaskID: UUID?
    private var reconciledImportFilenames: Set<String> = []
    private struct MetadataInspectionTask {
        let id: UUID
        let photo: LumixPhoto
        let onDiagnostic: @MainActor (String) -> Void
        let task: Task<CameraPhotoMetadataInspectionState, Never>
    }
    private var metadataInspectionTasks: [LumixPhoto.ID: MetadataInspectionTask] = [:]

    init(
        client: any CameraGalleryClient = LumixClient(),
        importer: any CameraMediaImporting = SystemCameraMediaImporter(),
        importHistoryStore: any CameraImportHistoryStoring = UserDefaultsCameraImportHistoryStore(),
        importReconciler: any CameraImportReconciling = NoopCameraImportReconciler(),
        sourceIdentifier: String = "camera",
        pageSize: Int = 20,
        mediaCacheByteLimit: Int = 24 * 1024 * 1024,
        metadataInspectionDownloadTimeout: Duration = .seconds(45),
        photoMetadataReader: @escaping @Sendable (URL) -> PhotoOriginalMetadata = {
            PhotoOriginalMetadataReader.read(from: $0)
        }
    ) {
        clientProvider = { client }
        sourceIdentifierProvider = { sourceIdentifier }
        self.client = client
        self.importer = importer
        self.importHistoryStore = importHistoryStore
        self.importReconciler = importReconciler
        self.photoMetadataReader = photoMetadataReader
        self.metadataInspectionDownloadTimeout = metadataInspectionDownloadTimeout
        self.pageSize = max(1, pageSize)
        mediaCache = LumixMediaCache(byteLimit: mediaCacheByteLimit)
        loadImportHistory()
    }

    init(
        clientProvider: @escaping @MainActor () -> any CameraGalleryClient,
        sourceIdentifierProvider: @escaping @MainActor () -> String = { "camera" },
        importer: any CameraMediaImporting = SystemCameraMediaImporter(),
        importHistoryStore: any CameraImportHistoryStoring = UserDefaultsCameraImportHistoryStore(),
        importReconciler: any CameraImportReconciling = NoopCameraImportReconciler(),
        pageSize: Int = 20,
        mediaCacheByteLimit: Int = 24 * 1024 * 1024,
        metadataInspectionDownloadTimeout: Duration = .seconds(45),
        photoMetadataReader: @escaping @Sendable (URL) -> PhotoOriginalMetadata = {
            PhotoOriginalMetadataReader.read(from: $0)
        }
    ) {
        self.clientProvider = clientProvider
        self.sourceIdentifierProvider = sourceIdentifierProvider
        client = clientProvider()
        self.importer = importer
        self.importHistoryStore = importHistoryStore
        self.importReconciler = importReconciler
        self.photoMetadataReader = photoMetadataReader
        self.metadataInspectionDownloadTimeout = metadataInspectionDownloadTimeout
        self.pageSize = max(1, pageSize)
        mediaCache = LumixMediaCache(byteLimit: mediaCacheByteLimit)
        loadImportHistory()
    }

    init(
        previewPhase: CameraGalleryPhase,
        photos: [LumixPhoto] = [],
        totalCount: Int = 0
    ) {
        let previewClient = DemoCameraGalleryClient(total: max(totalCount, photos.count))
        clientProvider = { previewClient }
        sourceIdentifierProvider = { "preview-camera" }
        client = previewClient
        importer = SystemCameraMediaImporter()
        importHistoryStore = InMemoryCameraImportHistoryStore()
        importReconciler = NoopCameraImportReconciler()
        photoMetadataReader = { PhotoOriginalMetadataReader.read(from: $0) }
        metadataInspectionDownloadTimeout = .seconds(45)
        pageSize = 20
        mediaCache = LumixMediaCache(byteLimit: 1 * 1024 * 1024)
        phase = previewPhase
        self.photos = photos
        self.totalCount = max(totalCount, photos.count)
    }

    var canLoadMore: Bool { nextPageRequest != nil }

    var hasCompleteMediaCounts: Bool {
        phase == .loaded && !canLoadMore && !isLoadingNextPage && paginationError == nil
    }

    var imageCount: Int { photos.lazy.filter { $0.kind == .photo }.count }
    var videoCount: Int { photos.lazy.filter { $0.kind == .video }.count }
    var metadataInspectionTimeoutSeconds: Int {
        max(1, Int(metadataInspectionDownloadTimeout.timeInterval.rounded(.up)))
    }

    var failedPhotos: [LumixPhoto] {
        photos.filter { photo in
            guard case .failed = importStates[photo.id] else { return false }
            return true
        }
    }

    var selectedPhotos: [LumixPhoto] {
        photos.filter { selectedPhotoIDs.contains($0.id) }
    }

    private var mediaPolicy: CameraMediaPolicy {
        CameraMediaPolicy(capabilities: capabilities)
    }

    func importHistoryRecord(for photo: LumixPhoto) -> CameraImportHistoryRecord? {
        importHistory[historyKey(for: photo)]
    }

    func metadataInspectionState(for photo: LumixPhoto) -> CameraPhotoMetadataInspectionState? {
        metadataInspectionStates[photo.id]
    }

    func isPreviouslyImported(_ photo: LumixPhoto) -> Bool {
        importHistoryRecord(for: photo) != nil
    }

    func canImportSelected(using mode: CameraPhotoImportMode) -> Bool {
        !selectedPhotos.isEmpty && selectedPhotos.allSatisfy { canImport($0, using: mode) }
    }

    func canImport(_ photo: LumixPhoto, using mode: CameraPhotoImportMode = .jpeg) -> Bool {
        mediaPolicy.supportsImport(of: photo, photoMode: mode)
    }

    func loadInitial() async {
        if let sessionResetTask { await sessionResetTask.value }
        cancelMetadataInspections(
            failureMessage: "The metadata check was interrupted when the camera gallery refreshed. Try again."
        )
        let generation = UUID()
        let taskID = UUID()
        loadGeneration = generation
        initialLoadTask?.cancel()
        paginationTask?.cancel()
        paginationTask = nil
        paginationTaskID = nil
        client = clientProvider()
        phase = .loading
        isLoadingNextPage = false
        paginationError = nil
        nextPageRequest = nil
        photos = []
        totalCount = 0
        capabilities = nil
        selectedPhotoIDs = []
        let client = self.client

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let reportedTotal = try await client.prepareForBrowsing()
                try Task.checkCancellation()
                guard loadGeneration == generation else { return }

                do {
                    capabilities = try await client.fetchCapabilities()
                    print("[GM1Sync] Loaded \(capabilities?.entries.count ?? 0) camera media capability entries.")
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    capabilities = nil
                    print("[GM1Sync] Camera capabilities unavailable: \(error.localizedDescription)")
                }
                try Task.checkCancellation()
                guard loadGeneration == generation else { return }

                guard reportedTotal > 0 else {
                    phase = .empty
                    return
                }

                let count = min(pageSize, reportedTotal)
                let start = max(0, reportedTotal - count)
                let page = try await client.browsePhotos(start: start, count: count)
                try Task.checkCancellation()
                guard loadGeneration == generation else { return }

                totalCount = max(reportedTotal, page.totalMatches)
                merge(page.photos.reversed())
                nextPageRequest = previousPage(before: start)
                phase = photos.isEmpty && nextPageRequest == nil ? .empty : .loaded
                print("[GM1Sync] Gallery loaded \(photos.count) of \(totalCount) camera items.")
            } catch is CancellationError {
                if loadGeneration == generation { phase = .idle }
            } catch {
                guard loadGeneration == generation else { return }
                phase = .failed(error.localizedDescription)
                print("[GM1Sync] Gallery load failed: \(error.localizedDescription)")
            }
        }
        initialLoadTaskID = taskID
        initialLoadTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if initialLoadTaskID == taskID {
            initialLoadTask = nil
            initialLoadTaskID = nil
        }
    }

    func loadNextPage() async {
        if let paginationTask {
            let taskID = paginationTaskID
            await paginationTask.value
            if paginationTaskID == taskID {
                self.paginationTask = nil
                paginationTaskID = nil
            }
            return
        }
        guard let request = nextPageRequest else { return }
        let generation = loadGeneration
        let taskID = UUID()
        let client = self.client
        isLoadingNextPage = true
        paginationError = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if loadGeneration == generation { isLoadingNextPage = false }
            }

            do {
                let page = try await client.browsePhotos(start: request.start, count: request.count)
                try Task.checkCancellation()
                guard loadGeneration == generation else { return }
                totalCount = max(totalCount, page.totalMatches)
                merge(page.photos.reversed())
                nextPageRequest = previousPage(before: request.start)
                phase = photos.isEmpty && nextPageRequest == nil ? .empty : .loaded
                print("[GM1Sync] Gallery pagination loaded \(photos.count) of \(totalCount) camera items.")
            } catch is CancellationError {
                return
            } catch {
                guard loadGeneration == generation else { return }
                paginationError = error.localizedDescription
                print("[GM1Sync] Gallery pagination failed: \(error.localizedDescription)")
            }
        }
        paginationTaskID = taskID
        paginationTask = task
        await task.value
        if paginationTaskID == taskID {
            paginationTask = nil
            paginationTaskID = nil
        }
    }

    func loadAllPages() async {
        while nextPageRequest != nil, !Task.isCancelled {
            let requestBeforeLoad = nextPageRequest
            await loadNextPage()
            if paginationError != nil || nextPageRequest == requestBeforeLoad { return }
        }
        if paginationError == nil { await reconcileImportHistoryWithPhotos() }
    }

    func reloadAllMedia() async {
        await loadInitial()
        guard phase == .loaded else { return }
        await loadAllPages()
    }

    func reconcileImportHistoryWithPhotos() async {
        guard !isReconcilingImportHistory else { return }

        let candidates = photos.filter { !isPreviouslyImported($0) }
        let candidateFilenames = candidates.reduce(into: Set<String>()) { result, photo in
            result.formUnion(photo.importFilenames)
        }
        let uncheckedFilenames = candidateFilenames.subtracting(reconciledImportFilenames)
        guard !uncheckedFilenames.isEmpty else {
            if candidateFilenames.isSubset(of: reconciledImportFilenames) {
                hasCompletePhotoLibraryImportHistory = importHistoryReconciliationError == nil
            }
            return
        }

        isReconcilingImportHistory = true
        importHistoryReconciliationError = nil
        defer { isReconcilingImportHistory = false }

        do {
            let result = try await importReconciler.importedFilenames(matching: uncheckedFilenames)
            recoverImportHistory(for: candidates, matchedFilenames: result.matchedFilenames)
            if result.hasCompleteLibraryAccess {
                reconciledImportFilenames.formUnion(uncheckedFilenames)
                hasCompletePhotoLibraryImportHistory = true
            } else {
                hasCompletePhotoLibraryImportHistory = false
                importHistoryReconciliationError =
                    "GM1 Sync has limited Photos access. Allow Full Access so it can reliably identify every new camera item."
            }
        } catch {
            hasCompletePhotoLibraryImportHistory = false
            importHistoryReconciliationError = error.localizedDescription
            print("[GM1Sync] Photos import-history reconciliation failed: \(error.localizedDescription)")
        }
    }

    func cancelLoading() {
        loadGeneration = UUID()
        initialLoadTask?.cancel()
        initialLoadTask = nil
        initialLoadTaskID = nil
        paginationTask?.cancel()
        paginationTask = nil
        paginationTaskID = nil
        isLoadingNextPage = false
        if phase == .loading { phase = .idle }
    }

    func resetForReconnect() async {
        if let sessionResetTask {
            await sessionResetTask.value
            return
        }
        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await performReconnectReset()
        }
        sessionResetTaskID = taskID
        sessionResetTask = task
        await task.value
        if sessionResetTaskID == taskID {
            sessionResetTask = nil
            sessionResetTaskID = nil
        }
    }

    private func performReconnectReset() async {
        cancelLoading()
        let activeImport = importTask
        importTask?.cancel()
        await activeImport?.value
        importTask = nil
        importTaskID = nil
        isImporting = false
        phase = .idle
        photos = []
        totalCount = 0
        capabilities = nil
        nextPageRequest = nil
        paginationError = nil
        selectedPhotoIDs = []
        importStates = [:]
        batchProgress = nil
        cancelMetadataInspections(clearStates: true)
        await mediaCache.removeAll()
    }

    private func cancelMetadataInspections(
        clearStates: Bool = false,
        failureMessage: String? = nil
    ) {
        for (photoID, inspection) in metadataInspectionTasks {
            inspection.task.cancel()
            if let failureMessage {
                metadataInspectionStates[photoID] = .failed(failureMessage)
                recordMetadataDiagnostic(
                    "Photo geotag check \(inspection.photo.displayFilename) was interrupted: \(failureMessage)",
                    onDiagnostic: inspection.onDiagnostic
                )
            }
        }
        metadataInspectionTasks = [:]
        if clearStates { metadataInspectionStates = [:] }
    }

    func mediaData(for resource: LumixResource) async throws -> Data {
        let client = self.client
        return try await mediaCache.data(for: resource.url) {
            try await client.downloadJPEGData(resource)
        }
    }

    func waitForMediaLoadsToFinish(maximumWait: Duration = .seconds(8)) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: maximumWait)
        while await mediaCache.hasInFlightRequests {
            guard !Task.isCancelled, clock.now < deadline else { return }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
        }
    }

    @discardableResult
    func inspectOriginalMetadata(
        for photo: LumixPhoto,
        force: Bool = false,
        onDiagnostic: @escaping @MainActor (String) -> Void = { _ in }
    ) async -> CameraPhotoMetadataInspectionState {
        if force, let existing = metadataInspectionTasks[photo.id] {
            existing.task.cancel()
            _ = await existing.task.value
            if metadataInspectionTasks[photo.id]?.id == existing.id {
                metadataInspectionTasks[photo.id] = nil
            }
        } else {
            if let existing = metadataInspectionTasks[photo.id] {
                if metadataInspectionStates[photo.id] == nil {
                    updateMetadataInspection(
                        photo,
                        stage: .requestingItemMetadata,
                        onDiagnostic: onDiagnostic
                    )
                }
                return await existing.task.value
            }
            if let cached = metadataInspectionStates[photo.id] {
                return cached
            }
        }

        guard photo.kind == .photo else {
            let state = CameraPhotoMetadataInspectionState.failed("Metadata inspection is only available for photos.")
            metadataInspectionStates[photo.id] = state
            return state
        }

        // Publish the request before creating the shared task. This guarantees that
        // the detail UI and diagnostic log leave their idle state immediately, even
        // if SwiftUI cancels the view task before the camera operation is scheduled.
        updateMetadataInspection(
            photo,
            stage: .requestingItemMetadata,
            onDiagnostic: onDiagnostic
        )

        let taskID = UUID()
        let generation = loadGeneration
        let client = self.client
        let task = Task { @MainActor [weak self] in
            guard let self else {
                return CameraPhotoMetadataInspectionState.failed("Metadata inspection stopped.")
            }
            return await performOriginalMetadataInspection(
                for: photo,
                generation: generation,
                client: client,
                onDiagnostic: onDiagnostic
            )
        }
        metadataInspectionTasks[photo.id] = MetadataInspectionTask(
            id: taskID,
            photo: photo,
            onDiagnostic: onDiagnostic,
            task: task
        )
        let state = await task.value
        if metadataInspectionTasks[photo.id]?.id == taskID {
            metadataInspectionTasks[photo.id] = nil
        }
        return state
    }

    private func performOriginalMetadataInspection(
        for photo: LumixPhoto,
        generation: UUID,
        client: any CameraGalleryClient,
        onDiagnostic: @escaping @MainActor (String) -> Void
    ) async -> CameraPhotoMetadataInspectionState {
        var itemMetadataCaptureDate: Date?
        var itemMetadataError: String?
        var detailedPhoto: LumixPhoto?

        if let itemID = photo.itemID {
            if metadataInspectionStates[photo.id] != .checking(.requestingItemMetadata) {
                updateMetadataInspection(
                    photo,
                    stage: .requestingItemMetadata,
                    onDiagnostic: onDiagnostic
                )
            }
            do {
                detailedPhoto = try await client.browseMetadata(itemID: itemID)
                try Task.checkCancellation()
                itemMetadataCaptureDate = detailedPhoto?.captureDate
            } catch is CancellationError {
                return cancelMetadataInspection(photo, generation: generation)
            } catch {
                itemMetadataError = error.localizedDescription
                recordMetadataDiagnostic(
                    "Photo geotag check \(photo.displayFilename): camera item metadata unavailable: \(error.localizedDescription)",
                    onDiagnostic: onDiagnostic
                )
            }
        }

        guard loadGeneration == generation else {
            return cancelMetadataInspection(photo, generation: generation)
        }

        guard let original = detailedPhoto?.originalJPEGResource ?? photo.originalJPEGResource else {
            return failMetadataInspection(
                photo,
                message: "The camera did not advertise an original JPEG for this item.",
                onDiagnostic: onDiagnostic
            )
        }

        updateMetadataInspection(
            photo,
            stage: .downloadingOriginalJPEG,
            onDiagnostic: onDiagnostic
        )
        let downloadStartedAt = Date()
        let advertisedSize = original.size.map { "\($0) bytes" } ?? "unknown size"
        recordMetadataDiagnostic(
            "Photo geotag check \(photo.displayFilename): starting bounded JPEG metadata-prefix transfer " +
                "(up to 512 KiB; 12-second socket inactivity timeout) " +
                "from \(original.downloadURL.absoluteString), advertised \(advertisedSize), " +
                "timeout \(metadataInspectionTimeoutSeconds) seconds.",
            onDiagnostic: onDiagnostic
        )
        do {
            let timeout = metadataInspectionDownloadTimeout
            let fileURL = try await withCameraMetadataTimeout(
                timeout,
                label: photo.displayFilename
            ) {
                try await client.downloadMetadataPrefix(original)
            }
            defer { try? FileManager.default.removeItem(at: fileURL) }
            try Task.checkCancellation()
            guard loadGeneration == generation else { throw CancellationError() }
            let elapsed = Date().timeIntervalSince(downloadStartedAt)
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            let downloadedSize = (attributes?[.size] as? NSNumber)?.int64Value
            recordMetadataDiagnostic(
                "Photo geotag check \(photo.displayFilename): JPEG metadata-prefix transfer completed " +
                    "with \(downloadedSize.map(String.init) ?? "unknown") bytes in \(elapsed.secondsLabel).",
                onDiagnostic: onDiagnostic
            )
            updateMetadataInspection(
                photo,
                stage: .readingOriginalJPEG,
                onDiagnostic: onDiagnostic
            )
            let reader = photoMetadataReader
            let originalMetadata = await Task.detached(priority: .userInitiated) {
                reader(fileURL)
            }.value
            try Task.checkCancellation()
            guard loadGeneration == generation else { throw CancellationError() }

            let inspection = CameraPhotoMetadataInspection(
                galleryCaptureDate: photo.captureDate,
                itemMetadataCaptureDate: itemMetadataCaptureDate,
                exifCaptureDate: originalMetadata.captureDate,
                embeddedLocation: originalMetadata.embeddedLocation,
                itemMetadataError: itemMetadataError
            )
            let state = CameraPhotoMetadataInspectionState.resolved(inspection)
            metadataInspectionStates[photo.id] = state
            recordMetadataDiagnostic(
                "Photo geotag check \(photo.displayFilename): \(inspection.diagnosticSummary)",
                onDiagnostic: onDiagnostic
            )
            recordMetadataDiagnostic(
                "Photo geotag check \(photo.displayFilename): final UI state = resolved.",
                onDiagnostic: onDiagnostic
            )
            return state
        } catch is CancellationError {
            recordMetadataDiagnostic(
                "Photo geotag check \(photo.displayFilename): metadata-prefix catch = CancellationError; " +
                    "final UI state = cancelled.",
                onDiagnostic: onDiagnostic
            )
            return cancelMetadataInspection(photo, generation: generation)
        } catch {
            let elapsed = Date().timeIntervalSince(downloadStartedAt)
            recordMetadataDiagnostic(
                "Photo geotag check \(photo.displayFilename): metadata-prefix catch type=" +
                    "\(String(reflecting: type(of: error))) message=\(error.localizedDescription).",
                onDiagnostic: onDiagnostic
            )
            return failMetadataInspection(
                photo,
                message: "Could not inspect the original JPEG after \(elapsed.secondsLabel): \(error.localizedDescription)",
                onDiagnostic: onDiagnostic
            )
        }
    }

    private func updateMetadataInspection(
        _ photo: LumixPhoto,
        stage: CameraPhotoMetadataInspectionStage,
        onDiagnostic: @MainActor (String) -> Void
    ) {
        metadataInspectionStates[photo.id] = .checking(stage)
        recordMetadataDiagnostic(
            "Photo geotag check \(photo.displayFilename): \(stage.title)",
            onDiagnostic: onDiagnostic
        )
    }

    private func failMetadataInspection(
        _ photo: LumixPhoto,
        message: String,
        onDiagnostic: @MainActor (String) -> Void
    ) -> CameraPhotoMetadataInspectionState {
        let state = CameraPhotoMetadataInspectionState.failed(message)
        metadataInspectionStates[photo.id] = state
        recordMetadataDiagnostic(
            "Photo geotag check \(photo.displayFilename): final UI state = failed: \(message)",
            onDiagnostic: onDiagnostic
        )
        return state
    }

    private func cancelMetadataInspection(
        _ photo: LumixPhoto,
        generation: UUID
    ) -> CameraPhotoMetadataInspectionState {
        if loadGeneration == generation {
            metadataInspectionStates[photo.id] = nil
        }
        return .failed("Metadata inspection cancelled.")
    }

    private func recordMetadataDiagnostic(
        _ message: String,
        onDiagnostic: @MainActor (String) -> Void
    ) {
        print("[GM1Sync] \(message)")
        onDiagnostic(message)
    }

    func videoPlaybackSession(_ photo: LumixPhoto) async throws -> any CameraPlaybackSession {
        var playbackPhoto = photo
        if photo.videoPlaybackResource?.isAVCHD == true, let itemID = photo.itemID {
            do {
                playbackPhoto = try await client.browseMetadata(itemID: itemID)
                print("[GM1Sync] Loaded AVCHD metadata with \(playbackPhoto.resources.count) resources for item \(itemID).")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                print("[GM1Sync] AVCHD BrowseMetadata failed; using direct resource set: \(error.localizedDescription)")
            }
        }

        guard let resource = playbackPhoto.videoPlaybackResource else { throw LumixError.noVideo }
        guard mediaPolicy.supportsPlayback(of: resource) else {
            throw LumixError.videoPlaybackNotSupported
        }
        print(
            "[GM1Sync] Preparing playback resource item=\(photo.itemID ?? "unknown") " +
                "role=\(resource.role.rawValue) profile=\(resource.profileName ?? "unknown") " +
                "url=\(resource.url.absoluteString)"
        )
        let client = self.client
        if resource.isAVCHD {
            return try await client.makeAVCHDPlaybackSession(
                for: resource,
                availableResources: playbackPhoto.resources
            )
        }
        return DownloadedCameraPlaybackSession {
            try await client.download(resource)
        }
    }

    func toggleSelection(_ photo: LumixPhoto) {
        if selectedPhotoIDs.contains(photo.id) {
            selectedPhotoIDs.remove(photo.id)
        } else {
            guard isSelectableForImport(photo) else { return }
            selectedPhotoIDs.insert(photo.id)
        }
    }

    func selectNewest(_ count: Int) {
        selectedPhotoIDs = Set(photos.filter(isSelectableForImport).prefix(max(0, count)).map(\.id))
    }

    func selectAll() {
        selectedPhotoIDs = Set(photos.filter(isSelectableForImport).map(\.id))
    }

    private func isSelectableForImport(_ photo: LumixPhoto) -> Bool {
        if photo.kind == .video { return mediaPolicy.importResource(for: photo) != nil }
        return photo.isImportable
    }

    @discardableResult
    func selectUnimported() -> Int {
        selectedPhotoIDs = Set(
            photos
                .filter { isSelectableForImport($0) && !isPreviouslyImported($0) }
                .map(\.id)
        )
        return selectedPhotoIDs.count
    }

    func clearSelection() {
        selectedPhotoIDs = []
    }

    func importSelected(
        photoMode: CameraPhotoImportMode = .jpeg,
        samples: [LocationSample],
        cameraClockOffset: TimeInterval
    ) async {
        await importPhotos(
            selectedPhotos,
            photoMode: photoMode,
            samples: samples,
            cameraClockOffset: cameraClockOffset
        )
    }

    func importPhoto(
        _ photo: LumixPhoto,
        photoMode: CameraPhotoImportMode = .jpeg,
        samples: [LocationSample],
        cameraClockOffset: TimeInterval
    ) async {
        await importPhotos(
            [photo],
            photoMode: photoMode,
            samples: samples,
            cameraClockOffset: cameraClockOffset
        )
    }

    private func importPhotos(
        _ photosToImport: [LumixPhoto],
        photoMode: CameraPhotoImportMode,
        samples: [LocationSample],
        cameraClockOffset: TimeInterval
    ) async {
        guard !isImporting, !photosToImport.isEmpty else { return }
        let taskID = UUID()
        let client = self.client
        isImporting = true
        batchProgress = CameraBatchProgress(
            total: photosToImport.count,
            completed: 0,
            saved: 0,
            failed: 0,
            currentTitle: nil
        )
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await performImport(
                photosToImport,
                photoMode: photoMode,
                samples: samples,
                cameraClockOffset: cameraClockOffset,
                client: client
            )
        }
        importTaskID = taskID
        importTask = task
        await task.value
        if importTaskID == taskID {
            importTask = nil
            importTaskID = nil
            isImporting = false
            batchProgress?.currentTitle = nil
        }
    }

    private func performImport(
        _ photosToImport: [LumixPhoto],
        photoMode: CameraPhotoImportMode,
        samples: [LocationSample],
        cameraClockOffset: TimeInterval,
        client: any CameraGalleryClient
    ) async {
        for photo in photosToImport {
            if Task.isCancelled { break }
            batchProgress?.currentTitle = photo.title
            var temporaryFiles: [URL] = []
            var failingFilename = photo.displayFilename

            do {
                let plan = try photo.importPlan(photoMode: photoMode, policy: mediaPolicy)
                importStates[photo.id] = .downloading
                var downloadedResources: [DownloadedCameraMedia.Resource] = []
                var originalMetadata: PhotoOriginalMetadata?

                for plannedResource in plan.resources {
                    failingFilename = plannedResource.cameraResource.downloadURL.lastPathComponent.nonEmpty
                        ?? photo.displayFilename
                    let fileURL = try await client.download(plannedResource.cameraResource)
                    temporaryFiles.append(fileURL)
                    downloadedResources.append(
                        DownloadedCameraMedia.Resource(
                            fileURL: fileURL,
                            originalFilename: plannedResource.cameraResource.downloadURL.lastPathComponent.nonEmpty
                                ?? "lumix-media",
                            role: plannedResource.role
                        )
                    )
                    if plannedResource.cameraResource.isOriginalJPEG {
                        let reader = photoMetadataReader
                        originalMetadata = await Task.detached(priority: .userInitiated) {
                            reader(fileURL)
                        }.value
                    }
                    try Task.checkCancellation()
                }

                let captureDate = originalMetadata?.captureDate ?? downloadedResources
                    .lazy
                    .compactMap { PhotoCaptureDateReader.read(from: $0.fileURL) }
                    .first
                let downloadedMedia = DownloadedCameraMedia(
                    variant: plan.variant,
                    resources: downloadedResources,
                    captureDate: captureDate,
                    embeddedLocation: originalMetadata?.embeddedLocation
                )
                failingFilename = downloadedResources
                    .map(\.originalFilename)
                    .joined(separator: " + ")
                let geotag = originalMetadata?.embeddedLocation == nil ? captureDate.flatMap {
                    LocationTrackMatcher.match(
                        captureDate: $0,
                        samples: samples,
                        cameraClockOffset: cameraClockOffset
                    )
                } : nil

                importStates[photo.id] = .saving
                try await importer.save(downloadedMedia, geotag: geotag)
                try Task.checkCancellation()
                importStates[photo.id] = .saved
                recordImport(
                    of: photo,
                    variant: plan.variant,
                    verifiedCaptureDate: captureDate,
                    appliedLocation: originalMetadata?.embeddedLocation ?? geotag.map {
                        PhotoGeotagLocation(match: $0)
                    }
                )
                batchProgress?.saved += 1
                selectedPhotoIDs.remove(photo.id)
                print(
                    "[GM1Sync] Imported camera item \(photo.itemID ?? "unknown") " +
                        "to Photos as \(plan.variant.title)."
                )
            } catch is CancellationError {
                importStates[photo.id] = .failed(
                    CameraImportFailure(filename: failingFilename, message: "Import cancelled")
                )
                for fileURL in temporaryFiles { try? FileManager.default.removeItem(at: fileURL) }
                break
            } catch {
                importStates[photo.id] = .failed(
                    CameraImportFailure(filename: failingFilename, message: error.localizedDescription)
                )
                batchProgress?.failed += 1
                print("[GM1Sync] Import failed for camera item \(photo.itemID ?? "unknown"): \(error.localizedDescription)")
            }

            for fileURL in temporaryFiles { try? FileManager.default.removeItem(at: fileURL) }
            batchProgress?.completed += 1
        }
    }

    private func loadImportHistory() {
        do {
            importHistory = try importHistoryStore.load()
        } catch {
            importHistory = [:]
            print("[GM1Sync] Import history could not be loaded: \(error.localizedDescription)")
        }
    }

    private func recordImport(
        of photo: LumixPhoto,
        variant: CameraImportVariant,
        verifiedCaptureDate: Date?,
        appliedLocation: PhotoGeotagLocation?
    ) {
        let key = historyKey(for: photo)
        var record = importHistory[key] ?? CameraImportHistoryRecord(
            variants: [],
            lastImportedAt: .now
        )
        record.variants.insert(variant)
        record.lastImportedAt = .now
        record.evidence = .appImport
        if let verifiedCaptureDate { record.verifiedCaptureDate = verifiedCaptureDate }
        if let appliedLocation { record.appliedLocation = appliedLocation }
        importHistory[key] = record

        do {
            try importHistoryStore.save(importHistory)
        } catch {
            print("[GM1Sync] Import history could not be saved: \(error.localizedDescription)")
        }
    }

    private func recoverImportHistory(
        for candidates: [LumixPhoto],
        matchedFilenames: Set<String>
    ) {
        let matches = Set(matchedFilenames.map(CameraImportFilename.normalized))
        guard !matches.isEmpty else { return }
        var recoveredCount = 0

        for photo in candidates {
            let photoMatches = photo.importFilenames.intersection(matches)
            guard !photoMatches.isEmpty else { continue }
            let variant: CameraImportVariant
            if photo.kind == .video {
                variant = .video
            } else {
                let jpegFilename = photo.originalJPEGResource.map {
                    CameraImportFilename.normalized($0.downloadURL.lastPathComponent)
                }
                let rawFilename = photo.rawResource.map {
                    CameraImportFilename.normalized($0.downloadURL.lastPathComponent)
                }
                let hasJPEG = jpegFilename.map(photoMatches.contains) ?? false
                let hasRAW = rawFilename.map(photoMatches.contains) ?? false
                variant = hasJPEG && hasRAW ? .jpegAndRAW : (hasRAW ? .raw : .jpeg)
            }

            importHistory[historyKey(for: photo)] = CameraImportHistoryRecord(
                variants: [variant],
                lastImportedAt: .now,
                evidence: .photosLibrary
            )
            recoveredCount += 1
        }

        guard recoveredCount > 0 else { return }
        do {
            try importHistoryStore.save(importHistory)
            print("[GM1Sync] Recovered \(recoveredCount) camera imports from the Photos library.")
        } catch {
            print("[GM1Sync] Recovered import history could not be saved: \(error.localizedDescription)")
        }
    }

    private func historyKey(for photo: LumixPhoto) -> String {
        [sourceIdentifierProvider(), photo.importIdentity].joined(separator: "|")
    }

    private func previousPage(before start: Int) -> PageRequest? {
        guard start > 0 else { return nil }
        let previousStart = max(0, start - pageSize)
        return PageRequest(start: previousStart, count: min(pageSize, start))
    }

    private func merge<S: Sequence>(_ newPhotos: S) where S.Element == LumixPhoto {
        var existingIDs = Set(photos.map(\.id))
        for photo in newPhotos where existingIDs.insert(photo.id).inserted {
            photos.append(photo)
            if photo.kind == .video {
                for resource in photo.resources where resource.isVideo {
                    print(
                        "[GM1Sync] Video resource item=\(photo.itemID ?? "unknown") " +
                            "profile=\(resource.profileName ?? "unknown") " +
                            "mime=\(resource.mimeType ?? "unknown") url=\(resource.url.absoluteString)"
                    )
                }
            }
        }
        selectedPhotoIDs.formIntersection(existingIDs)
    }
}

private let cameraMetadataTimeoutQueue = DispatchQueue(
    label: "com.web3.gm1sync.metadata-timeout",
    qos: .userInitiated
)

private let cameraMetadataCancellationQueue = DispatchQueue(
    label: "com.web3.gm1sync.metadata-cancellation",
    qos: .userInitiated,
    attributes: .concurrent
)

private func withCameraMetadataTimeout<Value: Sendable>(
    _ timeout: Duration,
    label: String,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let gate = CameraMetadataTimeoutGate<Value>()
    let operationTask = Task.detached(priority: .userInitiated, operation: operation)
    let timeoutWorkItem = DispatchWorkItem {
        print("[GM1Sync] [MetadataTimeout \(label)] timeout fired.")
        let won = gate.resume(.failure(CameraPhotoMetadataInspectionError.downloadTimedOut))
        print("[GM1Sync] [MetadataTimeout \(label)] gate resume source=timeout won=\(won).")

        // Deliver the timeout before touching cancellation or socket teardown.
        // Swift invokes a task's cancellation handler synchronously from cancel(),
        // so cleanup must not sit on the timeout's critical wake-up path.
        cameraMetadataCancellationQueue.async {
            print("[GM1Sync] [MetadataTimeout \(label)] operationTask.cancel enter (timeout).")
            operationTask.cancel()
            print("[GM1Sync] [MetadataTimeout \(label)] operationTask.cancel exit (timeout).")
        }
    }
    cameraMetadataTimeoutQueue.asyncAfter(
        deadline: .now() + max(0, timeout.timeInterval),
        execute: timeoutWorkItem
    )

    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            gate.install(continuation)

            Task.detached {
                let result = await operationTask.result
                timeoutWorkItem.cancel()
                let won = gate.resume(result)
                print("[GM1Sync] [MetadataTimeout \(label)] gate resume source=operation won=\(won).")
            }
        }
    } onCancel: {
        timeoutWorkItem.cancel()
        let won = gate.resume(.failure(CancellationError()))
        print("[GM1Sync] [MetadataTimeout \(label)] gate resume source=parent-cancellation won=\(won).")
        cameraMetadataCancellationQueue.async {
            print("[GM1Sync] [MetadataTimeout \(label)] operationTask.cancel enter (parent cancellation).")
            operationTask.cancel()
            print("[GM1Sync] [MetadataTimeout \(label)] operationTask.cancel exit (parent cancellation).")
        }
    }
}

private final class CameraMetadataTimeoutGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pendingResult: Result<Value, Error>?
    private var isFinished = false

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if isFinished {
            let result = pendingResult
            pendingResult = nil
            lock.unlock()
            if let result { continuation.resume(with: result) }
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    @discardableResult
    func resume(_ result: Result<Value, Error>) -> Bool {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return false
        }
        isFinished = true
        let continuation = continuation
        self.continuation = nil
        if continuation == nil { pendingResult = result }
        lock.unlock()
        continuation?.resume(with: result)
        return true
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}

private extension TimeInterval {
    var secondsLabel: String {
        String(format: "%.1f seconds", self)
    }
}

private actor LumixMediaCache {
    private struct InFlightRequest {
        let task: Task<Data, Error>
        var waiters: Set<UUID>
    }

    private let byteLimit: Int
    private let loadLimiter = LumixMediaLoadLimiter(limit: 3)
    private var cached: [URL: Data] = [:]
    private var recency: [URL] = []
    private var cachedBytes = 0
    private var inFlight: [URL: InFlightRequest] = [:]

    init(byteLimit: Int) {
        self.byteLimit = max(0, byteLimit)
    }

    var hasInFlightRequests: Bool { !inFlight.isEmpty }

    func data(
        for url: URL,
        loader: @escaping @Sendable () async throws -> Data
    ) async throws -> Data {
        if let value = cached[url] {
            touch(url)
            return value
        }
        let waiterID = UUID()
        let task: Task<Data, Error>

        if var request = inFlight[url] {
            request.waiters.insert(waiterID)
            inFlight[url] = request
            task = request.task
        } else {
            let limiter = loadLimiter
            task = Task {
                try await limiter.load(loader)
            }
            inFlight[url] = InFlightRequest(task: task, waiters: [waiterID])
        }

        return try await withTaskCancellationHandler {
            do {
                let value = try await task.value
                try Task.checkCancellation()
                finishRequest(for: url, waiterID: waiterID, value: value)
                return value
            } catch {
                finishRequest(for: url, waiterID: waiterID, value: nil)
                throw error
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID, for: url) }
        }
    }

    private func finishRequest(for url: URL, waiterID: UUID, value: Data?) {
        guard var request = inFlight[url] else { return }
        request.waiters.remove(waiterID)

        if let value {
            inFlight[url] = nil
            insert(value, for: url)
        } else if request.waiters.isEmpty {
            inFlight[url] = nil
        } else {
            inFlight[url] = request
        }
    }

    private func cancelWaiter(_ waiterID: UUID, for url: URL) {
        guard var request = inFlight[url], request.waiters.remove(waiterID) != nil else { return }
        if request.waiters.isEmpty {
            inFlight[url] = nil
            request.task.cancel()
        } else {
            inFlight[url] = request
        }
    }

    private func insert(_ data: Data, for url: URL) {
        guard data.count <= byteLimit else { return }
        if let previous = cached[url] { cachedBytes -= previous.count }
        cached[url] = data
        cachedBytes += data.count
        touch(url)

        while cachedBytes > byteLimit, let oldest = recency.first {
            recency.removeFirst()
            if let removed = cached.removeValue(forKey: oldest) { cachedBytes -= removed.count }
        }
    }

    private func touch(_ url: URL) {
        recency.removeAll { $0 == url }
        recency.append(url)
    }

    func removeAll() {
        for request in inFlight.values { request.task.cancel() }
        inFlight = [:]
        cached = [:]
        recency = []
        cachedBytes = 0
    }
}

private actor LumixMediaLoadLimiter {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let limit: Int
    private var available: Int
    private var waiters: [Waiter] = []

    init(limit: Int) {
        self.limit = max(1, limit)
        available = max(1, limit)
    }

    func load(_ operation: @escaping @Sendable () async throws -> Data) async throws -> Data {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if available > 0 {
            available -= 1
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if waiters.isEmpty {
            available = min(limit, available + 1)
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
