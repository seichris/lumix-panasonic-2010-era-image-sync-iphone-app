import Foundation

extension CameraActivity {
    static let geotagWrite = CameraActivity(id: "geotag-write", title: "Writing locations to camera photos", mode: .playback)
    static let clockSync = CameraActivity(id: "clock-sync", title: "Setting the camera clock", mode: nil)
}

/// Location writing needs pre-encoded queries (`%2B` in clock values) and the
/// multipart track upload in addition to ordinary `cam.cgi` commands.
protocol CameraGeotagControlling: RemoteCameraControlling {
    func perform(
        percentEncodedQuery: String,
        body: Data?,
        contentType: String?,
        timeoutInterval: TimeInterval?
    ) async throws -> LumixCommandReply
}

extension LumixClient: CameraGeotagControlling {}

extension CameraGeotagControlling {
    /// Sends `mode=<mode>&type=clock&value=<value>` with `+` encoded as `%2B`.
    /// If the camera answers `err_param`, it retries once with a raw `+`
    /// (lumix-link-desktop sends it unencoded). Which form the GM1S expects is unverified.
    func sendClockValue(
        mode: String,
        value: String,
        busyRetries: Int = 5,
        busyDelay: Duration = .seconds(1)
    ) async throws -> (reply: LumixCommandReply, usedRawPlus: Bool) {
        var reply = try await sendPercentEncoded(
            LumixCameraClock.percentEncodedQuery(mode: mode, type: "clock", value: value, encodePlus: true),
            busyRetries: busyRetries, busyDelay: busyDelay
        )
        guard reply.result == "err_param", value.contains("+") else { return (reply, false) }
        reply = try await sendPercentEncoded(
            LumixCameraClock.percentEncodedQuery(mode: mode, type: "clock", value: value, encodePlus: false),
            busyRetries: busyRetries, busyDelay: busyDelay
        )
        return (reply, true)
    }

    private func sendPercentEncoded(
        _ query: String,
        busyRetries: Int,
        busyDelay: Duration
    ) async throws -> LumixCommandReply {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let reply = try await perform(percentEncodedQuery: query, body: nil, contentType: nil, timeoutInterval: nil)
            guard reply.isBusy, attempt < busyRetries else { return reply }
            attempt += 1
            try await Task.sleep(for: busyDelay)
        }
    }

    func cameraClock() async throws -> LumixCameraClockReading? {
        LumixCameraClockReading(reply: try await send(.getSetting("clock"), busyRetries: 2, busyDelay: .milliseconds(500)))
    }
}

/// The part of the stored track that will be uploaded.
struct CameraGeodataSelection: Equatable, Sendable {
    let period: ClosedRange<Date>
    let records: [LumixGeodata.Record]
    let payload: Data
    let sampleCount: Int
    let segmentCount: Int

    init(samples: [LocationSample], period: ClosedRange<Date>,
         maximumGap: TimeInterval = LumixGeodata.defaultSegmentGap) throws {
        let usable = LumixGeodata.usableSamples(samples, in: period)
        records = try LumixGeodata.records(for: usable, maximumGap: maximumGap)
        payload = try LumixGeodata.encode(records)
        sampleCount = usable.count
        segmentCount = LumixGeodata.segments(of: usable, maximumGap: maximumGap).count
        self.period = period
    }
}

struct CameraGeotagTiming: Sendable {
    var pollInterval: Duration = .seconds(1)
    /// The write is aborted if the camera has not finished by then.
    var writeDeadline: TimeInterval = 10 * 60
    /// How long to keep polling for the camera to confirm an abort.
    var abortConfirmationTimeout: TimeInterval = 15
    var busyRetryDelay: Duration = .seconds(1)
    var modeSwitchSettle: Duration = .milliseconds(800)
    /// Consecutive unanswered progress polls before the connection counts as lost.
    var unansweredPollLimit = 10

    static let standard = CameraGeotagTiming()
}

struct CameraLocationWriteReport: Equatable, Sendable {
    let period: ClosedRange<Date>
    let sampleCount: Int
    let recordCount: Int
    let segmentCount: Int
    /// The value sent with `notify&type=clock` before the upload.
    let clockNotification: String
    let finishedAt: Date
    /// True if the app was backgrounded while the camera was writing.
    let wasInterrupted: Bool
}

enum CameraLocationWritePhase: Equatable, Sendable {
    case idle
    case preparing(String)
    case writing(progress: Int?, cameraState: String)
    case cancelling
    /// The camera reports `finish`. The files still need to be checked.
    case finished(CameraLocationWriteReport)
    case cancelled(String)
    case failed(String)

    var isActive: Bool {
        switch self {
        case .preparing, .writing, .cancelling: return true
        default: return false
        }
    }
}

private struct CameraGeotagFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct CameraGeotagCancelledBeforeWriting: Error {}

/// Uploads a location track and asks the camera to write it into matching photos.
///
/// Command order follows Image App: `playmode` → `notify&type=clock` →
/// `startsenddata&type=geodata` → multipart `senddata` →
/// `camctrl&type=add_location_data&value=start` → `getprogress` polling, with
/// `value=abort` to cancel. The camera chooses the photos; a `finish` state only
/// means the camera says it is done, not that the photos are correct.
@MainActor
final class CameraGeotagWriter: ObservableObject {
    @Published private(set) var phase: CameraLocationWritePhase = .idle
    @Published private(set) var steps: [String] = []
    @Published private(set) var wasInterrupted = false

    private let camera: any CameraGeotagControlling
    private let coordinator: CameraModeCoordinator
    private let timing: CameraGeotagTiming
    private let timeZone: TimeZone
    private let now: @Sendable () -> Date
    private let gate = CameraCommandGate()
    private var lease: CameraActivityLease?
    private var runTask: Task<Void, Never>?
    private var cancelRequested = false
    private var writeActive = false
    private var abortSent = false

    init(
        camera: any CameraGeotagControlling,
        coordinator: CameraModeCoordinator,
        timing: CameraGeotagTiming = .standard,
        timeZone: TimeZone = .autoupdatingCurrent,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.camera = camera
        self.coordinator = coordinator
        self.timing = timing
        self.timeZone = timeZone
        self.now = now
    }

    var isRunning: Bool { runTask != nil }

    /// Starts the write in the background; observe `phase`.
    func start(_ selection: CameraGeodataSelection) {
        guard runTask == nil else { return }
        runTask = Task { [weak self] in
            await self?.run(selection)
            self?.runTask = nil
        }
    }

    /// Runs the whole write and returns when the camera reports an end state.
    func run(_ selection: CameraGeodataSelection) async {
        cancelRequested = false
        writeActive = false
        abortSent = false
        wasInterrupted = false
        steps = []
        phase = .preparing("Reserving the camera…")
        do {
            let lease = try await coordinator.beginExclusive(.geotagWrite)
            lease.onRevoked = { [weak self] in self?.handleRevokedLease() }
            self.lease = lease
            try await performWrite(selection)
        } catch is CameraGeotagCancelledBeforeWriting {
            phase = .cancelled("Stopped before the camera was asked to write. No photos were changed by this request.")
        } catch LumixError.staleConnection {
            phase = .failed(writeActive
                ? "The camera connection changed while it was writing. It may have finished or stopped; check the photos."
                : "The camera connection changed. Nothing was written.")
        } catch is CancellationError {
            if case .failed = phase {} else {
                phase = .cancelled("Stopped. Check the camera before trying again.")
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
        if let lease {
            coordinator.endExclusive(lease)
            self.lease = nil
        }
    }

    /// Stops before the write starts, or asks the camera to abort a running write.
    func cancel() {
        guard phase.isActive else { return }
        cancelRequested = true
        if case .writing = phase { phase = .cancelling }
    }

    /// The app cannot poll while suspended; the camera keeps writing on its own.
    /// Polling resumes on return and reports what the camera says then.
    func setAppActive(_ isActive: Bool) {
        if !isActive, writeActive { wasInterrupted = true }
    }

    // MARK: Steps

    private func performWrite(_ selection: CameraGeodataSelection) async throws {
        let camera = self.camera
        let delay = timing.busyRetryDelay

        step("Switching the camera to playback")
        phase = .preparing("Switching the camera to playback…")
        try await run { try await camera.sendChecked(.playbackMode, busyRetries: 5, busyDelay: delay) }
        try await Task.sleep(for: timing.modeSwitchSettle)
        try checkCancelledBeforeWriting()

        let clockValue = try LumixCameraClock.value(for: now(), timeZone: timeZone)
        step("Sending this iPhone's time (\(clockValue)) with notify&type=clock")
        phase = .preparing("Sending this iPhone's time to the camera…")
        let clock = try await run { try await camera.sendClockValue(mode: "notify", value: clockValue, busyDelay: delay) }
        if clock.usedRawPlus { step("The camera rejected %2B; it accepted or answered the raw '+' form") }
        guard clock.reply.isOK else {
            throw CameraGeotagFailure(message: "The camera rejected the time notification (\(clock.reply.result)). Nothing was uploaded.")
        }
        try checkCancelledBeforeWriting()

        step("Announcing \(selection.payload.count) bytes of location data")
        phase = .preparing("Announcing the location data…")
        let announce = try await run {
            try await camera.send(
                LumixCommand(mode: "startsenddata", type: "geodata", value: String(selection.payload.count), value2: "1"),
                busyRetries: 5, busyDelay: delay
            )
        }
        guard LumixGeodataReplies.acceptsSingleUpload(announce) else {
            throw CameraGeotagFailure(message: "The camera refused the location upload (\(announce.result)). Nothing was written.")
        }
        try checkCancelledBeforeWriting()

        step("Uploading \(selection.records.count) track records")
        phase = .preparing("Uploading \(selection.records.count) track records…")
        let body = LumixGeodataUpload.body(for: selection.payload)
        let upload = try await run {
            try await camera.perform(
                percentEncodedQuery: "mode=senddata&value2=1", body: body,
                contentType: LumixGeodataUpload.contentType, timeoutInterval: 60
            )
        }
        // An HTTP 200 is not enough: the camera's own result code must be `ok`.
        guard upload.isOK else {
            throw CameraGeotagFailure(message: "The camera rejected the uploaded track (\(upload.result)). Nothing was written.")
        }
        try checkCancelledBeforeWriting()

        step("Asking the camera to write locations")
        phase = .preparing("Asking the camera to write locations…")
        let start = try await run { try await camera.send(.camctrl("add_location_data", value: "start"), busyRetries: 5, busyDelay: delay) }
        guard start.isOK else {
            throw CameraGeotagFailure(message: "The camera did not start writing (\(start.result)).")
        }
        writeActive = true
        phase = .writing(progress: nil, cameraState: "prepare")
        try await pollUntilDone(selection: selection, clockValue: clockValue)
    }

    private func pollUntilDone(selection: CameraGeodataSelection, clockValue: String) async throws {
        let camera = self.camera
        let deadline = now().addingTimeInterval(timing.writeDeadline)
        var abortDeadline: Date?
        var unanswered = 0
        while true {
            try await Task.sleep(for: timing.pollInterval)

            if (cancelRequested || now() > deadline), !abortSent {
                abortSent = true
                abortDeadline = now().addingTimeInterval(timing.abortConfirmationTimeout)
                step(cancelRequested ? "Asking the camera to stop writing" : "Deadline reached; asking the camera to stop")
                phase = .cancelling
                _ = try? await run { try await camera.send(.camctrl("add_location_data", value: "abort"), busyRetries: 3) }
            }
            if let abortDeadline, now() > abortDeadline {
                writeActive = false
                throw CameraGeotagFailure(message: "The camera did not confirm that it stopped. Check the camera and its photos.")
            }

            let reply: LumixCommandReply
            do {
                reply = try await run { try await camera.perform(LumixCommand(mode: "getprogress", type: "add_location_data"), timeoutInterval: 5) }
            } catch LumixError.staleConnection {
                throw LumixError.staleConnection
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Typically the app was suspended mid-request; keep asking until the limit.
                unanswered += 1
                if unanswered >= timing.unansweredPollLimit {
                    writeActive = false
                    throw CameraGeotagFailure(message: "Lost contact with the camera while it was writing. It may have finished or stopped; check the photos.")
                }
                continue
            }
            let progress = LumixLocationWriteProgress(reply: reply)
            if progress.result == LumixResultCode.busy || progress.result == LumixResultCode.noReply || progress.result == "bad_xml" {
                unanswered += 1
                if unanswered >= timing.unansweredPollLimit {
                    writeActive = false
                    throw CameraGeotagFailure(message: "The camera stopped answering progress requests. Check the camera and its photos.")
                }
                continue
            }
            unanswered = 0
            guard progress.result == LumixResultCode.ok else {
                writeActive = false
                throw CameraGeotagFailure(message: "The camera stopped reporting progress (\(progress.result)). Check the photos.")
            }

            switch progress.state {
            case .finish:
                writeActive = false
                step("The camera reports finish")
                if abortSent, now() > deadline {
                    throw CameraGeotagFailure(message: "The camera finished only after the deadline. Check the photos.")
                }
                phase = .finished(CameraLocationWriteReport(
                    period: selection.period,
                    sampleCount: selection.sampleCount,
                    recordCount: selection.records.count,
                    segmentCount: selection.segmentCount,
                    clockNotification: clockValue,
                    finishedAt: now(),
                    wasInterrupted: wasInterrupted
                ))
                return
            case .error:
                writeActive = false
                if progress.isCancelled {
                    step("The camera confirms it stopped")
                    if now() > deadline {
                        throw CameraGeotagFailure(message: "The camera did not finish before the deadline and was stopped. Some photos may already contain locations.")
                    }
                    phase = .cancelled("The camera stopped writing. Some photos may already contain locations.")
                    return
                }
                throw CameraGeotagFailure(message: "The camera reported a location-writing error (\(progress.error ?? "unknown")).")
            case .prepare, .exec, .unknown:
                if !abortSent {
                    phase = .writing(progress: progress.progress, cameraState: progress.rawState.nonEmptyValue ?? "busy")
                }
            }
        }
    }

    // MARK: Helpers

    private func checkCancelledBeforeWriting() throws {
        if cancelRequested { throw CameraGeotagCancelledBeforeWriting() }
    }

    @discardableResult
    private func run<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try ensureActive()
        let value = try await gate.run(operation)
        try ensureActive()
        return value
    }

    private func ensureActive() throws {
        guard let lease, coordinator.isValid(lease), camera.belongsToCurrentConnection else {
            throw LumixError.staleConnection
        }
    }

    private func handleRevokedLease() {
        lease = nil
        runTask?.cancel()
        phase = .failed(writeActive
            ? "The camera connection changed while it was writing. It may have finished or stopped; check the photos."
            : "The camera connection changed. Nothing was written.")
    }

    private func step(_ text: String) {
        steps.append(text)
        print("[GM1Sync] Location write: \(text)")
    }
}

// MARK: - Camera clock

struct CameraClockSyncResult: Equatable, Sendable {
    let sentValue: String
    let setAt: Date
    let before: LumixCameraClockReading?
    let after: LumixCameraClockReading?
    let usedRawPlus: Bool

    /// Camera minus phone after setting, if the camera's reply could be read.
    var differenceAfter: TimeInterval? { after?.difference(from: setAt) }
}

enum CameraClockSyncPhase: Equatable, Sendable {
    case idle
    case reading
    case waiting(until: Date)
    case setting
    case finished(CameraClockSyncResult)
    case cancelled
    case failed(String)

    var isActive: Bool {
        switch self {
        case .reading, .waiting, .setting: return true
        default: return false
        }
    }
}

/// Sets the camera clock from the iPhone before shooting (`setsetting&type=clock`).
///
/// This is separate from the `notify&type=clock` sent automatically before a
/// track upload: setting changes the camera's clock, notifying only tells the
/// camera what time the phone has while it matches the track.
@MainActor
final class CameraClockSynchronizer: ObservableObject {
    @Published private(set) var phase: CameraClockSyncPhase = .idle
    @Published private(set) var lastReading: LumixCameraClockReading?
    @Published private(set) var lastReadingAt: Date?

    private let camera: any CameraGeotagControlling
    private let coordinator: CameraModeCoordinator
    private let timeZone: TimeZone
    private let now: @Sendable () -> Date
    private let waitUntil: @Sendable (Date) async throws -> Void
    private var task: Task<Void, Never>?

    init(
        camera: any CameraGeotagControlling,
        coordinator: CameraModeCoordinator,
        timeZone: TimeZone = .autoupdatingCurrent,
        now: @escaping @Sendable () -> Date = { Date() },
        waitUntil: @escaping @Sendable (Date) async throws -> Void = { target in
            let delay = target.timeIntervalSinceNow
            if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        }
    ) {
        self.camera = camera
        self.coordinator = coordinator
        self.timeZone = timeZone
        self.now = now
        self.waitUntil = waitUntil
    }

    /// True when daylight saving time is in effect on the iPhone. Image App sends
    /// the standard offset; the camera's own daylight-saving setting must match.
    var isDaylightSavingTime: Bool { timeZone.isDaylightSavingTime(for: now()) }

    var rawOffsetMinutes: Int { LumixCameraClock.rawOffsetMinutes(of: timeZone, at: now()) }

    func readCameraClock() async {
        guard !phase.isActive else { return }
        let previous = phase
        phase = .reading
        do {
            let lease = try await coordinator.beginExclusive(.clockSync)
            defer { coordinator.endExclusive(lease) }
            lastReading = try await camera.cameraClock()
            lastReadingAt = now()
            phase = previous == .reading ? .idle : previous
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.synchronize()
            self?.task = nil
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// Waits for the next whole minute and sets the camera clock to it.
    func synchronize() async {
        guard !phase.isActive else { return }
        phase = .reading
        var lease: CameraActivityLease?
        do {
            let claimed = try await coordinator.beginExclusive(.clockSync)
            lease = claimed
            let before = try? await camera.cameraClock()
            if let before {
                lastReading = before
                lastReadingAt = now()
            }
            let boundary = LumixCameraClock.nextMinuteBoundary(after: now())
            let value = try LumixCameraClock.value(for: boundary, timeZone: timeZone)
            phase = .waiting(until: boundary)
            try await waitUntil(boundary)
            try Task.checkCancellation()
            guard coordinator.isValid(claimed), camera.belongsToCurrentConnection else { throw LumixError.staleConnection }
            phase = .setting
            let sent = try await camera.sendClockValue(mode: "setsetting", value: value)
            let setAt = now()
            guard sent.reply.isOK else {
                throw CameraGeotagFailure(message: sent.reply.result == "err_param" || sent.reply.result == "err_non_support"
                    ? "This camera does not accept a clock setting from the app (\(sent.reply.result))."
                    : "The camera rejected the clock setting (\(sent.reply.result)).")
            }
            let after = try? await camera.cameraClock()
            if let after {
                lastReading = after
                lastReadingAt = now()
            }
            phase = .finished(CameraClockSyncResult(
                sentValue: value, setAt: setAt, before: before, after: after, usedRawPlus: sent.usedRawPlus
            ))
        } catch is CancellationError {
            phase = .cancelled
        } catch {
            phase = .failed(error.localizedDescription)
        }
        if let lease { coordinator.endExclusive(lease) }
    }
}
