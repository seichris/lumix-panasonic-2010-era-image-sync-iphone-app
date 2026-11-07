import Foundation
import XCTest
@testable import GM1Sync

@MainActor
final class CameraGalleryStoreTests: XCTestCase {
    func testShortCameraRepliesStillLoadEveryItemNewestFirst() async {
        let client = MockGalleryClient(total: 11, maximumReturnedCount: 2)
        let store = CameraGalleryStore(client: client, pageSize: 5)

        await store.reloadAllMedia()

        XCTAssertEqual(store.photos.compactMap(\.itemID), (0..<11).reversed().map(String.init))
        XCTAssertTrue(store.hasCompleteMediaCounts)
    }

    func testZeroProgressOnANonemptyPageOffersARetry() async {
        let client = MockGalleryClient(total: 4, maximumReturnedCount: 0)
        let store = CameraGalleryStore(client: client, pageSize: 4)
        await store.reloadAllMedia()
        guard case .failed = store.phase else { return XCTFail("Expected a recoverable browse failure") }
        XCTAssertFalse(store.hasCompleteMediaCounts)
    }

    func testBulkImportUsesAnAvailableOriginalForEachItem() async {
        let client = MockGalleryClient(total: 3, rawOnlyIndexes: [1], videoIndexes: [2])
        let importer = RecordingImporter()
        let store = CameraGalleryStore(client: client, importer: importer,
                                      importHistoryStore: InMemoryCameraImportHistoryStore())
        await store.reloadAllMedia()
        XCTAssertEqual(store.selectUnimported(), 3)
        await store.importSelected(photoMode: .jpegAndRAW, allowFormatFallback: true, samples: [], cameraClockOffset: 0)
        let packages = await importer.packages
        XCTAssertEqual(packages.map(\.variant), [.video, .raw, .jpeg])
        XCTAssertEqual(store.batchProgress?.failed, 0)
    }

    func testLateThumbnailCannotReplaceTheNextCamerasThumbnailAtTheSameURL() async throws {
        let first = MockGalleryClient(total: 1, holdThumbnails: true)
        let second = MockGalleryClient(total: 1, holdThumbnails: true)
        var client = first
        let store = CameraGalleryStore(clientProvider: { client })
        let resource = Self.resource(0)
        let oldLoad = Task { try await store.mediaData(for: resource) }
        let oldStarted = await waitUntil { await first.thumbnailIsWaiting }
        XCTAssertTrue(oldStarted)
        await store.resetForReconnect()
        client = second
        await store.loadInitial()
        let newLoad = Task { try await store.mediaData(for: resource) }
        let newStarted = await waitUntil { await second.thumbnailIsWaiting }
        XCTAssertTrue(newStarted)
        await first.finishThumbnail(with: Data([1]))
        do {
            _ = try await oldLoad.value
            XCTFail("Returned a thumbnail from the disconnected camera")
        } catch is CancellationError {}
        await second.finishThumbnail(with: Data([2]))
        let current = try await newLoad.value
        let cached = try await store.mediaData(for: resource)
        XCTAssertEqual(current, Data([2]))
        XCTAssertEqual(cached, current)
    }

    func testOldPhotosScanCannotMarkTheNextCameraImported() async throws {
        let reconciler = SuspendedLibraryScan()
        var source = "camera-A"
        let client = MockGalleryClient(total: 1)
        let store = CameraGalleryStore(clientProvider: { client }, sourceIdentifierProvider: { source },
                                      importHistoryStore: InMemoryCameraImportHistoryStore(),
                                      importReconciler: reconciler)
        await store.loadInitial()
        let oldScan = Task { await store.reconcileImportHistoryWithPhotos() }
        let started = await waitUntil { await reconciler.isWaiting }
        XCTAssertTrue(started)
        source = "camera-B"
        await store.resetForReconnect()
        await store.loadInitial()
        await store.reconcileImportHistoryWithPhotos()
        await reconciler.finish()
        await oldScan.value

        let photo = try XCTUnwrap(store.photos.first)
        XCTAssertNil(store.importHistoryRecord(for: photo))
        XCTAssertFalse(store.hasCompletePhotoLibraryImportHistory)
        XCTAssertNotNil(store.importHistoryReconciliationError)
    }

    func testReconnectRecordsACompletedPhotosWriteAgainstItsOriginalCamera() async throws {
        let importer = SuspendedSuccessfulImporter()
        var source = "camera-A"
        let client = MockGalleryClient(total: 1)
        let history = InMemoryCameraImportHistoryStore()
        let store = CameraGalleryStore(clientProvider: { client }, sourceIdentifierProvider: { source },
                                      importer: importer, importHistoryStore: history)
        await store.loadInitial()
        let photo = try XCTUnwrap(store.photos.first)
        let importing = Task { await store.importPhoto(photo, samples: [], cameraClockOffset: 0) }
        let started = await waitUntil { await importer.isSaving }
        XCTAssertTrue(started)
        source = "camera-B"
        let reconnect = Task { await store.resetForReconnect() }
        let cancelled = await waitUntil { await importer.cancellationObserved }
        XCTAssertTrue(cancelled)
        await importer.finish()
        await importing.value
        await reconnect.value
        XCTAssertEqual(try history.load()["camera-A|" + photo.importIdentity]?.variants, [.jpeg])
        XCTAssertNil(try history.load()["camera-B|" + photo.importIdentity])
    }

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
        XCTAssertEqual(progress.attempted, 10)
        XCTAssertFalse(store.isImporting)
        XCTAssertEqual(store.selectedPhotoIDs.count, 1)

        let imported = await importer.filenames
        XCTAssertEqual(imported.count, 10)
        let failedPhoto = try XCTUnwrap(store.photos.first { $0.itemID == "4" })
        guard case let .failed(failure) = store.importStates[failedPhoto.id] else {
            return XCTFail("Expected the configured item to report a failure")
        }
        XCTAssertEqual(failure.filename, "photo-4.jpg")
        XCTAssertEqual(failure.message, "Configured import failure")
        XCTAssertEqual(store.failedPhotos.map(\.id), [failedPhoto.id])
    }

    func testCompleteMediaCountsSplitImagesAndVideos() async {
        let client = MockGalleryClient(total: 5, videoIndexes: [1, 3])
        let store = CameraGalleryStore(client: client, importer: RecordingImporter(), pageSize: 2)

        await store.reloadAllMedia()

        XCTAssertTrue(store.hasCompleteMediaCounts)
        XCTAssertEqual(store.imageCount, 3)
        XCTAssertEqual(store.videoCount, 2)
    }

    func testMP4PlaybackUsesTheCompletedLocalDownloadUntilSessionStops() async throws {
        let client = MockGalleryClient(total: 1, videoIndexes: [0])
        let store = CameraGalleryStore(client: client, importer: RecordingImporter(), pageSize: 1)

        await store.loadInitial()
        let video = try XCTUnwrap(store.photos.first)
        let session = try await store.videoPlaybackSession(video)
        let localURL = try await session.start()

        XCTAssertTrue(localURL.isFileURL)
        XCTAssertEqual(localURL.pathExtension.uppercased(), "MP4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: localURL.path))

        await session.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path))
    }

    func testSelectAllIncludesEveryImageAndVideo() async {
        let client = MockGalleryClient(total: 5, videoIndexes: [1, 3])
        let store = CameraGalleryStore(client: client, importer: RecordingImporter(), pageSize: 2)

        await store.reloadAllMedia()
        store.selectAll()

        XCTAssertEqual(store.selectedPhotoIDs, Set(store.photos.map(\.id)))
        XCTAssertEqual(store.selectedPhotoIDs.count, 5)
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

    func testRefreshDuringRemoteShootingWaitsThenLoadsTheNewPhotos() async throws {
        let coordinator = CameraModeCoordinator()
        let camera = MockGalleryClient(total: 2)
        let store = CameraGalleryStore(
            client: CoordinatedCameraGalleryClient(base: camera, coordinator: coordinator),
            importer: RecordingImporter(),
            pageSize: 5
        )
        await store.loadInitial()
        XCTAssertEqual(store.photos.count, 2)

        let shooting = try await coordinator.beginExclusive(.remoteShooting)
        await camera.setTotal(3)
        let refresh = Task { await store.reloadAllMedia() }
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(store.phase, .loading, "The gallery must wait instead of switching the camera to playback")
        let requestsWhileShooting = await camera.browseRequests.count
        XCTAssertEqual(requestsWhileShooting, 1, "Only the original load browsed the camera")

        store.markNeedsReloadAfterCameraModeChange()
        coordinator.endExclusive(shooting)
        await refresh.value
        XCTAssertEqual(store.photos.count, 3, "The photo taken while shooting appears after returning")
        XCTAssertFalse(store.consumeReloadRequest(), "The waiting refresh already reflects the new camera state")

        store.markNeedsReloadAfterCameraModeChange()
        XCTAssertTrue(store.consumeReloadRequest())
        XCTAssertFalse(store.consumeReloadRequest(), "A reload request is consumed once")
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

    func testOriginalMetadataInspectionDownloadsOnceAndCachesTheResult() async throws {
        let captureDate = Date(timeIntervalSince1970: 1_786_692_600)
        let embeddedLocation = PhotoGeotagLocation(latitude: 1.3521, longitude: 103.8198)
        let client = MockGalleryClient(total: 1)
        let store = CameraGalleryStore(
            client: client,
            importer: RecordingImporter(),
            pageSize: 1,
            photoMetadataReader: { _ in
                PhotoOriginalMetadata(captureDate: captureDate, embeddedLocation: embeddedLocation)
            }
        )

        await store.loadInitial()
        let photo = try XCTUnwrap(store.photos.first)
        let first = await store.inspectOriginalMetadata(for: photo)
        let second = await store.inspectOriginalMetadata(for: photo)

        guard case let .resolved(inspection) = first else {
            return XCTFail("Expected original metadata to resolve")
        }
        XCTAssertEqual(inspection.exifCaptureDate, captureDate)
        XCTAssertEqual(inspection.embeddedLocation, embeddedLocation)
        XCTAssertEqual(second, first)
        let downloadCount = await client.downloadCount
        XCTAssertEqual(downloadCount, 1)
    }

    /// The GM1S lists media without dates, so the location writer reads capture
    /// times from the newest originals and stops once it is past the period.
    func testPeriodScanReadsNewestCaptureTimesAndStopsPastThePeriod() async throws {
        let dates = CaptureDateTable()
        let client = MockGalleryClient(total: 14)
        let store = CameraGalleryStore(
            client: client,
            importer: RecordingImporter(),
            pageSize: 5,
            photoMetadataReader: { fileURL in
                PhotoOriginalMetadata(captureDate: dates.date(forDownloadedFile: fileURL), embeddedLocation: nil)
            }
        )
        await store.loadInitial()
        XCTAssertTrue(store.canLoadMore, "The scan must load the remaining pages itself")
        await store.loadAllPages()
        let base = Date(timeIntervalSince1970: 1_794_067_200)
        // Newest first, one minute apart: positions 0–3 fall inside the period.
        for (position, photo) in store.photos.enumerated() {
            dates.set(base.addingTimeInterval(Double(-60 * position)), for: try XCTUnwrap(photo.originalJPEGResource).url)
        }
        let period = base.addingTimeInterval(-200)...base.addingTimeInterval(30)
        XCTAssertEqual(CameraGeotagPeriodScanner.photos(in: period, store: store).unknown, 14)

        let scanner = CameraGeotagPeriodScanner()
        await scanner.scan(store: store, period: period, limit: 120)

        // 4 inside, then 5 older ones in a row end the scan.
        XCTAssertEqual(scanner.checkedCount, 9)
        let downloads = await client.downloadCount
        XCTAssertEqual(downloads, 9)
        let result = CameraGeotagPeriodScanner.photos(in: period, store: store)
        XCTAssertEqual(result.inside.map(\.photo.id), Array(store.photos.prefix(4)).map(\.id))
        XCTAssertEqual(result.unknown, 5, "Older photos past the stopping point stay unread")
        XCTAssertNil(store.metadataInspectionState(for: store.photos[13]))
        let completion = try XCTUnwrap(scanner.completion)
        XCTAssertEqual(completion, .init(periodStart: period.lowerBound, checked: 9, reachedOlderPhotos: true))
        XCTAssertTrue(completion.covers(base.addingTimeInterval(-100)...base), "A later start is covered")
        XCTAssertFalse(completion.covers(base.addingTimeInterval(-600)...base), "An earlier start needs another scan")

        // A period older than every photo reads the whole card and says so.
        let olderPeriod = base.addingTimeInterval(-7_200)...base.addingTimeInterval(-3_600)
        await scanner.scan(store: store, period: olderPeriod, limit: 120)
        XCTAssertEqual(scanner.completion?.reachedOlderPhotos, false)
        XCTAssertEqual(scanner.completion?.checked, 14)
        XCTAssertTrue(CameraGeotagPeriodScanner.photos(in: olderPeriod, store: store).inside.isEmpty)
    }

    /// On a GM1S the pre-write scan cached the newest photos, and the check after
    /// the write then reported those cached, GPS-free results instead of the card.
    func testVerificationAfterAWriteRereadsPhotosTheScanAlreadyRead() async throws {
        let table = CaptureDateTable()
        let client = MockGalleryClient(total: 3)
        let store = CameraGalleryStore(
            client: client,
            importer: RecordingImporter(),
            pageSize: 3,
            photoMetadataReader: { fileURL in
                PhotoOriginalMetadata(
                    captureDate: table.date(forDownloadedFile: fileURL),
                    embeddedLocation: table.location(forDownloadedFile: fileURL)
                )
            }
        )
        await store.loadInitial()
        let base = Date(timeIntervalSince1970: 1_794_067_200)
        for (position, photo) in store.photos.enumerated() {
            table.set(base.addingTimeInterval(Double(-60 * position)), for: try XCTUnwrap(photo.originalJPEGResource).url)
        }
        let period = base.addingTimeInterval(-600)...base.addingTimeInterval(60)
        let track = [
            LocationSample(timestamp: period.lowerBound, latitude: 22.3, longitude: 114.17, horizontalAccuracy: 8),
            LocationSample(timestamp: period.upperBound, latitude: 22.3, longitude: 114.17, horizontalAccuracy: 8)
        ]

        await CameraGeotagPeriodScanner().scan(store: store, period: period, limit: 120)
        XCTAssertEqual(CameraGeotagPeriodScanner.photos(in: period, store: store).inside.count, 3)

        // The camera writes GPS into the newest photo only.
        let tagged = try XCTUnwrap(store.photos.first)
        table.setLocation(PhotoGeotagLocation(latitude: 22.3, longitude: 114.17), for: try XCTUnwrap(tagged.originalJPEGResource).url)

        let cached = await store.inspectOriginalMetadata(for: tagged)
        guard case let .resolved(before) = cached else { return XCTFail("Expected the cached scan result") }
        XCTAssertNil(before.embeddedLocation, "Without force the scan's result is reused")

        let verifier = CameraGeotagVerifier()
        await verifier.verify(store: store, period: period, samples: track, baseline: [:], limit: 120)
        let statuses = Dictionary(uniqueKeysWithValues: verifier.results.map { ($0.id, $0.status) })
        guard case .taggedNearTrack? = statuses[tagged.id] else {
            return XCTFail("The written photo must be read again from the card, got \(String(describing: statuses[tagged.id]))")
        }
        XCTAssertEqual(statuses.values.filter { $0 == .notTagged }.count, 2)
        let downloads = await client.downloadCount
        XCTAssertEqual(downloads, 6, "Every photo is read once by the scan and once more by the check")
    }

    /// Each read cuts a camera transfer short, and a GM1S stopped serving files
    /// after about 150 of them. The check after a write read every photo on the
    /// card; it now stops past the period like the scan before the write.
    func testCheckAfterAWriteStopsPastThePeriod() async throws {
        let (client, store, base) = try await makeDatedCard(photos: 14)
        // Positions 0–3 fall inside the period.
        let period = base.addingTimeInterval(-200)...base.addingTimeInterval(30)

        let verifier = CameraGeotagVerifier()
        await verifier.verify(store: store, period: period, samples: [], baseline: [:], limit: 120)

        XCTAssertEqual(verifier.checkedCount, 9, "4 inside the period, then 5 older ones in a row")
        XCTAssertEqual(verifier.stop, .reachedOlderPhotos(unread: 5))
        XCTAssertEqual(verifier.results.map(\.id), Array(store.photos.prefix(9)).map(\.id))
        let downloads = await client.downloadCount
        XCTAssertEqual(downloads, 9)
    }

    /// When the GM1S stopped serving files, every remaining photo still waited
    /// for its own timeout. Two failed reads in a row now end the scan and the check.
    func testCardReadsStopWhenTheCameraStopsReturningPhotos() async throws {
        let (client, store, base) = try await makeDatedCard(photos: 14)
        // Every photo is inside the period, so only failures can end the reads early.
        let period = base.addingTimeInterval(-3_600)...base.addingTimeInterval(30)
        let urls = try store.photos.map { try XCTUnwrap($0.originalJPEGResource).url }
        await client.failDownloads(of: Array(urls.dropFirst(2)))

        let scanner = CameraGeotagPeriodScanner()
        await scanner.scan(store: store, period: period, limit: 120)
        XCTAssertTrue(scanner.cameraStoppedAnswering)
        XCTAssertNil(scanner.completion)
        XCTAssertEqual(scanner.checkedCount, 4, "Two good reads, then two failures")
        var downloads = await client.downloadCount
        XCTAssertEqual(downloads, 4)

        let verifier = CameraGeotagVerifier()
        await verifier.verify(store: store, period: period, samples: [], baseline: [:], limit: 120)
        XCTAssertEqual(verifier.stop, .cameraStoppedAnswering)
        XCTAssertEqual(verifier.checkedCount, 4)
        downloads = await client.downloadCount
        XCTAssertEqual(downloads, 8)

        // After the camera is back, the scan reads the failed photos again and
        // reuses the two it already has.
        await client.failDownloads(of: [])
        await scanner.scan(store: store, period: period, limit: 120)
        XCTAssertFalse(scanner.cameraStoppedAnswering)
        XCTAssertEqual(scanner.completion?.checked, 14)
        downloads = await client.downloadCount
        XCTAssertEqual(downloads, 8 + 12)
    }

    func testOneUnreadablePhotoDoesNotStopTheCheck() async throws {
        let (client, store, base) = try await makeDatedCard(photos: 6)
        let period = base.addingTimeInterval(-3_600)...base.addingTimeInterval(30)
        await client.failDownloads(of: [try XCTUnwrap(store.photos[1].originalJPEGResource).url])

        let verifier = CameraGeotagVerifier()
        await verifier.verify(store: store, period: period, samples: [], baseline: [:], limit: 120)

        XCTAssertNil(verifier.stop)
        XCTAssertEqual(verifier.checkedCount, 6)
        guard case .failed? = verifier.results.first(where: { $0.id == store.photos[1].id })?.status else {
            return XCTFail("The unreadable photo is reported")
        }
    }

    /// A card whose photos are one minute apart, newest first, starting at `base`.
    private func makeDatedCard(photos count: Int) async throws -> (MockGalleryClient, CameraGalleryStore, Date) {
        let table = CaptureDateTable()
        let client = MockGalleryClient(total: count)
        let store = CameraGalleryStore(
            client: client,
            importer: RecordingImporter(),
            pageSize: count,
            photoMetadataReader: { fileURL in
                PhotoOriginalMetadata(captureDate: table.date(forDownloadedFile: fileURL), embeddedLocation: nil)
            }
        )
        await store.loadInitial()
        let base = Date(timeIntervalSince1970: 1_794_067_200)
        for (position, photo) in store.photos.enumerated() {
            table.set(base.addingTimeInterval(Double(-60 * position)), for: try XCTUnwrap(photo.originalJPEGResource).url)
        }
        return (client, store, base)
    }

    func testConcurrentMetadataInspectionsShareOneCameraDownload() async throws {
        let client = MockGalleryClient(total: 1, downloadDelay: .milliseconds(100))
        let store = CameraGalleryStore(
            client: client,
            importer: RecordingImporter(),
            pageSize: 1,
            photoMetadataReader: { _ in
                PhotoOriginalMetadata(captureDate: nil, embeddedLocation: nil)
            }
        )

        await store.loadInitial()
        let photo = try XCTUnwrap(store.photos.first)
        async let first = store.inspectOriginalMetadata(for: photo)
        async let second = store.inspectOriginalMetadata(for: photo)
        let (firstResult, secondResult) = await (first, second)

        XCTAssertEqual(firstResult, secondResult)
        guard case .resolved = firstResult else {
            return XCTFail("Expected the shared inspection to resolve")
        }
        let downloadCount = await client.downloadCount
        XCTAssertEqual(downloadCount, 1)
    }

    func testMetadataInspectionTimesOutAndRecordsItsStages() async throws {
        let client = MockGalleryClient(total: 1, downloadDelay: .seconds(30))
        let store = CameraGalleryStore(
            client: client,
            importer: RecordingImporter(),
            pageSize: 1,
            metadataInspectionDownloadTimeout: .milliseconds(20)
        )
        var diagnostics: [String] = []

        await store.loadInitial()
        let photo = try XCTUnwrap(store.photos.first)
        let state = await store.inspectOriginalMetadata(
            for: photo,
            onDiagnostic: { diagnostics.append($0) }
        )

        guard case let .failed(message) = state else {
            return XCTFail("Expected the inspection to time out")
        }
        XCTAssertTrue(message.contains("did not finish sending"))
        XCTAssertTrue(diagnostics.contains { $0.contains("Checking photo metadata") })
        XCTAssertTrue(diagnostics.contains { $0.contains("Downloading original JPEG metadata") })
        XCTAssertTrue(diagnostics.contains { $0.contains("failed") })
    }

    func testMetadataTimeoutDoesNotWaitForAnUncooperativeCameraDownload() async throws {
        let client = MockGalleryClient(total: 1, ignoresDownloadCancellation: true)
        let store = CameraGalleryStore(
            client: client,
            importer: RecordingImporter(),
            pageSize: 1,
            metadataInspectionDownloadTimeout: .milliseconds(20)
        )

        await store.loadInitial()
        let photo = try XCTUnwrap(store.photos.first)
        let startedAt = Date()
        let state = await store.inspectOriginalMetadata(for: photo)
        let elapsed = Date().timeIntervalSince(startedAt)

        guard case let .failed(message) = state else {
            return XCTFail("Expected the inspection to time out")
        }
        XCTAssertTrue(message.contains("did not finish sending"))
        XCTAssertLessThan(elapsed, 0.3)
    }

    func testMetadataTimeoutPublishesBeforeBlockingCancellationHandlerReturns() async throws {
        let client = MockGalleryClient(
            total: 1,
            cancellationHandlerBlockSeconds: 0.5
        )
        let store = CameraGalleryStore(
            client: client,
            importer: RecordingImporter(),
            pageSize: 1,
            metadataInspectionDownloadTimeout: .milliseconds(20)
        )

        await store.loadInitial()
        let photo = try XCTUnwrap(store.photos.first)
        let startedAt = Date()
        let state = await store.inspectOriginalMetadata(for: photo)
        let elapsed = Date().timeIntervalSince(startedAt)

        guard case let .failed(message) = state else {
            return XCTFail("Expected the inspection to time out")
        }
        XCTAssertTrue(message.contains("did not finish sending"))
        XCTAssertLessThan(elapsed, 0.2)
    }

    func testGalleryRefreshLeavesInterruptedMetadataCheckVisibleForRetry() async throws {
        let client = MockGalleryClient(total: 1, downloadDelay: .seconds(30))
        let store = CameraGalleryStore(
            client: client,
            importer: RecordingImporter(),
            pageSize: 1,
            metadataInspectionDownloadTimeout: .seconds(60)
        )
        var diagnostics: [String] = []

        await store.loadInitial()
        let photo = try XCTUnwrap(store.photos.first)
        let inspectionTask = Task {
            await store.inspectOriginalMetadata(
                for: photo,
                onDiagnostic: { diagnostics.append($0) }
            )
        }

        for _ in 0..<20 {
            if store.metadataInspectionState(for: photo) == .checking(.downloadingOriginalJPEG) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.metadataInspectionState(for: photo), .checking(.downloadingOriginalJPEG))

        await store.loadInitial()
        _ = await inspectionTask.value

        guard case let .failed(message) = store.metadataInspectionState(for: photo) else {
            return XCTFail("Expected an interrupted check to remain visible")
        }
        XCTAssertTrue(message.contains("gallery refreshed"))
        XCTAssertTrue(diagnostics.contains { $0.contains("was interrupted") })
    }

    func testImportPersistsVerifiedCaptureTimeAndMatchedLocation() async throws {
        let captureDate = Date(timeIntervalSince1970: 1_786_692_600)
        let client = MockGalleryClient(total: 1)
        let importer = RecordingImporter()
        let store = CameraGalleryStore(
            client: client,
            importer: importer,
            importHistoryStore: InMemoryCameraImportHistoryStore(),
            sourceIdentifier: "GM1S-TEST",
            pageSize: 1,
            photoMetadataReader: { _ in
                PhotoOriginalMetadata(captureDate: captureDate, embeddedLocation: nil)
            }
        )
        let sample = LocationSample(
            timestamp: captureDate,
            latitude: 1.3521,
            longitude: 103.8198,
            altitude: 12,
            horizontalAccuracy: 8
        )

        await store.loadInitial()
        let photo = try XCTUnwrap(store.photos.first)
        await store.importPhoto(photo, samples: [sample], cameraClockOffset: 0)

        let history = try XCTUnwrap(store.importHistoryRecord(for: photo))
        XCTAssertEqual(history.verifiedCaptureDate, captureDate)
        XCTAssertEqual(history.appliedLocation?.latitude, sample.latitude)
        XCTAssertEqual(history.appliedLocation?.longitude, sample.longitude)
        let packages = await importer.packages
        XCTAssertEqual(packages.first?.geotag?.latitude, sample.latitude)
        XCTAssertNil(packages.first?.embeddedLocation)
    }

    func testManualLocationOverridePersistsAcrossReconnectAndWinsOverTrackMatch() async throws {
        let captureDate = Date(timeIntervalSince1970: 1_786_692_600)
        let client = MockGalleryClient(total: 1)
        let importer = RecordingImporter()
        let historyStore = InMemoryCameraImportHistoryStore()
        let locationStore = InMemoryCameraLocationOverrideStore()
        let manualLocation = PhotoGeotagLocation(latitude: 1.3, longitude: 103.8)
        let firstStore = CameraGalleryStore(
            client: client,
            importer: importer,
            importHistoryStore: historyStore,
            locationOverrideStore: locationStore,
            sourceIdentifier: "GM1S-TEST",
            pageSize: 1,
            photoMetadataReader: { _ in
                PhotoOriginalMetadata(captureDate: captureDate, embeddedLocation: nil)
            }
        )
        let trackSample = LocationSample(
            timestamp: captureDate,
            latitude: 1.35,
            longitude: 103.85,
            horizontalAccuracy: 8
        )

        await firstStore.loadInitial()
        let firstPhoto = try XCTUnwrap(firstStore.photos.first)
        try firstStore.setManualLocation(manualLocation, for: [firstPhoto])
        XCTAssertEqual(firstStore.manualLocationOverride(for: firstPhoto), manualLocation)

        let reloadedStore = CameraGalleryStore(
            client: client,
            importer: importer,
            importHistoryStore: historyStore,
            locationOverrideStore: locationStore,
            sourceIdentifier: "GM1S-TEST",
            pageSize: 1,
            photoMetadataReader: { _ in
                PhotoOriginalMetadata(captureDate: captureDate, embeddedLocation: nil)
            }
        )
        await reloadedStore.loadInitial()
        let reloadedPhoto = try XCTUnwrap(reloadedStore.photos.first)
        XCTAssertEqual(reloadedStore.manualLocationOverride(for: reloadedPhoto), manualLocation)

        await reloadedStore.importPhoto(
            reloadedPhoto,
            samples: [trackSample],
            cameraClockOffset: 0
        )

        let packages = await importer.packages
        let package = try XCTUnwrap(packages.last)
        XCTAssertNil(package.geotag)
        XCTAssertEqual(package.manualLocation, manualLocation)
        XCTAssertEqual(reloadedStore.importHistoryRecord(for: reloadedPhoto)?.appliedLocation, manualLocation)
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

    func testPhotosLibraryReconciliationRecoversMissingHistoryAndExcludesMatches() async throws {
        let client = MockGalleryClient(total: 3, videoIndexes: [1])
        let historyStore = InMemoryCameraImportHistoryStore()
        let store = CameraGalleryStore(
            client: client,
            importer: RecordingImporter(),
            importHistoryStore: historyStore,
            importReconciler: StubImportReconciler(
                matchedFilenames: ["PHOTO-2.JPG", "video-1.mp4"],
                hasCompleteLibraryAccess: true
            ),
            sourceIdentifier: "GM1S-TEST",
            pageSize: 3
        )

        await store.reloadAllMedia()

        let recoveredPhoto = try XCTUnwrap(store.photos.first { $0.itemID == "2" })
        let recoveredVideo = try XCTUnwrap(store.photos.first { $0.itemID == "1" })
        let newPhoto = try XCTUnwrap(store.photos.first { $0.itemID == "0" })
        XCTAssertEqual(store.importHistoryRecord(for: recoveredPhoto)?.effectiveEvidence, .photosLibrary)
        XCTAssertEqual(store.importHistoryRecord(for: recoveredPhoto)?.variants, [.jpeg])
        XCTAssertEqual(store.importHistoryRecord(for: recoveredVideo)?.variants, [.video])
        XCTAssertNil(store.importHistoryRecord(for: newPhoto))
        XCTAssertTrue(store.hasCompletePhotoLibraryImportHistory)

        XCTAssertEqual(store.selectUnimported(), 1)
        XCTAssertEqual(store.selectedPhotoIDs, [newPhoto.id])
        XCTAssertEqual(try historyStore.load().count, 2)
    }

    func testLimitedPhotosAccessRecoversVisibleMatchesButIsNotSafeForDownloadAllNew() async throws {
        let client = MockGalleryClient(total: 2)
        let store = CameraGalleryStore(
            client: client,
            importer: RecordingImporter(),
            importHistoryStore: InMemoryCameraImportHistoryStore(),
            importReconciler: StubImportReconciler(
                matchedFilenames: ["photo-1.jpg"],
                hasCompleteLibraryAccess: false
            ),
            sourceIdentifier: "GM1S-TEST",
            pageSize: 2
        )

        await store.reloadAllMedia()

        let visibleMatch = try XCTUnwrap(store.photos.first { $0.itemID == "1" })
        XCTAssertTrue(store.isPreviouslyImported(visibleMatch))
        XCTAssertFalse(store.hasCompletePhotoLibraryImportHistory)
        XCTAssertNotNil(store.importHistoryReconciliationError)
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

        // A released slot can legitimately start another download. Cancel and drain
        // the queued requests while all three active transfers still hold their slots.
        let activeURLs = await client.activeURLs
        let queued = zip(resources, loads).filter { !activeURLs.contains($0.0.url) }.map(\.1)
        XCTAssertEqual(queued.count, 2)
        queued.forEach { $0.cancel() }
        for load in queued { _ = try? await load.value }
        let cancelledWhileQueued = await client.cancellationCount
        XCTAssertEqual(cancelledWhileQueued, 0)

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

private struct StubImportReconciler: CameraImportReconciling {
    let matchedFilenames: Set<String>
    let hasCompleteLibraryAccess: Bool

    func importedFilenames(matching filenames: Set<String>) async throws -> CameraImportReconciliationResult {
        let normalizedMatches = Set(matchedFilenames.map(CameraImportFilename.normalized))
        return CameraImportReconciliationResult(
            matchedFilenames: normalizedMatches.intersection(filenames),
            hasCompleteLibraryAccess: hasCompleteLibraryAccess
        )
    }
}

/// Capture times keyed by original-JPEG file name, for a metadata reader that
/// only sees the downloaded prefix file (named `<UUID>-<original name>`).
private final class CaptureDateTable: @unchecked Sendable {
    private let lock = NSLock()
    private var dates: [String: Date] = [:]
    private var locations: [String: PhotoGeotagLocation] = [:]

    func set(_ date: Date, for url: URL) {
        lock.withLock { dates[url.lastPathComponent] = date }
    }

    func setLocation(_ location: PhotoGeotagLocation, for url: URL) {
        lock.withLock { locations[url.lastPathComponent] = location }
    }

    func date(forDownloadedFile fileURL: URL) -> Date? {
        let name = fileURL.lastPathComponent
        return lock.withLock { dates.first { name.hasSuffix("-" + $0.key) }?.value }
    }

    func location(forDownloadedFile fileURL: URL) -> PhotoGeotagLocation? {
        let name = fileURL.lastPathComponent
        return lock.withLock { locations.first { name.hasSuffix("-" + $0.key) }?.value }
    }
}

private actor MockGalleryClient: CameraGalleryClient {
    struct BrowseRequest: Sendable {
        let start: Int
        let count: Int
    }

    private var total: Int
    private let overlapsPages: Bool
    private let maximumReturnedCount: Int
    private let preparationDelay: Duration
    private let includesRAW: Bool
    private let rawOnlyIndexes: Set<Int>
    private let videoIndexes: Set<Int>
    private let downloadDelay: Duration
    private let ignoresDownloadCancellation: Bool
    private let cancellationHandlerBlockSeconds: TimeInterval
    private let holdThumbnails: Bool
    private var thumbnailContinuation: CheckedContinuation<Data, Never>?
    var thumbnailIsWaiting: Bool { thumbnailContinuation != nil }
    private var delayedBrowseStart: Int?
    private var delayedBrowseDuration: Duration = .milliseconds(250)
    private(set) var browseRequests: [BrowseRequest] = []
    private(set) var browseCancellationCount = 0
    private(set) var downloadCount = 0
    private var failingFilenames: Set<String> = []

    /// Downloads of these files fail, as when the camera stops serving them.
    func failDownloads(of urls: [URL]) {
        failingFilenames = Set(urls.map(\.lastPathComponent))
    }

    init(
        total: Int,
        overlapsPages: Bool = false,
        maximumReturnedCount: Int = .max,
        preparationDelay: Duration = .zero,
        includesRAW: Bool = false,
        rawOnlyIndexes: Set<Int> = [],
        videoIndexes: Set<Int> = [],
        downloadDelay: Duration = .zero,
        ignoresDownloadCancellation: Bool = false,
        cancellationHandlerBlockSeconds: TimeInterval = 0,
        holdThumbnails: Bool = false
    ) {
        self.total = total
        self.overlapsPages = overlapsPages
        self.maximumReturnedCount = maximumReturnedCount
        self.preparationDelay = preparationDelay
        self.includesRAW = includesRAW
        self.rawOnlyIndexes = rawOnlyIndexes
        self.holdThumbnails = holdThumbnails
        self.videoIndexes = videoIndexes
        self.downloadDelay = downloadDelay
        self.ignoresDownloadCancellation = ignoresDownloadCancellation
        self.cancellationHandlerBlockSeconds = cancellationHandlerBlockSeconds
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
        let upperBound = min(total, start + min(count, maximumReturnedCount))
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
        if holdThumbnails { return await withCheckedContinuation { thumbnailContinuation = $0 } }
        return Data([0xff, 0xd8, 0xff, 0xd9])
    }

    func finishThumbnail(with data: Data) {
        thumbnailContinuation?.resume(returning: data)
        thumbnailContinuation = nil
    }

    func download(_ resource: LumixResource) async throws -> URL {
        downloadCount += 1
        if failingFilenames.contains(resource.url.lastPathComponent) {
            throw TestImportError.configuredFailure
        }
        if cancellationHandlerBlockSeconds > 0 {
            let blockSeconds = cancellationHandlerBlockSeconds
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                        continuation.resume(throwing: TestImportError.configuredFailure)
                    }
                }
            } onCancel: {
                Thread.sleep(forTimeInterval: blockSeconds)
            }
        }
        if ignoresDownloadCancellation {
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                    continuation.resume(throwing: TestImportError.configuredFailure)
                }
            }
        }
        if downloadDelay > .zero { try await Task.sleep(for: downloadDelay) }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-" + resource.url.lastPathComponent)
        try Data([0xff, 0xd8, 0xff, 0xd9]).write(to: destination)
        return destination
    }

    private func photo(_ index: Int) -> LumixPhoto {
        let itemID = String(index)
        if videoIndexes.contains(index) {
            let resource = LumixResource(
                itemID: itemID,
                title: "Video \(index)",
                url: URL(string: "http://192.168.54.1:50001/video-\(index).MP4")!,
                protocolInfo: "http-get:*:video/mp4;PANASONIC.COM_PN=CAM_MP4"
            )
            return LumixPhoto(itemID: itemID, title: "Video \(index)", resources: [resource])
        }
        let resource = LumixResource(
            itemID: itemID,
            title: "Photo \(index)",
            url: URL(string: "http://192.168.54.1:50001/photo-\(index).jpg")!,
            protocolInfo: "http-get:*:image/jpeg;PANASONIC.COM_PN=CAM_ORG"
        )
        var resources = rawOnlyIndexes.contains(index) ? [] : [resource]
        if includesRAW || rawOnlyIndexes.contains(index) {
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

private actor SuspendedLibraryScan: CameraImportReconciling {
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }

    func importedFilenames(matching filenames: Set<String>) async throws -> CameraImportReconciliationResult {
        if isWaiting {
            return .init(matchedFilenames: [], hasCompleteLibraryAccess: false)
        }
        await withCheckedContinuation { continuation = $0 }
        return .init(matchedFilenames: filenames, hasCompleteLibraryAccess: true)
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}

private actor SuspendedSuccessfulImporter: CameraMediaImporting {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var cancellationObserved = false
    var isSaving: Bool { continuation != nil }

    func save(_ media: DownloadedCameraMedia, geotag: GeotagMatch?) async throws {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation = $0 }
        } onCancel: {
            Task { await self.noteCancellation() }
        }
    }

    private func noteCancellation() { cancellationObserved = true }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}

private actor CancellableMediaClient: CameraGalleryClient {
    private(set) var activeURLs: Set<URL> = []
    var activeDownloads: Int { activeURLs.count }
    private(set) var maximumActiveDownloads = 0
    private(set) var cancellationCount = 0

    func prepareForBrowsing() async throws -> Int { 0 }

    func browsePhotos(start: Int, count: Int) async throws -> LumixPhotoPage {
        LumixPhotoPage(startIndex: start, numberReturned: 0, totalMatches: 0, photos: [])
    }

    func downloadJPEGData(_ resource: LumixResource) async throws -> Data {
        activeURLs.insert(resource.url)
        maximumActiveDownloads = max(maximumActiveDownloads, activeDownloads)
        defer { activeURLs.remove(resource.url) }

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
        let geotag: GeotagMatch?
        let embeddedLocation: PhotoGeotagLocation?
        let manualLocation: PhotoGeotagLocation?
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
                roles: media.resources.map(\.role),
                geotag: geotag,
                embeddedLocation: media.embeddedLocation,
                manualLocation: media.manualLocation
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
