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
        let store = CameraGalleryStore(client: client, importer: importer, pageSize: 10)

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
}

private actor MockGalleryClient: CameraGalleryClient {
    struct BrowseRequest: Sendable {
        let start: Int
        let count: Int
    }

    private var total: Int
    private let overlapsPages: Bool
    private(set) var browseRequests: [BrowseRequest] = []

    init(total: Int, overlapsPages: Bool = false) {
        self.total = total
        self.overlapsPages = overlapsPages
    }

    func setTotal(_ total: Int) {
        self.total = total
    }

    func prepareForBrowsing() async throws -> Int { total }

    func browsePhotos(start: Int, count: Int) async throws -> LumixPhotoPage {
        browseRequests.append(BrowseRequest(start: start, count: count))
        let upperBound = min(total, start + count)
        var photos = start < upperBound ? (start..<upperBound).map(Self.photo) : []
        if overlapsPages, upperBound < total {
            photos.append(Self.photo(upperBound))
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

    private static func photo(_ index: Int) -> LumixPhoto {
        let itemID = String(index)
        let resource = LumixResource(
            itemID: itemID,
            title: "Photo \(index)",
            url: URL(string: "http://192.168.54.1:50001/photo-\(index).jpg")!,
            protocolInfo: "http-get:*:image/jpeg;PANASONIC.COM_PN=CAM_ORG"
        )
        return LumixPhoto(itemID: itemID, title: "Photo \(index)", resources: [resource])
    }
}

private actor RecordingImporter: CameraPhotoImporting {
    private(set) var filenames: [String] = []
    private let failingFilenames: Set<String>

    init(failingFilenames: Set<String> = []) {
        self.failingFilenames = failingFilenames
    }

    func save(_ photo: DownloadedPhoto, geotag: GeotagMatch?) async throws {
        filenames.append(photo.originalFilename)
        if failingFilenames.contains(photo.originalFilename) {
            throw TestImportError.configuredFailure
        }
    }
}

private enum TestImportError: LocalizedError {
    case configuredFailure

    var errorDescription: String? { "Configured import failure" }
}
