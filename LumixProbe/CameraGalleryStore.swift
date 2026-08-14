import Foundation

struct DownloadedPhoto: Equatable, Sendable {
    let fileURL: URL
    let captureDate: Date?
    let originalFilename: String
}

protocol CameraGalleryClient: Sendable {
    func prepareForBrowsing() async throws -> Int
    func browsePhotos(start: Int, count: Int) async throws -> LumixPhotoPage
    func downloadJPEGData(_ resource: LumixResource) async throws -> Data
    func download(_ resource: LumixResource) async throws -> URL
}

extension LumixClient: CameraGalleryClient {}

protocol CameraPhotoImporting: Sendable {
    func save(_ photo: DownloadedPhoto, geotag: GeotagMatch?) async throws
}

struct SystemCameraPhotoImporter: CameraPhotoImporting {
    func save(_ photo: DownloadedPhoto, geotag: GeotagMatch?) async throws {
        try await PhotosOriginalImporter.save(
            fileURL: photo.fileURL,
            originalFilename: photo.originalFilename,
            captureDate: photo.captureDate,
            location: geotag?.location
        )
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
    case failed(String)

    var isWorking: Bool {
        self == .downloading || self == .saving
    }
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

    private struct PageRequest: Equatable {
        let start: Int
        let count: Int
    }

    private let client: any CameraGalleryClient
    private let importer: any CameraPhotoImporting
    private let mediaCache: LumixMediaCache
    private let pageSize: Int
    private var nextPageRequest: PageRequest?
    private var loadGeneration = UUID()

    init(
        client: any CameraGalleryClient = LumixClient(),
        importer: any CameraPhotoImporting = SystemCameraPhotoImporter(),
        pageSize: Int = 20,
        mediaCacheByteLimit: Int = 24 * 1024 * 1024
    ) {
        self.client = client
        self.importer = importer
        self.pageSize = max(1, pageSize)
        mediaCache = LumixMediaCache(byteLimit: mediaCacheByteLimit)
    }

    init(
        previewPhase: CameraGalleryPhase,
        photos: [LumixPhoto] = [],
        totalCount: Int = 0
    ) {
        client = DemoCameraGalleryClient(total: max(totalCount, photos.count))
        importer = SystemCameraPhotoImporter()
        pageSize = 20
        mediaCache = LumixMediaCache(byteLimit: 1 * 1024 * 1024)
        phase = previewPhase
        self.photos = photos
        self.totalCount = max(totalCount, photos.count)
    }

    var canLoadMore: Bool { nextPageRequest != nil }

    var selectedPhotos: [LumixPhoto] {
        photos.filter { selectedPhotoIDs.contains($0.id) }
    }

    func loadInitial() async {
        let generation = UUID()
        loadGeneration = generation
        phase = .loading
        paginationError = nil
        nextPageRequest = nil
        photos = []
        totalCount = 0
        selectedPhotoIDs = []

        do {
            let reportedTotal = try await client.prepareForBrowsing()
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
            return
        } catch {
            guard loadGeneration == generation else { return }
            phase = .failed(error.localizedDescription)
            print("[GM1Sync] Gallery load failed: \(error.localizedDescription)")
        }
    }

    func loadNextPage() async {
        guard let request = nextPageRequest, !isLoadingNextPage else { return }
        isLoadingNextPage = true
        paginationError = nil
        defer { isLoadingNextPage = false }

        do {
            let page = try await client.browsePhotos(start: request.start, count: request.count)
            try Task.checkCancellation()
            totalCount = max(totalCount, page.totalMatches)
            merge(page.photos.reversed())
            nextPageRequest = previousPage(before: request.start)
            phase = photos.isEmpty && nextPageRequest == nil ? .empty : .loaded
            print("[GM1Sync] Gallery pagination loaded \(photos.count) of \(totalCount) camera items.")
        } catch is CancellationError {
            return
        } catch {
            paginationError = error.localizedDescription
            print("[GM1Sync] Gallery pagination failed: \(error.localizedDescription)")
        }
    }

    func loadAllPages() async {
        while nextPageRequest != nil, !Task.isCancelled {
            let requestBeforeLoad = nextPageRequest
            await loadNextPage()
            if paginationError != nil || nextPageRequest == requestBeforeLoad { return }
        }
    }

    func cancelLoading() {
        loadGeneration = UUID()
    }

    func mediaData(for resource: LumixResource) async throws -> Data {
        let client = self.client
        return try await mediaCache.data(for: resource.url) {
            try await client.downloadJPEGData(resource)
        }
    }

    func toggleSelection(_ photo: LumixPhoto) {
        if selectedPhotoIDs.contains(photo.id) {
            selectedPhotoIDs.remove(photo.id)
        } else {
            selectedPhotoIDs.insert(photo.id)
        }
    }

    func selectNewest(_ count: Int) {
        selectedPhotoIDs = Set(photos.prefix(max(0, count)).map(\.id))
    }

    func clearSelection() {
        selectedPhotoIDs = []
    }

    func importSelected(samples: [LocationSample], cameraClockOffset: TimeInterval) async {
        await importPhotos(selectedPhotos, samples: samples, cameraClockOffset: cameraClockOffset)
    }

    func importPhoto(_ photo: LumixPhoto, samples: [LocationSample], cameraClockOffset: TimeInterval) async {
        await importPhotos([photo], samples: samples, cameraClockOffset: cameraClockOffset)
    }

    private func importPhotos(
        _ photosToImport: [LumixPhoto],
        samples: [LocationSample],
        cameraClockOffset: TimeInterval
    ) async {
        guard !isImporting, !photosToImport.isEmpty else { return }
        isImporting = true
        batchProgress = CameraBatchProgress(
            total: photosToImport.count,
            completed: 0,
            saved: 0,
            failed: 0,
            currentTitle: nil
        )
        defer {
            isImporting = false
            batchProgress?.currentTitle = nil
        }

        for photo in photosToImport {
            if Task.isCancelled { break }
            batchProgress?.currentTitle = photo.title
            var temporaryFile: URL?

            do {
                guard let resource = photo.originalJPEGResource else { throw LumixError.noOriginalJPEG }
                importStates[photo.id] = .downloading
                let fileURL = try await client.download(resource)
                temporaryFile = fileURL
                let downloadedPhoto = DownloadedPhoto(
                    fileURL: fileURL,
                    captureDate: PhotoCaptureDateReader.read(from: fileURL),
                    originalFilename: resource.url.lastPathComponent.nonEmpty ?? "lumix-original.jpg"
                )
                let geotag = downloadedPhoto.captureDate.flatMap {
                    LocationTrackMatcher.match(
                        captureDate: $0,
                        samples: samples,
                        cameraClockOffset: cameraClockOffset
                    )
                }

                importStates[photo.id] = .saving
                try await importer.save(downloadedPhoto, geotag: geotag)
                importStates[photo.id] = .saved
                batchProgress?.saved += 1
                selectedPhotoIDs.remove(photo.id)
                print("[GM1Sync] Imported camera item \(photo.itemID ?? "unknown") to Photos.")
            } catch is CancellationError {
                importStates[photo.id] = .failed("Import cancelled")
                if let temporaryFile { try? FileManager.default.removeItem(at: temporaryFile) }
                break
            } catch {
                importStates[photo.id] = .failed(error.localizedDescription)
                batchProgress?.failed += 1
                print("[GM1Sync] Import failed for camera item \(photo.itemID ?? "unknown"): \(error.localizedDescription)")
            }

            if let temporaryFile { try? FileManager.default.removeItem(at: temporaryFile) }
            batchProgress?.completed += 1
        }
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
        }
        selectedPhotoIDs.formIntersection(existingIDs)
    }
}

private actor LumixMediaCache {
    private let byteLimit: Int
    private var cached: [URL: Data] = [:]
    private var recency: [URL] = []
    private var cachedBytes = 0
    private var inFlight: [URL: Task<Data, Error>] = [:]

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
        if let task = inFlight[url] { return try await task.value }

        let task = Task { try await loader() }
        inFlight[url] = task

        do {
            let value = try await task.value
            inFlight[url] = nil
            insert(value, for: url)
            return value
        } catch {
            inFlight[url] = nil
            throw error
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
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
