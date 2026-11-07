import CoreGraphics
import Foundation
import XCTest
@testable import GM1Sync

@MainActor
final class RemoteShootingSessionTests: XCTestCase {
    private var camera: ScriptedRemoteCamera!
    private var source: FakeLiveViewSource!
    private var coordinator: CameraModeCoordinator!
    private var scope: CameraConnectionScope!
    private var session: RemoteShootingSession!

    override func setUp() async throws {
        scope = CameraConnectionScope()
        camera = ScriptedRemoteCamera(scope: scope)
        source = FakeLiveViewSource(port: 49_199)
        coordinator = CameraModeCoordinator(connectionScope: scope)
        let source = self.source!
        session = RemoteShootingSession(camera: camera, coordinator: coordinator, timing: .fast) { source }
    }

    override func tearDown() async throws {
        await session?.stop()
    }

    func testStartRequestsAccessSwitchesToRecordAndGoesLiveOnTheFirstFrame() async throws {
        await session.start()
        XCTAssertEqual(session.phase, .connecting("Starting live view…"))
        XCTAssertTrue(source.isRunning)
        let commands = await camera.commands
        let expectedOrder = [
            "mode=accctrl&type=req_acc&value=0&value2=GM1Sync",
            "mode=getstate",
            "mode=camcmd&value=recmode",
            "mode=getinfo&type=capability",
            "mode=getinfo&type=allmenu",
            "mode=getinfo&type=curmenu",
            "mode=getsetting&type=iso",
            "mode=getinfo&type=lens",
            "mode=startstream&value=49199"
        ]
        let positions = expectedOrder.map { command in commands.firstIndex(of: command) ?? -1 }
        XCTAssertFalse(positions.contains(-1), "Missing commands in \(commands)")
        XCTAssertEqual(positions, positions.sorted())

        source.emitFrame()
        try await waitUntil { self.session.phase == .live }
        XCTAssertEqual(session.framesReceived, 1)
        XCTAssertNotNil(session.frame)
        XCTAssertEqual(coordinator.exclusiveActivity, .remoteShooting)
        XCTAssertTrue(session.controls.hasCameraMenus)
        XCTAssertEqual(session.controls.settings.first { $0.kind == .iso }?.currentLabel, "i.Auto")
    }

    func testGalleryPreparationWaitsUntilRemoteShootingEnds() async throws {
        await session.start()
        let log = OperationLog()
        let preparation = Task { @MainActor in
            try await self.coordinator.performSharedOperation { await log.append("playmode") }
        }
        try await Task.sleep(for: .milliseconds(80))
        let duringShooting = await log.entries
        XCTAssertTrue(duringShooting.isEmpty)

        await camera.startRecording()
        try await waitUntil { self.session.isRecordingVideo }
        await session.stop()
        try await preparation.value
        let afterShooting = await log.entries
        XCTAssertEqual(afterShooting, ["playmode"])
        XCTAssertEqual(session.phase, .ended)
        XCTAssertFalse(source.isRunning)
        let commands = await camera.commands
        XCTAssertTrue(commands.contains("mode=camcmd&value=video_recstop"), "Leaving the screen stops a recording it controlled")
        XCTAssertEqual(commands.last, "mode=stopstream")
        XCTAssertEqual(coordinator.completedExclusiveActivities, 1)
    }

    func testRemoteShootingWaitsForAGalleryPreparationInFlight() async throws {
        let gate = AsyncGate()
        let preparation = Task { @MainActor in
            try await self.coordinator.performSharedOperation { await gate.wait() }
        }
        try await Task.sleep(for: .milliseconds(30))
        let start = Task { @MainActor in await self.session.start() }
        try await Task.sleep(for: .milliseconds(80))
        let beforeRelease = await camera.commands
        XCTAssertTrue(beforeRelease.isEmpty, "No remote command may race the gallery's playmode switch")

        await gate.open()
        try await preparation.value
        await start.value
        let afterRelease = await camera.commands
        XCTAssertTrue(afterRelease.contains("mode=camcmd&value=recmode"))
    }

    func testBackgroundStopsTheStreamAndForegroundRestartsIt() async throws {
        await session.start()
        source.emitFrame()
        try await waitUntil { self.session.phase == .live }

        await session.setAppActive(false)
        XCTAssertEqual(session.phase, .paused(.appInBackground))
        XCTAssertFalse(source.isRunning)
        var commands = await camera.commands
        XCTAssertEqual(commands.last, "mode=stopstream")
        XCTAssertEqual(coordinator.exclusiveActivity, .remoteShooting, "The camera stays reserved while paused")

        await session.setAppActive(true)
        XCTAssertTrue(source.isRunning)
        commands = await camera.commands
        XCTAssertEqual(commands.last, "mode=startstream&value=49199")
        source.emitFrame()
        try await waitUntil { self.session.phase == .live }
        XCTAssertEqual(source.startCount, 2)
    }

    func testCaptureRetriesWhileBusyAndConfirmsTheCardWrite() async throws {
        await session.start()
        source.emitFrame()
        try await waitUntil { self.session.phase == .live }
        await camera.enqueue("mode=camcmd&value=capture", ["<camrply><result>err_busy</result></camrply>"])
        await camera.enqueue("mode=camcmd&value=capture_cancel", ["<camrply><result>err_retry</result></camrply>"])

        await session.capturePhoto()
        let commands = await camera.commands
        XCTAssertEqual(commands.filter { $0 == "mode=camcmd&value=capture" }.count, 2)
        XCTAssertEqual(commands.filter { $0 == "mode=camcmd&value=capture_cancel" }.count, 2)
        XCTAssertEqual(session.notice?.style, .success)
        XCTAssertEqual(session.notice?.message, "Photo saved to the camera's card.")
        XCTAssertFalse(session.isShutterPressed)
    }

    func testCaptureWithoutCardActivityIsReportedAsUnconfirmed() async throws {
        await session.start()
        source.emitFrame()
        try await waitUntil { self.session.phase == .live }
        await camera.setCaptureWritesToCard(false)

        await session.capturePhoto()
        XCTAssertEqual(session.notice?.style, .warning)
    }

    func testLostConnectionPausesAndRecoversWhenTheCameraReplies() async throws {
        await session.start()
        source.emitFrame()
        try await waitUntil { self.session.phase == .live }

        await camera.setFailing(true)
        try await waitUntil { self.session.phase == .paused(.connectionLost) }
        XCTAssertFalse(source.isRunning)

        await camera.setFailing(false)
        try await waitUntil { self.source.isRunning }
        source.emitFrame()
        try await waitUntil { self.session.phase == .live }
    }

    func testCameraPlaybackPausesUntilTheCameraReturnsToRecording() async throws {
        await session.start()
        source.emitFrame()
        try await waitUntil { self.session.phase == .live }

        await camera.setMode("play")
        try await waitUntil { self.session.phase == .paused(.cameraInPlayback) }
        XCTAssertFalse(source.isRunning)
        let commands = await camera.commands
        XCTAssertEqual(commands.filter { $0 == "mode=camcmd&value=recmode" }.count, 1,
                       "The app must not pull the camera out of playback while someone uses it")

        await camera.setMode("rec")
        try await waitUntil { self.source.isRunning }
        source.emitFrame()
        try await waitUntil { self.session.phase == .live }
    }

    func testStalledLiveViewRequestsTheStreamAgain() async throws {
        await session.start()
        source.emitFrame()
        try await waitUntil { self.session.phase == .live }
        try await waitUntil {
            await self.camera.commands.filter { $0 == "mode=startstream&value=49199" }.count >= 2
        }
        try await waitUntil { self.session.phase == .paused(.liveViewStalled) }
        source.emitFrame()
        try await waitUntil { self.session.phase == .live }
    }

    func testStaleConnectionEndsTheSessionWithoutReachingTheNewCamera() async throws {
        await session.start()
        source.emitFrame()
        try await waitUntil { self.session.phase == .live }

        scope.invalidate()
        try await waitUntil {
            if case .failed = self.session.phase { return true }
            return false
        }
        let countAfterFailure = await camera.commands.count
        await session.capturePhoto()
        try await Task.sleep(for: .milliseconds(100))
        let finalCount = await camera.commands.count
        XCTAssertEqual(finalCount, countAfterFailure)
        XCTAssertFalse(source.isRunning)
        XCTAssertNil(coordinator.exclusiveActivity)
    }

    func testConnectionChangeRevokesTheSession() async throws {
        await session.start()
        source.emitFrame()
        try await waitUntil { self.session.phase == .live }
        coordinator.connectionDidChange()
        XCTAssertFalse(source.isRunning)
        guard case .failed = session.phase else { return XCTFail("Expected a failed phase, got \(session.phase)") }
    }

    func testTouchSendsCameraGridCoordinatesAndTouchShutterCaptures() async throws {
        await session.start()
        source.emitFrame()
        try await waitUntil { self.session.phase == .live }

        await session.touch(at: CGPoint(x: 0.25, y: 0.754))
        var commands = await camera.commands
        XCTAssertEqual(commands.last, "mode=camctrl&type=touch&value=250/754&value2=on")

        session.touchMode = .shutter
        await session.touch(at: CGPoint(x: 1.4, y: -0.2))
        commands = await camera.commands
        let touchIndex = try XCTUnwrap(commands.lastIndex(of: "mode=camctrl&type=touch&value=1000/0&value2=on"))
        XCTAssertTrue(commands[(touchIndex + 1)...].contains("mode=camcmd&value=capture"), "Touch shutter focuses, then captures")
    }

    func testTouchShutterInManualFocusCapturesWithoutAnAFPoint() async throws {
        await camera.setSetting("focusmode", "mf")
        await session.start()
        source.emitFrame()
        try await waitUntil { self.session.phase == .live }
        XCTAssertTrue(session.controls.isManualFocus)

        session.touchMode = .shutter
        await session.touch(at: CGPoint(x: 0.5, y: 0.5))
        let commands = await camera.commands
        XCTAssertFalse(commands.contains { $0.hasPrefix("mode=camctrl&type=touch") })
        XCTAssertTrue(commands.contains("mode=camcmd&value=capture"))
    }

    func testApplyingAnAdvertisedOptionSendsTheCameraCommand() async throws {
        await session.start()
        source.emitFrame()
        try await waitUntil { self.session.phase == .live }
        let iso = try XCTUnwrap(session.controls.settings.first { $0.kind == .iso })
        let option = try XCTUnwrap(iso.options.first { $0.value == "800" })

        await session.apply(option, to: iso)
        let commands = await camera.commands
        XCTAssertTrue(commands.contains("mode=setsetting&type=iso&value=800"))
        XCTAssertEqual(session.controls.settings.first { $0.kind == .iso }?.currentValue, "800")
        XCTAssertEqual(session.notice?.message, "ISO: \(option.label)")
        XCTAssertEqual(session.notice?.style, .success)
    }

    func testASettingTheCameraAcknowledgesButDoesNotApplyIsReported() async throws {
        await session.start()
        source.emitFrame()
        try await waitUntil { self.session.phase == .live }
        // A GM1S answered ok to burst drive mode and still reported single shot.
        await camera.ignoreSetting("iso")
        let iso = try XCTUnwrap(session.controls.settings.first { $0.kind == .iso })
        let option = try XCTUnwrap(iso.options.first { $0.value == "800" })

        await session.apply(option, to: iso)
        XCTAssertEqual(session.controls.settings.first { $0.kind == .iso }?.currentLabel, "i.Auto")
        XCTAssertEqual(session.notice?.message, "The camera accepted ISO: \(option.label) but still reports i.Auto.")
        XCTAssertEqual(session.notice?.style, .warning)
    }

    func testUnsupportedZoomIsReportedOnce() async throws {
        await camera.enqueue("mode=camcmd&value=tele-normal", ["<camrply><result>err_non_support</result></camrply>"])
        await session.start()
        source.emitFrame()
        try await waitUntil { self.session.phase == .live }
        XCTAssertTrue(session.controls.supportsPowerZoom)

        await session.startZoom(.tele, fast: false)
        await session.stopZoom()
        XCTAssertEqual(session.zoomUnavailableMessage, "This lens can't be zoomed from the phone.")
        let commands = await camera.commands
        XCTAssertFalse(commands.contains("mode=camcmd&value=zoomstop"), "No stop is sent for a zoom that never started")
    }

    func testCameraApprovalIsAwaitedBeforeTakingControl() async throws {
        await camera.enqueue("mode=accctrl&type=req_acc&value=0&value2=GM1Sync", ["ok_under_research", "ok_under_research"])
        await session.start()
        let requests = await camera.commands.filter { $0.hasPrefix("mode=accctrl") }
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(session.phase, .connecting("Starting live view…"))
    }

    func testDeclinedAccessFailsWithoutSwitchingModes() async throws {
        await camera.enqueue("mode=accctrl&type=req_acc&value=0&value2=GM1Sync", ["err_already_connected"])
        await session.start()
        XCTAssertEqual(session.phase, .failed(LumixResultCode.message(for: "err_already_connected")))
        let commands = await camera.commands
        XCTAssertFalse(commands.contains("mode=camcmd&value=recmode"))
        XCTAssertNil(coordinator.exclusiveActivity)
    }

    func testStartWaitsWhileTheCameraAnswersOverloaded() async throws {
        await camera.setOverloaded(3)
        await session.start()
        XCTAssertEqual(session.phase, .connecting("Starting live view…"))
        let commands = await camera.commands
        XCTAssertEqual(commands.filter { $0.hasPrefix("503 ") }.count, 3)
        XCTAssertEqual(commands.last, "mode=startstream&value=49199")
        source.emitFrame()
        try await waitUntil { self.session.phase == .live }
    }

    func testStartGivesUpReadablyWhenTheCameraStaysOverloaded() async throws {
        var timing = RemoteShootingTiming.fast
        timing.overloadWaitTimeout = 0.05
        let source = self.source!
        session = RemoteShootingSession(camera: camera, coordinator: coordinator, timing: timing) { source }
        await camera.setOverloaded(.max)
        await session.start()
        guard case let .failed(message) = session.phase else {
            return XCTFail("Expected a failure, got \(session.phase)")
        }
        XCTAssertFalse(message.contains("<"), message)
        XCTAssertTrue(message.contains("busy"), message)
        XCTAssertNil(coordinator.exclusiveActivity, "The camera is returned to the rest of the app")
        XCTAssertFalse(source.isRunning)
    }

    // MARK: Helpers

    private func waitUntil(
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            guard Date() < deadline else {
                XCTFail("Timed out; phase \(session.phase)", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

extension RemoteShootingTiming {
    static var fast: RemoteShootingTiming {
        var timing = RemoteShootingTiming()
        timing.pollInterval = .milliseconds(20)
        timing.settingsRefreshInterval = 0.05
        timing.menuRefreshInterval = 0.1
        timing.frameStallTimeout = 0.15
        timing.streamRestartInterval = 0.05
        timing.stalledRestartLimit = 2
        timing.connectionFailureLimit = 3
        timing.modeSwitchSettle = .milliseconds(1)
        timing.busyRetryDelay = .milliseconds(1)
        timing.approvalPollInterval = .milliseconds(5)
        timing.captureConfirmationTimeout = 0.3
        timing.captureConfirmationPollInterval = .milliseconds(10)
        timing.shutterReleaseRetryInterval = .milliseconds(2)
        timing.manualFocusRepeatInterval = .milliseconds(10)
        timing.overloadRetryDelay = .milliseconds(5)
        timing.overloadWaitTimeout = 2
        return timing
    }
}

/// A camera that answers like a GM-family body, with per-command overrides.
actor ScriptedRemoteCamera: RemoteCameraControlling {
    nonisolated let host = "127.0.0.1"
    private nonisolated let scope: CameraConnectionScope
    private nonisolated let token: CameraConnectionToken

    private(set) var commands: [String] = []
    private var overrides: [String: [String]] = [:]
    private var mode = "play"
    private var remaining = 100
    private var cardBusy = false
    private var captureWritesToCard = true
    private var isRecording = false
    private var isFailing = false
    private var overloadedReplies = 0
    private var ignoredSettings: Set<String> = []
    private var settings = ["iso": "auto", "whitebalance": "auto", "drivemode": "normal",
                            "focusmode": "afs", "afmode": "1area", "exposure": "0",
                            "focal": "1024/256", "shtrspeed": "1536/256"]

    init(scope: CameraConnectionScope) {
        self.scope = scope
        token = scope.current
    }

    nonisolated var belongsToCurrentConnection: Bool { scope.isCurrent(token) }

    func enqueue(_ command: String, _ replies: [String]) { overrides[command, default: []].append(contentsOf: replies) }
    func setMode(_ value: String) { mode = value }
    func setFailing(_ value: Bool) { isFailing = value }
    /// Answers the next `count` requests the way an overloaded GM1S does.
    func setOverloaded(_ count: Int) { overloadedReplies = count }
    func setCaptureWritesToCard(_ value: Bool) { captureWritesToCard = value }
    func startRecording() { isRecording = true }
    func setSetting(_ type: String, _ value: String) { settings[type] = value }
    /// Answers `ok` to `setsetting` for this type without changing it.
    func ignoreSetting(_ type: String) { ignoredSettings.insert(type) }

    func perform(_ command: LumixCommand, timeoutInterval: TimeInterval?) async throws -> LumixCommandReply {
        guard belongsToCurrentConnection else { throw LumixError.staleConnection }
        if isFailing { throw URLError(.timedOut) }
        if overloadedReplies > 0 {
            overloadedReplies -= 1
            commands.append("503 " + command.description)
            throw LumixError.http(503, "<HTML><HEAD><TITLE>503 Service Temporarily Overloaded</TITLE></HEAD></HTML>")
        }
        let key = command.description
        commands.append(key)
        if var queued = overrides[key], !queued.isEmpty {
            let reply = queued.removeFirst()
            overrides[key] = queued
            return LumixCommandReply.parse(reply)
        }
        return LumixCommandReply.parse(defaultReply(command))
    }

    private func defaultReply(_ command: LumixCommand) -> String {
        let ok = "<camrply><result>ok</result></camrply>"
        switch (command.mode, command.type, command.value) {
        case ("getstate", _, _):
            let busy = cardBusy
            cardBusy = false
            return "<camrply><result>ok</result><state><batt>3/3</batt><cammode>\(mode)</cammode>" +
                "<remaincapacity>\(remaining)</remaincapacity><rec>\(isRecording ? "on" : "off")</rec>" +
                "<sd_access>\(busy ? "on" : "off")</sd_access></state></camrply>"
        case ("accctrl", _, _): return "ok,GM1S-TEST,remote,encrypted"
        case ("camcmd", _, "recmode"?):
            mode = "rec"
            return ok
        case ("camcmd", _, "capture"?):
            if captureWritesToCard {
                remaining -= 1
                cardBusy = true
            }
            return ok
        case ("camcmd", _, "video_recstop"?):
            isRecording = false
            return ok
        case ("getsetting", let type?, _):
            guard let value = settings[type] else { return "<camrply><result>err_param</result></camrply>" }
            return "<camrply><result>ok</result><settingvalue \(type)=\"\(value)\"></settingvalue></camrply>"
        case ("setsetting", let type?, let value?):
            if !ignoredSettings.contains(type) { settings[type] = value }
            return ok
        case ("getinfo", "capability"?, _):
            return "<camrply><result>ok</result><comm_proto_ver>1.3</comm_proto_ver><camcmdlist>" +
                "<camcmd>tele-normal</camcmd><camcmd>wide-normal</camcmd></camcmdlist></camrply>"
        case ("getinfo", "allmenu"?, _): return LumixRemoteProtocolTests.allMenu.replacingOccurrences(
            of: "<item id=\"menu_item_id_sensitivity_400\"",
            with: "<item id=\"menu_item_id_sensitivity_800\" title_id=\"t_iso_400\" cmd_mode=\"setsetting\" cmd_type=\"iso\" cmd_value=\"800\" />\n<item id=\"menu_item_id_sensitivity_400\""
        )
        case ("getinfo", "curmenu"?, _):
            return "<camrply><result>ok</result><menuinfo><item id=\"menu_item_id_f_and_ss\" enable=\"yes\" />" +
                "<item id=\"menu_item_id_sensitivity\" enable=\"yes\" value=\"\(settings["iso"] ?? "")\" /></menuinfo></camrply>"
        case ("getinfo", "lens"?, _): return "ok,2304/256,768/256,3584/256,-1536/256,0,on,32,12,on,128/1024,on"
        default:
            return ok
        }
    }
}

/// A live-view source the test drives frame by frame.
final class FakeLiveViewSource: LumixLiveViewSource, @unchecked Sendable {
    private let lock = NSLock()
    private let port: UInt16
    private var handler: (@Sendable (LumixLiveViewEvent) -> Void)?
    private var starts = 0
    private let image: CGImage

    init(port: UInt16) {
        self.port = port
        let context = CGContext(data: nil, width: 4, height: 3, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        image = context.makeImage()!
    }

    var isRunning: Bool { lock.withLock { handler != nil } }
    var startCount: Int { lock.withLock { starts } }

    func start(handler: @escaping @Sendable (LumixLiveViewEvent) -> Void) throws -> UInt16 {
        lock.withLock {
            self.handler = handler
            starts += 1
        }
        return port
    }

    func stop() {
        lock.withLock { handler = nil }
    }

    func emitFrame() {
        let handler = lock.withLock { self.handler }
        handler?(.frame(LumixLiveViewFrame(image: image, metadata: LumixLiveViewFrameMetadata(), receivedAt: Date())))
    }
}
