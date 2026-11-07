import Foundation
import XCTest
@testable import GM1Sync

@MainActor
final class CameraGeotagWriterTests: XCTestCase {
    private var scope: CameraConnectionScope!
    private var camera: ScriptedGeotagCamera!
    private var coordinator: CameraModeCoordinator!
    private let fixedNow = ISO8601DateFormatter().date(from: "2026-10-21T12:34:56Z")!
    private let plusSeven = TimeZone(secondsFromGMT: 7 * 3600)!

    override func setUp() async throws {
        scope = CameraConnectionScope()
        camera = ScriptedGeotagCamera(scope: scope)
        coordinator = CameraModeCoordinator(connectionScope: scope)
    }

    private func makeWriter(timing: CameraGeotagTiming = .fast) -> CameraGeotagWriter {
        let fixed = fixedNow
        // Deadline tests need a moving clock; the rest use a fixed instant.
        let clock: @Sendable () -> Date
        if timing.writeDeadline < 1 {
            clock = { Date() }
        } else {
            clock = { fixed }
        }
        return CameraGeotagWriter(camera: camera, coordinator: coordinator, timing: timing, timeZone: plusSeven, now: clock)
    }

    private func selection() throws -> CameraGeodataSelection {
        let start = fixedNow.addingTimeInterval(-3600)
        let samples = (0..<10).map { index in
            LocationSample(timestamp: start.addingTimeInterval(TimeInterval(index * 60)),
                           latitude: 1.25 + Double(index) * 0.001, longitude: -2.5, altitude: 12, horizontalAccuracy: 8)
        }
        return try CameraGeodataSelection(samples: samples, period: start...fixedNow)
    }

    func testFullWriteFollowsImageAppOrderAndReportsOnlyTheCameraFinish() async throws {
        let writer = makeWriter()
        let selection = try selection()
        await writer.run(selection)

        guard case let .finished(report) = writer.phase else { return XCTFail("Expected finish, got \(writer.phase)") }
        XCTAssertEqual(report.recordCount, 11)
        XCTAssertEqual(report.clockNotification, "20261021123456+0700")
        let requests = await camera.requests
        let order = [
            "mode=camcmd&value=playmode",
            "mode=notify&type=clock&value=20261021123456%2B0700",
            "mode=startsenddata&type=geodata&value=\(selection.payload.count)&value2=1",
            "POST mode=senddata&value2=1",
            "mode=camctrl&type=add_location_data&value=start",
            "mode=getprogress&type=add_location_data"
        ]
        let positions = order.map { requests.firstIndex(of: $0) ?? -1 }
        XCTAssertFalse(positions.contains(-1), "Missing requests in \(requests)")
        XCTAssertEqual(positions, positions.sorted())
        XCTAssertFalse(requests.contains("mode=camctrl&type=add_location_data&value=abort"))
        let body = await camera.uploadedBody
        XCTAssertEqual(body, LumixGeodataUpload.body(for: selection.payload))
        let contentType = await camera.uploadedContentType
        XCTAssertEqual(contentType, "multipart/form-data; boundary=xyzxyz")
        XCTAssertNil(coordinator.exclusiveActivity)
        XCTAssertEqual(coordinator.completedExclusiveActivities, 1, "The gallery reloads after the write")
    }

    func testClockNotificationFallsBackToARawPlusWhenTheCameraRejectsTheEncodedForm() async throws {
        await camera.override("mode=notify&type=clock&value=20261021123456%2B0700", with: ["<camrply><result>err_param</result></camrply>"])
        let writer = makeWriter()
        await writer.run(try selection())
        guard case .finished = writer.phase else { return XCTFail("Expected finish, got \(writer.phase)") }
        let requests = await camera.requests
        XCTAssertTrue(requests.contains("mode=notify&type=clock&value=20261021123456+0700"))
        XCTAssertTrue(writer.steps.contains { $0.contains("raw '+'") })
    }

    func testRejectedAnnouncementNeverUploadsOrStartsWriting() async throws {
        await camera.override("startsenddata", with: ["<camrply><result>ok</result></camrply>"])
        let writer = makeWriter()
        await writer.run(try selection())
        guard case let .failed(message) = writer.phase else { return XCTFail("Expected failure, got \(writer.phase)") }
        XCTAssertTrue(message.contains("refused"))
        let requests = await camera.requests
        XCTAssertFalse(requests.contains("POST mode=senddata&value2=1"))
        XCTAssertFalse(requests.contains { $0.contains("add_location_data") })
        XCTAssertNil(coordinator.exclusiveActivity)
    }

    func testRejectedUploadNeverStartsWritingEvenWithHTTPSuccess() async throws {
        await camera.override("POST mode=senddata&value2=1", with: ["<camrply><result>err_param</result></camrply>"])
        let writer = makeWriter()
        await writer.run(try selection())
        guard case let .failed(message) = writer.phase else { return XCTFail("Expected failure, got \(writer.phase)") }
        XCTAssertTrue(message.contains("rejected the uploaded track"))
        let requests = await camera.requests
        XCTAssertFalse(requests.contains { $0.contains("add_location_data") })
    }

    func testCameraErrorStateIsReportedAsAFailure() async throws {
        await camera.setProgressScript(["exec", "error:nodata"])
        let writer = makeWriter()
        await writer.run(try selection())
        guard case let .failed(message) = writer.phase else { return XCTFail("Expected failure, got \(writer.phase)") }
        XCTAssertTrue(message.contains("nodata"))
    }

    func testCancelDuringWritingSendsAbortAndWaitsForTheCamera() async throws {
        await camera.setProgressScript(Array(repeating: "exec", count: 1_000))
        let writer = makeWriter()
        let selection = try selection()
        let run = Task { await writer.run(selection) }
        try await waitUntil { if case .writing = writer.phase { return true }; return false }
        writer.cancel()
        await run.value

        guard case let .cancelled(message) = writer.phase else { return XCTFail("Expected cancelled, got \(writer.phase)") }
        XCTAssertTrue(message.contains("Some photos may already contain locations"))
        let requests = await camera.requests
        XCTAssertTrue(requests.contains("mode=camctrl&type=add_location_data&value=abort"))
        XCTAssertNil(coordinator.exclusiveActivity)
    }

    func testCancelBeforeWritingNeverAsksTheCameraToWrite() async throws {
        await camera.setDelay(.milliseconds(150), for: "startsenddata")
        let writer = makeWriter()
        let selection = try selection()
        let run = Task { await writer.run(selection) }
        try await waitUntil { await self.camera.requests.contains { $0.hasPrefix("mode=notify") } }
        writer.cancel()
        await run.value
        guard case let .cancelled(message) = writer.phase else { return XCTFail("Expected cancelled, got \(writer.phase)") }
        XCTAssertTrue(message.contains("No photos were changed"))
        let requests = await camera.requests
        XCTAssertFalse(requests.contains { $0.contains("add_location_data") })
    }

    func testDeadlineAbortsTheWriteAndFails() async throws {
        await camera.setProgressScript(Array(repeating: "exec", count: 1_000))
        var timing = CameraGeotagTiming.fast
        timing.writeDeadline = 0.1
        let writer = makeWriter(timing: timing)
        await writer.run(try selection())
        guard case let .failed(message) = writer.phase else { return XCTFail("Expected failure, got \(writer.phase)") }
        XCTAssertTrue(message.contains("deadline"))
        let requests = await camera.requests
        XCTAssertTrue(requests.contains("mode=camctrl&type=add_location_data&value=abort"))
    }

    func testStaleConnectionStopsWithoutReachingTheNewCamera() async throws {
        await camera.setProgressScript(Array(repeating: "exec", count: 1_000))
        let writer = makeWriter()
        let selection = try selection()
        let run = Task { await writer.run(selection) }
        try await waitUntil { if case .writing = writer.phase { return true }; return false }
        scope.invalidate()
        let countAtInvalidation = await camera.requests.count
        await run.value
        guard case let .failed(message) = writer.phase else { return XCTFail("Expected failure, got \(writer.phase)") }
        XCTAssertTrue(message.contains("connection changed"))
        let finalCount = await camera.requests.count
        XCTAssertEqual(finalCount, countAtInvalidation, "No request may reach the next camera, not even an abort")
    }

    func testGalleryPreparationWaitsWhileTheWriteHoldsTheCamera() async throws {
        await camera.setProgressScript(Array(repeating: "exec", count: 60) + ["finish"])
        let writer = makeWriter()
        let selection = try selection()
        let run = Task { await writer.run(selection) }
        try await waitUntil { if case .writing = writer.phase { return true }; return false }

        let log = OperationLog()
        let preparation = Task { @MainActor in
            try await self.coordinator.performSharedOperation { await log.append("playmode") }
        }
        try await Task.sleep(for: .milliseconds(60))
        let duringWrite = await log.entries
        XCTAssertTrue(duringWrite.isEmpty, "Browsing must not switch modes while the camera writes")
        await run.value
        try await preparation.value
        let afterWrite = await log.entries
        XCTAssertEqual(afterWrite, ["playmode"])
    }

    func testUnansweredProgressFailsHonestly() async throws {
        await camera.setProgressFailures(true)
        let writer = makeWriter()
        await writer.run(try selection())
        guard case let .failed(message) = writer.phase else { return XCTFail("Expected failure, got \(writer.phase)") }
        XCTAssertTrue(message.contains("check the photos"))
    }

    // MARK: Clock

    func testClockSyncSetsTheNextWholeMinuteAndReadsTheClockBack() async throws {
        let target = TargetRecorder()
        let now = fixedNow
        let synchronizer = CameraClockSynchronizer(
            camera: camera, coordinator: coordinator, timeZone: plusSeven,
            now: { now }, waitUntil: { await target.record($0) }
        )
        await synchronizer.synchronize()

        guard case let .finished(result) = synchronizer.phase else { return XCTFail("Expected finish, got \(synchronizer.phase)") }
        XCTAssertEqual(result.sentValue, "20261021123500+0700")
        let waited = await target.date
        XCTAssertEqual(waited, ISO8601DateFormatter().date(from: "2026-10-21T12:35:00Z"))
        let requests = await camera.requests
        XCTAssertTrue(requests.contains("mode=setsetting&type=clock&value=20261021123500%2B0700"))
        XCTAssertEqual(result.after?.raw, "20261021123500+0700")
        XCTAssertNil(coordinator.exclusiveActivity)
    }

    func testClockSyncReportsACameraThatDoesNotAcceptIt() async throws {
        await camera.override("mode=setsetting&type=clock&value=20261021123500%2B0700", with: ["<camrply><result>err_non_support</result></camrply>"])
        let now = fixedNow
        let synchronizer = CameraClockSynchronizer(camera: camera, coordinator: coordinator, timeZone: plusSeven,
                                                   now: { now }, waitUntil: { _ in })
        await synchronizer.synchronize()
        guard case let .failed(message) = synchronizer.phase else { return XCTFail("Expected failure, got \(synchronizer.phase)") }
        XCTAssertTrue(message.contains("does not accept"))
    }

    func testCancellingTheClockCountdownLeavesTheClockUnchanged() async throws {
        let synchronizer = CameraClockSynchronizer(camera: camera, coordinator: coordinator, timeZone: plusSeven,
                                                   waitUntil: { _ in try await Task.sleep(for: .seconds(30)) })
        synchronizer.start()
        try await waitUntil { if case .waiting = synchronizer.phase { return true }; return false }
        synchronizer.cancel()
        try await waitUntil { synchronizer.phase == .cancelled }
        let requests = await camera.requests
        XCTAssertFalse(requests.contains { $0.hasPrefix("mode=setsetting&type=clock") })
        XCTAssertNil(coordinator.exclusiveActivity)
    }

    // MARK: Helpers

    private func waitUntil(timeout: TimeInterval = 3, _ condition: @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            guard Date() < deadline else { return XCTFail("Timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

extension CameraGeotagTiming {
    static var fast: CameraGeotagTiming {
        var timing = CameraGeotagTiming()
        timing.pollInterval = .milliseconds(5)
        timing.busyRetryDelay = .milliseconds(1)
        timing.modeSwitchSettle = .milliseconds(1)
        timing.abortConfirmationTimeout = 2
        timing.unansweredPollLimit = 4
        return timing
    }
}

private actor TargetRecorder {
    private(set) var date: Date?
    func record(_ date: Date) { self.date = date }
}

/// A camera that answers the location-writing commands like Image App expects.
actor ScriptedGeotagCamera: CameraGeotagControlling {
    nonisolated let host = "127.0.0.1"
    private nonisolated let scope: CameraConnectionScope
    private nonisolated let token: CameraConnectionToken

    private(set) var requests: [String] = []
    private(set) var uploadedBody: Data?
    private(set) var uploadedContentType: String?
    private var overrides: [String: [String]] = [:]
    private var delays: [String: Duration] = [:]
    private var progressScript = ["prepare", "exec", "finish"]
    private var progressFailures = false
    private var aborted = false
    private var clock = "20261021120000+0700"

    init(scope: CameraConnectionScope) {
        self.scope = scope
        token = scope.current
    }

    nonisolated var belongsToCurrentConnection: Bool { scope.isCurrent(token) }

    func override(_ key: String, with replies: [String]) { overrides[key, default: []].append(contentsOf: replies) }
    func setDelay(_ delay: Duration, for prefix: String) { delays[prefix] = delay }
    func setProgressScript(_ script: [String]) { progressScript = script }
    func setProgressFailures(_ value: Bool) { progressFailures = value }

    func perform(_ command: LumixCommand, timeoutInterval: TimeInterval?) async throws -> LumixCommandReply {
        try await handle(command.description) { self.defaultReply(command) }
    }

    func perform(percentEncodedQuery: String, body: Data?, contentType: String?, timeoutInterval: TimeInterval?) async throws -> LumixCommandReply {
        let key = body == nil ? percentEncodedQuery : "POST " + percentEncodedQuery
        return try await handle(key) {
            if let body {
                self.uploadedBody = body
                self.uploadedContentType = contentType
                return "<camrply><result>ok</result></camrply>"
            }
            if percentEncodedQuery.hasPrefix("mode=setsetting&type=clock&value=") {
                self.clock = String(percentEncodedQuery.dropFirst("mode=setsetting&type=clock&value=".count))
                    .replacingOccurrences(of: "%2B", with: "+")
            }
            return "<camrply><result>ok</result></camrply>"
        }
    }

    private func handle(_ key: String, _ fallback: () -> String) async throws -> LumixCommandReply {
        guard belongsToCurrentConnection else { throw LumixError.staleConnection }
        if key.hasPrefix("mode=getprogress"), progressFailures { throw URLError(.timedOut) }
        requests.append(key)
        if let delay = delays.first(where: { key.hasPrefix($0.key) || key.contains($0.key) })?.value {
            try await Task.sleep(for: delay)
        }
        if let prefixKey = overrides.keys.first(where: { key == $0 || key.contains($0) }),
           var queue = overrides[prefixKey], !queue.isEmpty {
            let reply = queue.removeFirst()
            overrides[prefixKey] = queue
            return LumixCommandReply.parse(reply)
        }
        return LumixCommandReply.parse(fallback())
    }

    private func defaultReply(_ command: LumixCommand) -> String {
        switch (command.mode, command.type, command.value) {
        case ("startsenddata", _, _):
            return "<camrply><result>ok</result><method>once</method></camrply>"
        case ("camctrl", "add_location_data"?, "abort"?):
            aborted = true
            return "<camrply><result>ok</result></camrply>"
        case ("getprogress", _, _):
            if aborted {
                return "<camrply><result>ok</result><state>error</state><progress>50</progress><err>cancel</err></camrply>"
            }
            let next = progressScript.isEmpty ? "finish" : progressScript.removeFirst()
            if next.hasPrefix("error:") {
                return "<camrply><result>ok</result><state>error</state><err>\(next.dropFirst(6))</err></camrply>"
            }
            return "<camrply><result>ok</result><state>\(next)</state><progress>\(next == "finish" ? 100 : 30)</progress><err></err></camrply>"
        case ("getsetting", "clock"?, _):
            return "<camrply><result>ok</result><settingvalue clock=\"\(clock)\"></settingvalue></camrply>"
        default:
            return "<camrply><result>ok</result></camrply>"
        }
    }
}
