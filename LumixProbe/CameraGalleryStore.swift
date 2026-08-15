import Foundation

struct DownloadedPhoto: Equatable, Sendable {
    let fileURL: URL
    let captureDate: Date?
    let originalFilename: String
}

protocol CameraGalleryClient: Sendable {
    func prepareForBrowsing() async throws -> Int
    func fetchCapabilities() async throws -> CameraCapabilities
    func browsePhotos(start: Int, count: Int) async throws -> LumixPhotoPage
    func browseMetadata(itemID: String) async throws -> LumixPhoto
    func downloadJPEGData(_ resource: LumixResource) async throws -> Data
    func download(_ resource: LumixResource) async throws -> URL
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
    @Published private(set) var capabilities: CameraCapabilities?

    private struct PageRequest: Equatable {
        let start: Int
        let count: Int
    }

    private let clientProvider: @MainActor () -> any CameraGalleryClient
    private let sourceIdentifierProvider: @MainActor () -> String
    private var client: any CameraGalleryClient
    private let importer: any CameraMediaImporting
    private let importHistoryStore: any CameraImportHistoryStoring
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

    init(
        client: any CameraGalleryClient = LumixClient(),
        importer: any CameraMediaImporting = SystemCameraMediaImporter(),
        importHistoryStore: any CameraImportHistoryStoring = UserDefaultsCameraImportHistoryStore(),
        sourceIdentifier: String = "camera",
        pageSize: Int = 20,
        mediaCacheByteLimit: Int = 24 * 1024 * 1024
    ) {
        clientProvider = { client }
        sourceIdentifierProvider = { sourceIdentifier }
        self.client = client
        self.importer = importer
        self.importHistoryStore = importHistoryStore
        self.pageSize = max(1, pageSize)
        mediaCache = LumixMediaCache(byteLimit: mediaCacheByteLimit)
        loadImportHistory()
    }

    init(
        clientProvider: @escaping @MainActor () -> any CameraGalleryClient,
        sourceIdentifierProvider: @escaping @MainActor () -> String = { "camera" },
        importer: any CameraMediaImporting = SystemCameraMediaImporter(),
        importHistoryStore: any CameraImportHistoryStoring = UserDefaultsCameraImportHistoryStore(),
        pageSize: Int = 20,
        mediaCacheByteLimit: Int = 24 * 1024 * 1024
    ) {
        self.clientProvider = clientProvider
        self.sourceIdentifierProvider = sourceIdentifierProvider
        client = clientProvider()
        self.importer = importer
        self.importHistoryStore = importHistoryStore
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
    }

    func reloadAllMedia() async {
        await loadInitial()
        guard phase == .loaded else { return }
        await loadAllPages()
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
        await mediaCache.removeAll()
    }

    func mediaData(for resource: LumixResource) async throws -> Data {
        let client = self.client
        return try await mediaCache.data(for: resource.url) {
            try await client.downloadJPEGData(resource)
        }
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
                    try Task.checkCancellation()
                }

                let captureDate = downloadedResources
                    .lazy
                    .compactMap { PhotoCaptureDateReader.read(from: $0.fileURL) }
                    .first
                let downloadedMedia = DownloadedCameraMedia(
                    variant: plan.variant,
                    resources: downloadedResources,
                    captureDate: captureDate
                )
                failingFilename = downloadedResources
                    .map(\.originalFilename)
                    .joined(separator: " + ")
                let geotag = captureDate.flatMap {
                    LocationTrackMatcher.match(
                        captureDate: $0,
                        samples: samples,
                        cameraClockOffset: cameraClockOffset
                    )
                }

                importStates[photo.id] = .saving
                try await importer.save(downloadedMedia, geotag: geotag)
                try Task.checkCancellation()
                importStates[photo.id] = .saved
                recordImport(of: photo, variant: plan.variant)
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

    private func recordImport(of photo: LumixPhoto, variant: CameraImportVariant) {
        let key = historyKey(for: photo)
        var record = importHistory[key] ?? CameraImportHistoryRecord(
            variants: [],
            lastImportedAt: .now
        )
        record.variants.insert(variant)
        record.lastImportedAt = .now
        importHistory[key] = record

        do {
            try importHistoryStore.save(importHistory)
        } catch {
            print("[GM1Sync] Import history could not be saved: \(error.localizedDescription)")
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
