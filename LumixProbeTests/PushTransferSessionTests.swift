import Foundation
import XCTest
@testable import GM1Sync

@MainActor
final class PushTransferSessionTests: XCTestCase {
    private var directory: URL!
    private var jpeg: Data!
    private var network: NetworkSwitch!
    private var harness: Harness!
    private var importer: RecordingPushImporter!
    private var history: CameraPushTransferHistory!
    private var coordinator: CameraModeCoordinator!
    private var camera: ScriptedRemoteCamera!
    private var session: PushTransferSession!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PushSession-\(UUID().uuidString)")
        jpeg = try XCTUnwrap(LumixLiveViewPacketBuilder.syntheticJPEG(width: 96, height: 72))
        network = NetworkSwitch(address: "192.168.54.10")
        harness = Harness()
        importer = RecordingPushImporter()
        history = CameraPushTransferHistory(store: InMemoryCameraPushTransferHistoryStore())
        let scope = CameraConnectionScope()
        coordinator = CameraModeCoordinator(connectionScope: scope)
        camera = ScriptedRemoteCamera(scope: scope)
        session = makeSession()
    }

    override func tearDown() async throws {
        await session?.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeSession() -> PushTransferSession {
        let network = self.network!
        let harness = self.harness!
        let camera = self.camera!
        var dependencies = PushTransferDependencies(
            cameraHost: "192.168.54.1",
            deviceUUID: "4D454930-0100-1000-8001-000000000001",
            pendingDirectory: directory.appendingPathComponent("Pending"),
            incomingDirectory: directory.appendingPathComponent("Incoming"),
            registrationCamera: { camera },
            importer: importer,
            history: history
        )
        dependencies.localAddress = { _ in network.address.map { .init(address: $0, interface: "en0") } }
        dependencies.makeServer = { receiver, _ in harness.makeServer(receiver) }
        dependencies.makeAnnouncer = { _, _, _, emit in harness.makeAnnouncer(emit) }
        dependencies.networkPollInterval = .milliseconds(20)
        return PushTransferSession(dependencies: dependencies, coordinator: coordinator)
    }

    func testWaitsForTheCameraNetworkThenAdvertisesAndRegisters() async throws {
        network.address = nil
        await session.start()
        XCTAssertEqual(session.phase, .waitingForCameraNetwork)
        XCTAssertTrue(harness.servers.isEmpty)
        XCTAssertEqual(coordinator.exclusiveActivity, .pushTransfer, "Gallery playback switches wait while receiving")

        network.address = "192.168.54.10"
        try await waitUntil { self.session.phase == .advertising }
        XCTAssertEqual(session.localEndpoint, "http://192.168.54.10:49152")
        XCTAssertEqual(harness.announcers.first?.starts, 1)
        try await waitUntil { self.session.registration == .accepted }
        let commands = await camera.commands
        XCTAssertEqual(commands, ["mode=accctrl&type=req_acc&value=0&value2=Retro LUMIX Sync"])
    }

    func testReportsSavedOnlyAfterPhotosHasTheFile() async throws {
        await session.start()
        let receiver = try XCTUnwrap(harness.servers.last?.receiver)
        _ = exchange(receiver, "GET /dms/ddd.xml HTTP/1.1\r\n\r\n")
        try await waitUntil { self.session.phase == .linked }
        XCTAssertEqual(harness.announcers.last?.intervals.last, 15)

        await importer.hold()
        upload(jpeg, title: "P1030516", to: receiver)
        try await waitUntil { self.session.items.first?.state == .saving }
        try await waitUntil { await self.importer.isWaiting }
        XCTAssertEqual(session.savedCount, 0, "Nothing is reported before Photos finishes")
        XCTAssertNil(history.savedRecord(sha256: sha(jpeg)))

        await importer.release()
        try await waitUntil { self.session.items.first?.state == .saved }
        XCTAssertEqual(session.savedCount, 1)
        XCTAssertEqual(session.items.first?.filename, "P1030516.JPG")
        XCTAssertEqual(session.items.first?.pixelWidth, 96)
        let saved = await importer.savedFilenames
        XCTAssertEqual(saved, ["P1030516.JPG"])
        XCTAssertNotNil(history.savedRecord(sha256: sha(jpeg)))
        XCTAssertEqual(session.pendingFileCount, 0)
    }

    func testRepeatedDeliveryOfTheSameImageIsNotSavedTwice() async throws {
        await session.start()
        let receiver = try XCTUnwrap(harness.servers.last?.receiver)
        upload(jpeg, title: "P1000001", to: receiver)
        try await waitUntil { self.session.savedCount == 1 }
        upload(jpeg, title: "P1000001", to: receiver)
        try await waitUntil { self.session.items.first?.state == .duplicate }
        let saved = await importer.savedFilenames
        XCTAssertEqual(saved.count, 1)
    }

    func testBurstIsSavedInArrivalOrder() async throws {
        await session.start()
        let receiver = try XCTUnwrap(harness.servers.last?.receiver)
        let frames = try (0..<3).map { index in
            try XCTUnwrap(LumixLiveViewPacketBuilder.syntheticJPEG(width: 80, height: 60, phase: 0.2 + Double(index) * 0.3))
        }
        for (index, frame) in frames.enumerated() { upload(frame, title: "P100000\(index)", to: receiver) }
        try await waitUntil { self.session.savedCount == 3 }
        let saved = await importer.savedFilenames
        XCTAssertEqual(saved, ["P1000000.JPG", "P1000001.JPG", "P1000002.JPG"])
    }

    func testPhotosPermissionFailureKeepsTheFileUntilARetrySucceeds() async throws {
        await importer.fail(with: CameraMediaImportError.permissionDenied)
        await session.start()
        let receiver = try XCTUnwrap(harness.servers.last?.receiver)
        upload(jpeg, title: "P1000020", to: receiver)
        try await waitUntil { self.session.items.first?.state == .waitingForPhotosAccess }
        XCTAssertTrue(session.needsPhotosAccess)
        XCTAssertEqual(session.pendingFileCount, 1)
        XCTAssertEqual(session.savedCount, 0)

        await importer.fail(with: nil)
        await session.retryPendingSaves()
        try await waitUntil { self.session.items.first?.state == .saved }
        XCTAssertFalse(session.needsPhotosAccess)
        XCTAssertEqual(session.pendingFileCount, 0)
    }

    func testBackgroundPausesAndForegroundResumesOnTheSamePort() async throws {
        await session.start()
        XCTAssertEqual(session.phase, .advertising)

        await session.setAppActive(false)
        XCTAssertEqual(session.phase, .paused)
        XCTAssertEqual(harness.servers.last?.stops, 1)
        XCTAssertEqual(harness.announcers.last?.goodbyes, [false], "The camera keeps its cached description")

        await session.setAppActive(true)
        XCTAssertEqual(session.phase, .advertising)
        XCTAssertEqual(harness.servers.count, 2)
        XCTAssertEqual(harness.servers.last?.requestedPorts.first, 49152, "The previous port is tried first")
        XCTAssertEqual(harness.announcers.last?.announcements, 1)
    }

    func testTheCameraSearchShowsTheCameraIsLookingForTheReceiver() async throws {
        await session.start()
        XCTAssertFalse(session.cameraSearched)
        harness.announcers.last?.simulate(.cameraSearched(SSDPMessage(
            startLine: "M-SEARCH * HTTP/1.1",
            headers: ["ST": PushTransferProtocol.mediaServerType, "MX": "5"]
        )))
        try await waitUntil { self.session.cameraSearched }
        XCTAssertEqual(session.phase, .linked)
    }

    func testLosingTheCameraNetworkWaitsForItAndAnnouncesTheNewAddress() async throws {
        await session.start()
        let receiver = try XCTUnwrap(harness.servers.last?.receiver)
        _ = exchange(receiver, "GET /dms/ddd.xml HTTP/1.1\r\n\r\n")
        try await waitUntil { self.session.phase == .linked }

        // The GM1S turns its Wi-Fi off after "Connection error".
        network.address = nil
        try await waitUntil { self.session.phase == .waitingForCameraNetwork }
        XCTAssertEqual(harness.servers.first?.stops, 1)
        XCTAssertEqual(harness.announcers.first?.goodbyes, [false])
        XCTAssertEqual(coordinator.exclusiveActivity, .pushTransfer, "Receiving continues once the network is back")

        network.address = "192.168.54.11"
        try await waitUntil { self.session.phase == .advertising }
        XCTAssertEqual(session.localEndpoint, "http://192.168.54.11:49152", "The new address is announced")
        XCTAssertEqual(harness.servers.count, 2)
        XCTAssertEqual(harness.servers.last?.requestedPorts.first, 49152, "The previous port is tried first")
        XCTAssertFalse(session.cameraSearched)
    }

    func testReturningAfterTheCameraFoundTheReceiverWarnsAboutAMissedPhoto() async throws {
        await session.start()
        let receiver = try XCTUnwrap(harness.servers.last?.receiver)
        _ = exchange(receiver, "GET /dms/ddd.xml HTTP/1.1\r\n\r\n")
        try await waitUntil { self.session.phase == .linked }
        XCTAssertFalse(session.resumedAfterPause)

        await session.setAppActive(false)
        await session.setAppActive(true)
        XCTAssertEqual(session.phase, .linked)
        XCTAssertTrue(session.resumedAfterPause, "A GM1S that tried to send meanwhile shows Connection error")

        let resumed = try XCTUnwrap(harness.servers.last?.receiver)
        upload(jpeg, title: "P1000030", to: resumed)
        try await waitUntil { self.session.savedCount == 1 }
        XCTAssertFalse(session.resumedAfterPause, "A photo from the camera shows it is still sending")
    }

    func testReturningOffTheCameraNetworkWaitsForTheCameraToFindTheReceiverAgain() async throws {
        await session.start()
        let receiver = try XCTUnwrap(harness.servers.last?.receiver)
        _ = exchange(receiver, "GET /dms/ddd.xml HTTP/1.1\r\n\r\n")
        try await waitUntil { self.session.phase == .linked }

        await session.setAppActive(false)
        network.address = nil
        await session.setAppActive(true)
        XCTAssertEqual(session.phase, .waitingForCameraNetwork)
        XCTAssertFalse(session.resumedAfterPause)

        network.address = "192.168.54.10"
        try await waitUntil { self.session.phase == .advertising }
    }

    func testStopSaysGoodbyeAndReleasesTheCamera() async throws {
        await session.start()
        await session.stop()
        XCTAssertEqual(session.phase, .stopped)
        XCTAssertEqual(harness.announcers.last?.goodbyes, [true])
        XCTAssertNil(coordinator.exclusiveActivity)
        XCTAssertEqual(coordinator.completedExclusiveActivities, 1)
    }

    func testJoiningTheCameraNetworkDoesNotRevokeTheSession() async throws {
        await session.start()
        coordinator.connectionDidChange()
        XCTAssertEqual(coordinator.exclusiveActivity, .pushTransfer)
        XCTAssertEqual(session.phase, .advertising)
    }

    func testFilesLeftFromAnEarlierSessionAreSaved() async throws {
        let pending = directory.appendingPathComponent("Pending")
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        try jpeg.write(to: pending.appendingPathComponent("A1B2__P1000099.JPG"))
        await session.start()
        try await waitUntil { self.session.savedCount == 1 }
        XCTAssertEqual(session.items.first?.filename, "P1000099.JPG")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.appendingPathComponent("A1B2__P1000099.JPG").path))
    }

    func testFailedUploadIsShownAndNothingIsSaved() async throws {
        await session.start()
        let receiver = try XCTUnwrap(harness.servers.last?.receiver)
        let token = createObject(receiver, title: "P1000030")
        let processor = PushHTTPConnectionProcessor(router: receiver)
        _ = processor.receive(Data("POST /upload/\(token) HTTP/1.1\r\nContent-Length: \(jpeg.count)\r\n\r\n".utf8) + jpeg.prefix(100))
        processor.connectionClosed()
        try await waitUntil {
            if case .failed = self.session.items.first?.state { return true }
            return false
        }
        let saved = await importer.savedFilenames
        XCTAssertTrue(saved.isEmpty)
    }

    // MARK: Helpers

    private func upload(_ data: Data, title: String, to receiver: PushTransferReceiver) {
        let token = createObject(receiver, title: title)
        var request = Data("POST /upload/\(token) HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        request.append(Data(String(data.count, radix: 16).utf8) + Data("\r\n".utf8) + data + Data("\r\n0\r\n\r\n".utf8))
        _ = exchange(receiver, request)
    }

    private func createObject(_ receiver: PushTransferReceiver, title: String) -> String {
        let didl = "<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><item><dc:title>\(title)</dc:title><res/></item></DIDL-Lite>"
        let envelope = "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><u:CreateObject>" +
            "<Elements>\(didl.xmlEscapedForPush)</Elements></u:CreateObject></s:Body></s:Envelope>"
        let response = exchange(receiver, Data(("POST /dms/control_0 HTTP/1.1\r\nSOAPACTION: \"#CreateObject\"\r\n" +
            "Content-Length: \(Data(envelope.utf8).count)\r\n\r\n" + envelope).utf8))
        return response.firstCapture(of: "upload/([0-9a-f]+)") ?? "missing"
    }

    private func exchange(_ receiver: PushTransferReceiver, _ request: String) -> String {
        exchange(receiver, Data(request.utf8))
    }

    private func exchange(_ receiver: PushTransferReceiver, _ request: Data) -> String {
        var response = Data()
        for case let .send(chunk) in PushHTTPConnectionProcessor(router: receiver).receive(request) { response.append(chunk) }
        return String(decoding: response, as: UTF8.self)
    }

    private func sha(_ data: Data) -> String {
        let file = directory.appendingPathComponent("hash-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        return (try? PushReceivedFile.sha256(of: file)) ?? ""
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            guard Date() < deadline else {
                XCTFail("Timed out; phase \(session.phase), items \(session.items.map(\.state))", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class NetworkSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    init(address: String?) { value = address }
    var address: String? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

@MainActor
private final class Harness {
    private(set) var servers: [FakePushServer] = []
    private(set) var announcers: [FakeAnnouncer] = []

    func makeServer(_ receiver: PushTransferReceiver) -> any PushTransferHTTPServing {
        let server = FakePushServer(receiver: receiver)
        servers.append(server)
        return server
    }

    func makeAnnouncer(_ emit: @escaping @Sendable (SSDPAnnouncerEvent) -> Void) -> any SSDPAnnouncing {
        let announcer = FakeAnnouncer(emit: emit)
        announcers.append(announcer)
        return announcer
    }
}

private final class FakePushServer: PushTransferHTTPServing, @unchecked Sendable {
    let receiver: PushTransferReceiver
    private let lock = NSLock()
    private var ports: [UInt16] = []
    private var stopCount = 0

    init(receiver: PushTransferReceiver) { self.receiver = receiver }

    var requestedPorts: [UInt16] { lock.withLock { ports } }
    var stops: Int { lock.withLock { stopCount } }

    func start(preferredPorts: [UInt16]) async throws -> UInt16 {
        lock.withLock { ports = preferredPorts }
        return preferredPorts.first ?? 50_000
    }

    func stop() { lock.withLock { stopCount += 1 } }
}

private final class FakeAnnouncer: SSDPAnnouncing, @unchecked Sendable {
    private let lock = NSLock()
    private let emit: @Sendable (SSDPAnnouncerEvent) -> Void

    init(emit: @escaping @Sendable (SSDPAnnouncerEvent) -> Void) { self.emit = emit }

    /// Delivers an SSDP event as the real announcer would from its network queue.
    func simulate(_ event: SSDPAnnouncerEvent) { emit(event) }

    private var startCount = 0
    private var goodbyeList: [Bool] = []
    private var announceCount = 0
    private var intervalList: [TimeInterval] = []

    var starts: Int { lock.withLock { startCount } }
    var goodbyes: [Bool] { lock.withLock { goodbyeList } }
    var announcements: Int { lock.withLock { announceCount } }
    var intervals: [TimeInterval] { lock.withLock { intervalList } }

    func start() throws { lock.withLock { startCount += 1 } }
    func announceNow() { lock.withLock { announceCount += 1 } }
    func setInterval(_ seconds: TimeInterval) { lock.withLock { intervalList.append(seconds) } }
    func stop(sayGoodbye: Bool) { lock.withLock { goodbyeList.append(sayGoodbye) } }
}

private actor RecordingPushImporter: CameraMediaImporting {
    private(set) var savedFilenames: [String] = []
    private var failure: Error?
    private var isHolding = false
    private var waiter: CheckedContinuation<Void, Never>?

    var isWaiting: Bool { waiter != nil }

    func fail(with error: Error?) { failure = error }
    func hold() { isHolding = true }

    func release() {
        isHolding = false
        waiter?.resume()
        waiter = nil
    }

    func save(_ media: DownloadedCameraMedia, geotag: GeotagMatch?) async throws {
        if isHolding { await withCheckedContinuation { waiter = $0 } }
        if let failure { throw failure }
        XCTAssertTrue(FileManager.default.fileExists(atPath: media.resources[0].fileURL.path))
        savedFilenames.append(media.resources[0].originalFilename)
    }
}
