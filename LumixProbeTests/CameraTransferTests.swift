import Foundation
import XCTest
@testable import GM1Sync

final class CameraTransferTests: XCTestCase {
    @MainActor
    func testOlderConnectionFailureCannotDisconnectANewerSuccessfulProbe() async {
        let started = expectation(description: "First camera probe started")
        let probe = DelayedCameraProbe(started: started)
        let model = ProbeViewModel(cameraNetworkStore: KeychainCameraNetworkStore(service: UUID().uuidString),
                                   checkCamera: { _, _ in await probe.check() })
        let older = Task { await model.refreshConnectionStatus() }
        await fulfillment(of: [started], timeout: 5)
        await model.refreshConnectionStatus()
        await probe.finish()
        await older.value
        XCTAssertTrue(model.isCameraConnected)
        XCTAssertEqual(model.connectionStatusMessage, "Camera connected")
    }

    func testFourFieldProtocolInfoKeepsTheMIMEAndPanasonicProfileSeparate() {
        let resource = LumixResource(itemID: "1", title: "Video", url: URL(string: "http://192.168.54.1:50001/a")!,
                                     protocolInfo: "http-get:*:video/mp4:DLNA.ORG_OP=01;PANASONIC.COM_PN=CAM_MP4")
        XCTAssertEqual(resource.mimeType, "video/mp4")
        XCTAssertEqual(resource.dlnaOperations, "01")
        XCTAssertTrue(resource.isPhoneCopyableVideoFormat)
        let photo = LumixResource(itemID: "2", title: "JPEG", url: URL(string: "http://192.168.54.1:50001/b")!,
                                  protocolInfo: "http-get:*:image/jpeg;PANASONIC.COM_PN=CAM_ORG:*")
        XCTAssertEqual(photo.profileName, "CAM_ORG")
        XCTAssertNotNil(LumixPhoto(itemID: "2", title: "JPEG", resources: [photo]).originalJPEGResource)
    }

    func testMediaFromAnotherHostIsRejectedBeforeConnecting() async {
        let client = LumixClient(host: "127.0.0.1")
        let foreign = LumixResource(itemID: "1", title: "Foreign",
                                    url: URL(string: "http://127.0.0.2:50001/a.ts")!,
                                    protocolInfo: "http-get:*:video/mp2t;PANASONIC.COM_PN=CAM_AVCHD")
        do {
            _ = try await client.makeAVCHDPlaybackSession(for: foreign, availableResources: [])
            XCTFail("Accepted a playback relay to a different host")
        } catch LumixError.invalidURL { } catch { XCTFail("Unexpected error: \(error)") }
        do {
            _ = try await client.downloadMetadataPrefix(foreign)
            XCTFail("Accepted a download from a different host")
        } catch LumixError.invalidURL { } catch { XCTFail("Attempted a connection: \(error)") }
    }

    func testSOAPTextPreservesDIDLEntitiesAndQueryParameters() throws {
        let didl = """
        <DIDL-Lite><item id="12"><title>Sun &amp; sea</title>
        <res protocolInfo="http-get:*:image/jpeg;PANASONIC.COM_PN=CAM_ORG">http://192.168.54.1:50001/a.jpg?x=1&amp;y=2</res>
        </item></DIDL-Lite>
        """
        func escaped(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        for payload in [escaped(didl), escaped(escaped(didl)), "<![CDATA[" + didl + "]]>"] {
            let soap = "<BrowseResponse><Result>\(payload)</Result><NumberReturned>1</NumberReturned></BrowseResponse>"
            let response = LumixHTTPResponse(url: URL(string: "http://192.168.54.1")!, statusCode: 200,
                                             headers: [:], data: Data(soap.utf8))
            let result = try LumixBrowseResult.parse(response)
            let item = try XCTUnwrap(result.resources.first)
            XCTAssertEqual(item.title, "Sun & sea")
            XCTAssertEqual(item.url.query, "x=1&y=2")
        }
    }

    func testCameraControlRedirectsStayOnTheConfiguredOrigin() throws {
        let source = try XCTUnwrap(URL(string: "http://192.168.54.1:60606/browse"))
        XCTAssertTrue(CameraControlRedirects.allows(source.appendingPathComponent("next"), from: source))
        for url in ["http://127.0.0.1:60606/browse", "http://192.168.54.1:81/browse",
                    "https://192.168.54.1:60606/browse", "http://user@192.168.54.1:60606/browse"] {
            XCTAssertFalse(CameraControlRedirects.allows(try XCTUnwrap(URL(string: url)), from: source))
        }
    }

    func testDiagnosticDownloadIsRemovedAfterItsLastReaderFinishes() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1, 2, 3]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var preview: DownloadedPhoto? = DownloadedPhoto(fileURL: file, captureDate: nil, originalFilename: "A.jpg")
        var saving = preview
        preview = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(saving).fileURL.path))
        saving = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

#if os(macOS)
    func testMacCopiesPreserveOriginalBytesAndHandleConcurrentNameCollisions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("source.jpg")
        let bytes = Data([0xff, 0xd8, 0xff, 0xd9])
        try bytes.write(to: input)
        let original = directory.appendingPathComponent("photo.jpg")
        try Data([42]).write(to: original)
        async let first = MacOriginalExporter.copy(fileURL: input, originalFilename: "photo.jpg", to: directory)
        async let second = MacOriginalExporter.copy(fileURL: input, originalFilename: "photo.jpg", to: directory)
        let copies = try await [first, second]
        XCTAssertEqual(Set(copies.map(\.lastPathComponent)), ["photo-1.jpg", "photo-2.jpg"])
        for copy in copies { XCTAssertEqual(try Data(contentsOf: copy), bytes) }
        XCTAssertEqual(try Data(contentsOf: original), Data([42]))
    }
#endif
}

private actor DelayedCameraProbe {
    let started: XCTestExpectation
    var first: CheckedContinuation<Bool, Never>?
    init(started: XCTestExpectation) { self.started = started }

    func check() async -> Bool {
        if first != nil { return true }
        return await withCheckedContinuation {
            first = $0
            started.fulfill()
        }
    }

    func finish() {
        first?.resume(returning: false)
        first = nil
    }
}
