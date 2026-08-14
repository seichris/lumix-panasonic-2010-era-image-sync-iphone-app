import Foundation
import XCTest
@testable import GM1Sync

@MainActor
final class CameraGalleryStoreTests: XCTestCase {
    func testLoadsEveryPageNewestFirstWithoutDuplicates() async throws {
        let client = MockGalleryClient(total: 41, overlapsPages: true)
        let store = CameraGalleryStore(client: client, importer: RecordingImporter(), pageSize: 10)

        await store.loadInitial()
        await store.loadAllPages()

        XCTAssertEqual(store.phase, .loaded)
        XCTAssertEqual(store.totalCount, 41)
        XCTAssertEqual(store.photos.count, 41)
        XCTAssertEqual(Set(store.photos.map(\.id)).count, 41)
        XCTAssertEqual(store.photos.first?.itemID, "40")
        XCTAssertEqual(store.photos.last?.itemID, "0")
        XCTAssertFalse(store.canLoadMore)

        let requests = await client.browseRequests
        XCTAssertEqual(requests.map(\.start), [31, 21, 11, 1, 0])
        XCTAssertEqual(requests.map(\.count), [10, 10, 10, 10, 1])
    }

    func testTenItemImportContinuesAfterOneFailure() async throws {
        let client = MockGalleryClient(total: 10)
        let importer = RecordingImporter(failingFilenames: ["photo-4.jpg"])
        let store = CameraGalleryStore(
            client: client,
            importer: importer,
            importHistoryStore: InMemoryCameraImportHistoryStore(),
            pageSize: 10
        )

        await store.loadInitial()
        store.selectNewest(10)
        await store.importSelected(samples: [], cameraClockOffset: 0)

        let progress = try XCTUnwrap(store.batchProgress)
        XCTAssertEqual(progress.total, 10)
        XCTAssertEqual(progress.completed, 10)
        XCTAssertEqual(progress.saved, 9)
        XCTAssertEqual(progress.failed, 1)
        XCTAssertFalse(store.isImporting)
        XCTAssertEqual(store.selectedPhotoIDs.count, 1)

        let imported = await importer.filenames
        XCTAssertEqual(imported.count, 10)
        let failedPhoto = try XCTUnwrap(store.photos.first { $0.itemID == "4" })
        guard case .failed = store.importStates[failedPhoto.id] else {
            return XCTFail("Expected the configured item to report a failure")
        }
    }

    func testRefreshReplacesStaleStateAndSelection() async {
        let client = MockGalleryClient(total: 3)
        let store = CameraGalleryStore(client: client, importer: RecordingImporter(), pageSize: 2)

        await store.loadInitial()
        store.selectNewest(1)
        await client.setTotal(1)
        await store.loadInitial()

        XCTAssertEqual(store.photos.count, 1)
        XCTAssertEqual(store.photos.first?.itemID, "0")
        XCTAssertTrue(store.selectedPhotoIDs.isEmpty)
    }

    func testRefreshIgnoresAnOlderPageThatFinishesLate() async {
        let client = MockGalleryClient(total: 4)
        let store = CameraGalleryStore(client: client, importer: RecordingImporter(), pageSize: 2)

        await store.loadInitial()
        await client.delayNextBrowse(start: 0)
        let stalePage = Task { await store.loadNextPage() }
        let staleRequestStarted = await waitUntil { await client.browseRequests.count == 2 }
        XCTAssertTrue(staleRequestStarted)

        await client.setTotal(1)
        await store.loadInitial()
        await stalePage.value

        XCTAssertEqual(store.totalCount, 1)
        XCTAssertEqual(store.photos.map(\.itemID), ["0"])
        XCTAssertFalse(store.canLoadMore)
        XCTAssertFalse(store.isLoadingNextPage)
    }

    func testLoadAllWaitsForAutomaticPaginationThenFinishesEveryPage() async {
        let client = MockGalleryClient(total: 5)
        let store = CameraGalleryStore(client: client, importer: RecordingImporter(), pageSize: 2)

        await store.loadInitial()
        await client.delayNextBrowse(start: 1)
        let automaticPage = Task { await store.loadNextPage() }
        let automaticRequestStarted = await waitUntil { await client.browseRequests.count == 2 }
        XCTAssertTrue(automaticRequestStarted)

        await store.loadAllPages()
        await automaticPage.value

        XCTAssertEqual(store.photos.map(\.itemID), ["4", "3", "2", "1", "0"])
        XCTAssertFalse(store.canLoadMore)
        let requests = await client.browseRequests
        XCTAssertEqual(requests.map(\.start), [3, 1, 0])
    }

    func testCancelLoadingCancelsTheUnderlyingPaginationRequest() async {
        let client = MockGalleryClient(total: 4)
        let store = CameraGalleryStore(client: client, importer: RecordingImporter(), pageSize: 2)

        await store.loadInitial()
        await client.delayNextBrowse(start: 0, duration: .seconds(30))
        let page = Task { await store.loadNextPage() }
        let requestStarted = await waitUntil { await client.browseRequests.count == 2 }
        XCTAssertTrue(requestStarted)

        store.cancelLoading()
        await page.value

        let cancellationCount = await client.browseCancellationCount
        XCTAssertEqual(cancellationCount, 1)
        XCTAssertFalse(store.isLoadingNextPage)
    }

    func testRefreshCancelsStalePaginationAndLoadAllUsesTheNewCursor() async {
        let client = MockGalleryClient(total: 5)
        let store = CameraGalleryStore(client: client, importer: RecordingImporter(), pageSize: 2)

        await store.loadInitial()
        await client.delayNextBrowse(start: 1, duration: .seconds(30))
        let stalePage = Task { await store.loadNextPage() }
        let staleRequestStarted = await waitUntil { await client.browseRequests.count == 2 }
        XCTAssertTrue(staleRequestStarted)

        await store.loadInitial()
        await store.loadAllPages()
        await stalePage.value

        let cancellationCount = await client.browseCancellationCount
        XCTAssertEqual(cancellationCount, 1)
        XCTAssertEqual(store.photos.map(\.itemID), ["4", "3", "2", "1", "0"])
        XCTAssertFalse(store.canLoadMore)
    }

    func testCancellingInitialLoadReturnsStoreToIdleForReentry() async {
        let client = MockGalleryClient(total: 2, preparationDelay: .seconds(5))
        let store = CameraGalleryStore(client: client, importer: RecordingImporter())
        let load = Task { await store.loadInitial() }
        let started = await waitUntil { store.phase == .loading }
        XCTAssertTrue(started)

        store.cancelLoading()
        load.cancel()
        await load.value

        XCTAssertEqual(store.phase, .idle)
    }

    func testEachRefreshUsesTheCurrentClientProvider() async {
        let first = MockGalleryClient(total: 3)
        let second = MockGalleryClient(total: 1)
        var currentClient: any CameraGalleryClient = first
        let store = CameraGalleryStore(
            clientProvider: { currentClient },
            importer: RecordingImporter(),
            pageSize: 5
        )

        await store.loadInitial()
        XCTAssertEqual(store.photos.count, 3)

        currentClient = second
        await store.loadInitial()

        XCTAssertEqual(store.totalCount, 1)
        XCTAssertEqual(store.photos.map(\.itemID), ["0"])
    }

    func testReconnectResetClearsThePreviousCameraSession() async {
        let first = MockGalleryClient(total: 3)
        let second = MockGalleryClient(total: 1)
        var currentClient: any CameraGalleryClient = first
        let store = CameraGalleryStore(
            clientProvider: { currentClient },
            importer: RecordingImporter(),
            pageSize: 5
        )

        await store.loadInitial()
        store.selectNewest(2)
        await store.resetForReconnect()

        XCTAssertEqual(store.phase, .idle)
        XCTAssertTrue(store.photos.isEmpty)
        XCTAssertTrue(store.selectedPhotoIDs.isEmpty)

        currentClient = second
        await store.loadInitial()
        XCTAssertEqual(store.photos.map(\.itemID), ["0"])
    }

    func testReconnectResetCancelsImportAndRemovesItsTemporaryFile() async throws {
        let client = MockGalleryClient(total: 1)
        let importer = CancellableImporter()
        let store = CameraGalleryStore(
            client: client,
            importer: importer,
            importHistoryStore: InMemoryCameraImportHistoryStore(),
            pageSize: 1
        )

        await store.loadInitial()
        let photo = try XCTUnwrap(store.photos.first)
        let importOperation = Task {
            await store.importPhoto(photo, samples: [], cameraClockOffset: 0)
        }
        let saveStarted = await waitUntil { await importer.isSaving }
        XCTAssertTrue(saveStarted)
        let importedFileURL = await importer.fileURL
        let temporaryFile = try XCTUnwrap(importedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryFile.path))

        await store.resetForReconnect()
        await importOperation.value

        let cancellationCount = await importer.cancellationCount
        XCTAssertEqual(cancellationCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryFile.path))
        XCTAssertFalse(store.isImporting)
        XCTAssertNil(store.batchProgress)
        XCTAssertTrue(store.importStates.isEmpty)
    }

    func testJPEGAndRAWImportDownloadsBothResourcesAndRecordsHistory() async throws {
        let client = MockGalleryClient(total: 1, includesRAW: true)
        let importer = RecordingImporter()
        let historyStore = InMemoryCameraImportHistoryStore()
        let store = CameraGalleryStore(
            client: client,
            importer: importer,
            importHistoryStore: historyStore,
            sourceIdentifier: "GM1S-TEST",
            pageSize: 1
        )

        await store.loadInitial()
        let photo = try XCTUnwrap(store.photos.first)
        await store.importPhoto(
            photo,
            photoMode: .jpegAndRAW,
            samples: [],
            cameraClockOffset: 0
        )

        let packages = await importer.packages
        XCTAssertEqual(packages.count, 1)
        XCTAssertEqual(packages[0].variant, .jpegAndRAW)
        XCTAssertEqual(packages[0].filenames, ["photo-0.jpg", "photo-0.RW2"])
        XCTAssertEqual(packages[0].roles, [.photo, .alternatePhoto])
        XCTAssertEqual(store.importHistoryRecord(for: photo)?.variants, [.jpegAndRAW])
        XCTAssertTrue(store.isPreviouslyImported(photo))
    }

    func testSelectUnimportedExcludesPreviouslyImportedItemsAfterReload() async throws {
        let client = MockGalleryClient(total: 3)
        let historyStore = InMemoryCameraImportHistoryStore()
        let firstStore = CameraGalleryStore(
            client: client,
            importer: RecordingImporter(),
            importHistoryStore: historyStore,
            sourceIdentifier: "GM1S-TEST",
            pageSize: 3
        )

        await firstStore.loadInitial()
        let importedPhoto = try XCTUnwrap(firstStore.photos.first)
        await firstStore.importPhoto(importedPhoto, samples: [], cameraClockOffset: 0)

        let reloadedStore = CameraGalleryStore(
            client: client,
            importer: RecordingImporter(),
            importHistoryStore: historyStore,
            sourceIdentifier: "GM1S-TEST",
            pageSize: 3
        )
        await reloadedStore.loadInitial()
        reloadedStore.selectUnimported()

        XCTAssertTrue(reloadedStore.isPreviouslyImported(importedPhoto))
        XCTAssertEqual(reloadedStore.selectedPhotoIDs.count, 2)
        XCTAssertFalse(reloadedStore.selectedPhotoIDs.contains(importedPhoto.id))
    }

    func testMediaLoadingIsBoundedAndCancellationReachesTheClient() async throws {
        let client = CancellableMediaClient()
        let store = CameraGalleryStore(client: client, importer: RecordingImporter())
        let resources = (0..<5).map(Self.resource)
        let loads = resources.map { resource in
            Task { try await store.mediaData(for: resource) }
        }

        let reachedLimit = await waitUntil { await client.activeDownloads == 3 }
        XCTAssertTrue(reachedLimit)
        let maximumActiveDownloads = await client.maximumActiveDownloads
        XCTAssertEqual(maximumActiveDownloads, 3)

        loads.forEach { $0.cancel() }
        for load in loads { _ = try? await load.value }

        let allStopped = await waitUntil { await client.activeDownloads == 0 }
        XCTAssertTrue(allStopped)
        let cancellationCount = await client.cancellationCount
        XCTAssertEqual(cancellationCount, 3)
    }

    private static func resource(_ index: Int) -> LumixResource {
        LumixResource(
            itemID: String(index),
            title: "Photo \(index)",
            url: URL(string: "http://192.168.54.1:50001/photo-\(index).jpg")!,
            protocolInfo: "http-get:*:image/jpeg;PANASONIC.COM_PN=CAM_TN"
        )
    }

    private func waitUntil(_ condition: @escaping () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

private actor MockGalleryClient: CameraGalleryClient {
    struct BrowseRequest: Sendable {
        let start: Int
        let count: Int
    }

    private var total: Int
    private let overlapsPages: Bool
    private let preparationDelay: Duration
    private let includesRAW: Bool
    private var delayedBrowseStart: Int?
    private var delayedBrowseDuration: Duration = .milliseconds(250)
    private(set) var browseRequests: [BrowseRequest] = []
    private(set) var browseCancellationCount = 0

    init(
        total: Int,
        overlapsPages: Bool = false,
        preparationDelay: Duration = .zero,
        includesRAW: Bool = false
    ) {
        self.total = total
        self.overlapsPages = overlapsPages
        self.preparationDelay = preparationDelay
        self.includesRAW = includesRAW
    }

    func setTotal(_ total: Int) {
        self.total = total
    }

    func delayNextBrowse(start: Int, duration: Duration = .milliseconds(250)) {
        delayedBrowseStart = start
        delayedBrowseDuration = duration
    }

    func prepareForBrowsing() async throws -> Int {
        if preparationDelay > .zero { try await Task.sleep(for: preparationDelay) }
        return total
    }

    func browsePhotos(start: Int, count: Int) async throws -> LumixPhotoPage {
        browseRequests.append(BrowseRequest(start: start, count: count))
        let total = self.total
        if delayedBrowseStart == start {
            delayedBrowseStart = nil
            do {
                try await Task.sleep(for: delayedBrowseDuration)
            } catch is CancellationError {
                browseCancellationCount += 1
                throw CancellationError()
            }
        }
        let upperBound = min(total, start + count)
        var photos = start < upperBound ? (start..<upperBound).map(photo) : []
        if overlapsPages, upperBound < total {
            photos.append(photo(upperBound))
        }
        return LumixPhotoPage(
            startIndex: start,
            numberReturned: photos.count,
            totalMatches: total,
            photos: photos
        )
    }

    func downloadJPEGData(_ resource: LumixResource) async throws -> Data {
        Data([0xff, 0xd8, 0xff, 0xd9])
    }

    func download(_ resource: LumixResource) async throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-" + resource.url.lastPathComponent)
        try Data([0xff, 0xd8, 0xff, 0xd9]).write(to: destination)
        return destination
    }

    private func photo(_ index: Int) -> LumixPhoto {
        let itemID = String(index)
        let resource = LumixResource(
            itemID: itemID,
            title: "Photo \(index)",
            url: URL(string: "http://192.168.54.1:50001/photo-\(index).jpg")!,
            protocolInfo: "http-get:*:image/jpeg;PANASONIC.COM_PN=CAM_ORG"
        )
        var resources = [resource]
        if includesRAW {
            resources.append(
                LumixResource(
                    itemID: itemID,
                    title: "Photo \(index)",
                    url: URL(string: "http://192.168.54.1:50001/photo-\(index).RW2")!,
                    protocolInfo: "http-get:*:application/octet-stream;PANASONIC.COM_PN=CAM_RAW"
                )
            )
        }
        return LumixPhoto(itemID: itemID, title: "Photo \(index)", resources: resources)
    }
}

private actor CancellableMediaClient: CameraGalleryClient {
    private(set) var activeDownloads = 0
    private(set) var maximumActiveDownloads = 0
    private(set) var cancellationCount = 0

    func prepareForBrowsing() async throws -> Int { 0 }

    func browsePhotos(start: Int, count: Int) async throws -> LumixPhotoPage {
        LumixPhotoPage(startIndex: start, numberReturned: 0, totalMatches: 0, photos: [])
    }

    func downloadJPEGData(_ resource: LumixResource) async throws -> Data {
        activeDownloads += 1
        maximumActiveDownloads = max(maximumActiveDownloads, activeDownloads)
        defer { activeDownloads -= 1 }

        do {
            try await Task.sleep(for: .seconds(30))
            return Data([0xff, 0xd8, 0xff, 0xd9])
        } catch is CancellationError {
            cancellationCount += 1
            throw CancellationError()
        }
    }

    func download(_ resource: LumixResource) async throws -> URL {
        throw TestImportError.configuredFailure
    }
}

private actor RecordingImporter: CameraMediaImporting {
    struct Package: Sendable {
        let variant: CameraImportVariant
        let filenames: [String]
        let roles: [CameraImportPlan.Resource.Role]
    }

    private(set) var filenames: [String] = []
    private(set) var packages: [Package] = []
    private let failingFilenames: Set<String>

    init(failingFilenames: Set<String> = []) {
        self.failingFilenames = failingFilenames
    }

    func save(_ media: DownloadedCameraMedia, geotag: GeotagMatch?) async throws {
        let mediaFilenames = media.resources.map(\.originalFilename)
        filenames.append(contentsOf: mediaFilenames)
        packages.append(
            Package(
                variant: media.variant,
                filenames: mediaFilenames,
                roles: media.resources.map(\.role)
            )
        )
        if !failingFilenames.isDisjoint(with: mediaFilenames) {
            throw TestImportError.configuredFailure
        }
    }
}

private actor CancellableImporter: CameraMediaImporting {
    private(set) var isSaving = false
    private(set) var cancellationCount = 0
    private(set) var fileURL: URL?

    func save(_ media: DownloadedCameraMedia, geotag: GeotagMatch?) async throws {
        fileURL = media.resources.first?.fileURL
        isSaving = true
        defer { isSaving = false }

        do {
            try await Task.sleep(for: .seconds(30))
        } catch is CancellationError {
            cancellationCount += 1
            throw CancellationError()
        }
    }
}

private enum TestImportError: LocalizedError {
    case configuredFailure

    var errorDescription: String? { "Configured import failure" }
}
