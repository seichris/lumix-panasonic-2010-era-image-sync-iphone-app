import CoreGraphics
import Foundation

struct RemoteShootingTiming: Sendable {
    var pollInterval: Duration = .seconds(1)
    var settingsRefreshInterval: TimeInterval = 5
    var menuRefreshInterval: TimeInterval = 15
    /// Live view is considered stalled when no frame arrives for this long.
    var frameStallTimeout: TimeInterval = 3
    /// Minimum time between `startstream` re-requests while frames are missing.
    var streamRestartInterval: TimeInterval = 3
    /// Restarts that may fail before the screen reports a stalled live view.
    var stalledRestartLimit = 3
    /// Consecutive failed `getstate` keep-alives before the connection counts as lost.
    var connectionFailureLimit = 3
    var modeSwitchSettle: Duration = .milliseconds(800)
    var busyRetryDelay: Duration = .seconds(1)
    var approvalTimeout: TimeInterval = 60
    var approvalPollInterval: Duration = .seconds(2)
    var captureConfirmationTimeout: TimeInterval = 5
    var captureConfirmationPollInterval: Duration = .milliseconds(200)
    var shutterReleaseRetryInterval: Duration = .milliseconds(100)
    var shutterReleaseTimeout: TimeInterval = 5
    var manualFocusRepeatInterval: Duration = .milliseconds(150)

    static let standard = RemoteShootingTiming()
}

enum RemoteShootingPauseReason: Equatable, Sendable {
    case appInBackground
    case cameraInPlayback
    case cameraBusy
    case liveViewStalled
    case connectionLost

    var message: String {
        switch self {
        case .appInBackground:
            return "Live view paused while Retro LUMIX Sync is in the background."
        case .cameraInPlayback:
            return "The camera is in playback mode. Switch the camera back to recording to resume remote shooting."
        case .cameraBusy:
            return "The camera is being operated directly. Remote control resumes when the camera is ready."
        case .liveViewStalled:
            return "The camera stopped sending live view. Retrying…"
        case .connectionLost:
            return "The camera stopped responding. Waiting for the connection…"
        }
    }
}

enum RemoteShootingPhase: Equatable, Sendable {
    case idle
    case connecting(String)
    case awaitingCameraApproval
    case live
    case paused(RemoteShootingPauseReason)
    case failed(String)
    case ended

    var isOperational: Bool {
        switch self {
        case .live, .paused(.liveViewStalled), .paused(.cameraBusy): return true
        default: return false
        }
    }
}

enum RemoteTouchMode: String, CaseIterable, Identifiable, Sendable {
    case focus
    case shutter

    var id: String { rawValue }
    var title: String { self == .focus ? "Touch AF" : "Touch shutter" }
}

enum RemoteZoomDirection: Sendable {
    case tele
    case wide
}

/// Manual focus direction. Panasonic's protocol names far focus `tele` and near focus `wide`.
enum RemoteFocusDirection: Sendable {
    case near
    case far
}

struct RemoteShootingNotice: Equatable, Identifiable, Sendable {
    enum Style: Sendable { case info, success, warning, error }

    let id = UUID()
    let message: String
    let style: Style
}

enum RemoteShootingError: LocalizedError, Equatable {
    case cameraStayedInPlayback
    case approvalTimedOut
    case cameraDeclined(String)

    var errorDescription: String? {
        switch self {
        case .cameraStayedInPlayback:
            return "The camera stayed in playback mode. Switch it to recording and try again."
        case .approvalTimedOut:
            return "The camera did not accept the connection. Accept it on the camera and try again."
        case let .cameraDeclined(code):
            return LumixResultCode.message(for: code)
        }
    }
}

/// Owns one remote shooting visit: the exclusive camera lease, the record-mode
/// switch, the UDP live view, the `getstate` keep-alive, and every shooting command.
@MainActor
final class RemoteShootingSession: ObservableObject {
    @Published private(set) var phase: RemoteShootingPhase = .idle
    /// Per-frame state lives in its own object so only the viewfinder redraws for
    /// each live-view frame; redrawing the whole screen rebuilt open settings menus.
    let feed = RemoteLiveViewFeed()
    @Published private(set) var cameraState: LumixCameraState?
    @Published private(set) var controls = RemoteShootingControls()
    @Published private(set) var focusPosition: LumixFocusPosition?
    @Published private(set) var isShutterPressed = false
    @Published private(set) var isConfirmingCapture = false
    @Published private(set) var notice: RemoteShootingNotice?
    @Published private(set) var capabilities: CameraCapabilities?
    @Published private(set) var lastTouchPoint: CGPoint?
    @Published private(set) var zoomUnavailableMessage: String?
    @Published var touchMode: RemoteTouchMode = .focus

    private let camera: any RemoteCameraControlling
    private let coordinator: CameraModeCoordinator
    private let makeLiveViewSource: @MainActor () -> any LumixLiveViewSource
    private let timing: RemoteShootingTiming
    private let accessIdentifier: String
    private let clientName: String
    private let gate = CameraCommandGate()
    private let mailbox = LiveViewMailbox()

    private var lease: CameraActivityLease?
    private var liveViewSource: (any LumixLiveViewSource)?
    private var streamPort: UInt16?
    private var streamRequestedAt: Date?
    private var lastFrameAt: Date?
    private var lastStreamRestart = Date.distantPast
    private var failedStreamRestarts = 0
    private var pollTask: Task<Void, Never>?
    private var focusRepeatTask: Task<Void, Never>?
    private var schema: LumixMenuSchema?
    private var didRequestSchema = false
    private var currentMenu: LumixCurrentMenu?
    private var settingValues: [RemoteShootingSetting.Kind: LumixSettingValue] = [:]
    private var apertureValue: LumixSettingValue?
    private var shutterValue: LumixSettingValue?
    private var lensInfo: LumixLensInfo?
    private var lastSettingsRefresh = Date.distantPast
    private var lastMenuRefresh = Date.distantPast
    private var consecutiveFailures = 0
    private var isInBackground = false
    private var isZooming = false
    private var isStartingLiveView = false
    private var captureBaseline: LumixCameraState?
    private var requestedVideoRecording = false

    init(
        camera: any RemoteCameraControlling,
        coordinator: CameraModeCoordinator,
        timing: RemoteShootingTiming = .standard,
        accessIdentifier: String = "0",
        clientName: String = "GM1Sync",
        makeLiveViewSource: @escaping @MainActor () -> any LumixLiveViewSource
    ) {
        self.camera = camera
        self.coordinator = coordinator
        self.timing = timing
        self.accessIdentifier = accessIdentifier
        self.clientName = clientName
        self.makeLiveViewSource = makeLiveViewSource
    }

    /// Uses the camera's `rec` field when it reports one; otherwise the last
    /// start/stop command this screen sent.
    var frame: LumixLiveViewFrame? { feed.frame }
    var framesReceived: Int { feed.framesReceived }
    var malformedFrames: Int { feed.malformedFrames }

    var isRecordingVideo: Bool {
        if let rec = cameraState?.values["rec"] { return rec == "on" }
        return requestedVideoRecording
    }
    var canOperate: Bool { phase.isOperational && !isInBackground }

    // MARK: Lifecycle

    func start() async {
        guard lease == nil else { return }
        switch phase {
        case .idle, .failed, .ended: break
        default: return
        }
        phase = .connecting("Preparing the camera…")
        do {
            let lease = try await coordinator.beginExclusive(.remoteShooting)
            lease.onRevoked = { [weak self] in self?.handleRevokedLease() }
            self.lease = lease
            try await prepareCameraAndLiveView(requestAccess: true)
            // The screen may have closed while the camera was being prepared.
            guard self.lease != nil else { return }
            startPolling()
        } catch {
            await finish(failure: error)
        }
    }

    /// Ends the visit: stops the stream, stops any video recording this screen
    /// started controlling, and returns the camera to the rest of the app.
    func stop() async {
        pollTask?.cancel()
        pollTask = nil
        stopContinuousActions()
        guard let lease else {
            if case .failed = phase { return }
            phase = .ended
            return
        }
        let hadStream = liveViewSource != nil
        stopLiveViewSource()
        if camera.belongsToCurrentConnection, coordinator.isValid(lease) {
            let camera = self.camera
            if isRecordingVideo {
                _ = try? await gate.run { try await camera.send(.videoRecordStop, busyRetries: 2, busyDelay: .milliseconds(500)) }
                requestedVideoRecording = false
            }
            if isShutterPressed {
                _ = try? await gate.run { try await camera.send(.captureCancel, busyRetries: 2, busyDelay: .milliseconds(300)) }
            }
            if hadStream {
                _ = try? await gate.run { try await camera.send(.stopStream, busyRetries: 0, timeoutInterval: 3) }
            }
        }
        coordinator.endExclusive(lease)
        self.lease = nil
        isShutterPressed = false
        phase = .ended
    }

    /// Pauses live view when the app leaves the foreground and recovers on return.
    func setAppActive(_ isActive: Bool) async {
        if isActive {
            guard isInBackground else { return }
            isInBackground = false
            guard let lease, coordinator.isValid(lease), camera.belongsToCurrentConnection else {
                await finish(failure: LumixError.staleConnection)
                return
            }
            await resumeAfterInterruption()
            if self.lease != nil { startPolling() }
        } else {
            guard !isInBackground, lease != nil else { return }
            isInBackground = true
            pollTask?.cancel()
            pollTask = nil
            stopContinuousActions()
            let hadStream = liveViewSource != nil
            stopLiveViewSource()
            phase = .paused(.appInBackground)
            if hadStream, camera.belongsToCurrentConnection {
                let camera = self.camera
                _ = try? await gate.run { try await camera.send(.stopStream, busyRetries: 0, timeoutInterval: 2) }
            }
        }
    }

    /// Manual retry from the paused or failed screen.
    func retry() async {
        if lease == nil {
            phase = .idle
            await start()
            return
        }
        await resumeAfterInterruption()
    }

    // MARK: Shooting

    /// Single shot: press and release the shutter.
    func capturePhoto() async {
        await pressShutter()
        await releaseShutter()
    }

    /// Press-and-hold support for burst and bulb: the camera keeps shooting until release.
    func pressShutter() async {
        guard canOperate, !isShutterPressed else { return }
        isShutterPressed = true
        // Baseline before the exposure: a keep-alive poll may refresh the count mid-press.
        captureBaseline = cameraState
        let camera = self.camera
        let delay = timing.busyRetryDelay
        do {
            let reply = try await run { try await camera.send(.capture, busyRetries: 5, busyDelay: delay) }
            if !reply.isOK {
                isShutterPressed = false
                show(LumixResultCode.message(for: reply.result), style: .error)
            }
        } catch {
            isShutterPressed = false
            await handleCommandError(error)
        }
    }

    func releaseShutter() async {
        guard isShutterPressed else { return }
        let baseline = captureBaseline ?? cameraState
        let camera = self.camera
        let delay = timing.busyRetryDelay
        do {
            var reply = try await run { try await camera.send(.captureCancel, busyRetries: 5, busyDelay: delay) }
            // `err_retry` means the exposure is still running (long shutter speeds).
            let deadline = Date().addingTimeInterval(timing.shutterReleaseTimeout)
            while reply.result == LumixResultCode.retry, Date() < deadline {
                try await Task.sleep(for: timing.shutterReleaseRetryInterval)
                reply = try await run { try await camera.send(.captureCancel, busyRetries: 2, busyDelay: delay) }
            }
            isShutterPressed = false
            guard reply.isOK else {
                show(LumixResultCode.message(for: reply.result), style: .error)
                return
            }
            await confirmCapture(after: baseline)
        } catch {
            isShutterPressed = false
            await handleCommandError(error)
        }
    }

    func toggleVideoRecording() async {
        guard canOperate else { return }
        let stopping = isRecordingVideo
        let camera = self.camera
        let delay = timing.busyRetryDelay
        do {
            let command: LumixCommand = stopping ? .videoRecordStop : .videoRecordStart
            let reply = try await run { try await camera.send(command, busyRetries: 3, busyDelay: delay) }
            guard reply.isOK else {
                show(LumixResultCode.message(for: reply.result), style: .error)
                return
            }
            requestedVideoRecording = !stopping
            if let state = try? await run({ try await camera.cameraState(timeoutInterval: 3) }) { apply(state) }
            show(stopping ? "Video saved to the camera's card." : "Recording video on the camera.", style: stopping ? .success : .info)
        } catch {
            await handleCommandError(error)
        }
    }

    /// Handles a tap on the live view at a point normalized to the image (0…1).
    func touch(at point: CGPoint) async {
        guard canOperate else { return }
        let x = Int((min(max(point.x, 0), 1) * 1000).rounded())
        let y = Int((min(max(point.y, 0), 1) * 1000).rounded())
        lastTouchPoint = CGPoint(x: Double(x) / 1000, y: Double(y) / 1000)
        if controls.isManualFocus {
            // Manual focus needs no AF point: touch shutter simply releases the shutter.
            if touchMode == .shutter {
                await capturePhoto()
            } else {
                show("Touch AF is unavailable in manual focus. Use the focus controls.", style: .info)
            }
            return
        }
        let camera = self.camera
        do {
            let reply = try await run { try await camera.send(.camctrl("touch", value: "\(x)/\(y)", value2: "on"), busyRetries: 2) }
            guard reply.isOK else {
                show(LumixResultCode.message(for: reply.result), style: .warning)
                return
            }
            if touchMode == .shutter { await capturePhoto() }
        } catch {
            await handleCommandError(error)
        }
    }

    func startZoom(_ direction: RemoteZoomDirection, fast: Bool) async {
        guard canOperate, controls.supportsPowerZoom, !isZooming else { return }
        isZooming = true
        let value = (direction == .tele ? "tele" : "wide") + (fast ? "-fast" : "-normal")
        let camera = self.camera
        do {
            let reply = try await run { try await camera.send(.camcmd(value), busyRetries: 1, busyDelay: .milliseconds(300)) }
            if !reply.isOK {
                isZooming = false
                if reply.result == "err_non_support" || reply.result == "err_param" {
                    zoomUnavailableMessage = "This lens can't be zoomed from the phone."
                } else {
                    show(LumixResultCode.message(for: reply.result), style: .warning)
                }
            }
        } catch {
            isZooming = false
            await handleCommandError(error)
        }
    }

    func stopZoom() async {
        guard isZooming else { return }
        isZooming = false
        let camera = self.camera
        do {
            _ = try await run { try await camera.send(.camcmd("zoomstop"), busyRetries: 3, busyDelay: .milliseconds(200)) }
            lastSettingsRefresh = .distantPast
        } catch {
            await handleCommandError(error)
        }
    }

    func driveFocus(_ direction: RemoteFocusDirection, fast: Bool) async {
        guard canOperate else { return }
        let value = (direction == .far ? "tele" : "wide") + (fast ? "-fast" : "-normal")
        let camera = self.camera
        do {
            let reply = try await run { try await camera.send(.camctrl("focus", value: value), busyRetries: 1, busyDelay: .milliseconds(200)) }
            if let position = LumixFocusPosition(reply: reply) {
                focusPosition = position
            } else if !reply.isOK {
                stopFocusRepeat()
                show(LumixResultCode.message(for: reply.result), style: .warning)
            }
        } catch {
            stopFocusRepeat()
            await handleCommandError(error)
        }
    }

    /// Repeats a manual-focus step while a focus button is held, as Image App does.
    func startFocusRepeat(_ direction: RemoteFocusDirection, fast: Bool) {
        stopFocusRepeat()
        let interval = timing.manualFocusRepeatInterval
        focusRepeatTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.driveFocus(direction, fast: fast)
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stopFocusRepeat() {
        focusRepeatTask?.cancel()
        focusRepeatTask = nil
    }

    func apply(_ option: RemoteShootingSetting.Option, to setting: RemoteShootingSetting) async {
        guard canOperate, option.isEnabled else { return }
        await applySettingCommand(option.command(for: setting.kind), description: "\(setting.title): \(option.label)")
    }

    func apply(_ option: LumixExposureOption, to control: RemoteExposureControl) async {
        guard canOperate, control.isEnabled else { return }
        await applySettingCommand(.setSetting(control.settingType, value: option.value), description: "\(control.title): \(option.label)")
    }

    func dismissNotice(_ notice: RemoteShootingNotice) {
        if self.notice?.id == notice.id { self.notice = nil }
    }

    // MARK: Camera preparation

    private func prepareCameraAndLiveView(requestAccess: Bool) async throws {
        if requestAccess {
            phase = .connecting("Requesting camera access…")
            try await requestCameraAccess()
        }
        phase = .connecting("Switching the camera to recording…")
        let camera = self.camera
        var state = try await run { try await camera.cameraState(timeoutInterval: 4) }
        apply(state)
        if state.mode != .record {
            let delay = timing.busyRetryDelay
            try await run { try await camera.sendChecked(.recordMode, busyRetries: 3, busyDelay: delay) }
            try await Task.sleep(for: timing.modeSwitchSettle)
            state = try await run { try await camera.cameraState(timeoutInterval: 4) }
            apply(state)
            if state.mode == .playback { throw RemoteShootingError.cameraStayedInPlayback }
        }
        phase = .connecting("Reading camera settings…")
        if capabilities == nil {
            capabilities = try? await run { try await camera.capabilityInfo() }
        }
        await refreshMenus(force: true)
        await refreshSettings(force: true)
        try await startLiveView()
    }

    private func requestCameraAccess() async throws {
        let camera = self.camera
        let command = LumixCommand.requestAccess(identifier: accessIdentifier, clientName: clientName)
        let delay = timing.busyRetryDelay
        var reply = try await run { try await camera.send(command, busyRetries: 2, busyDelay: delay) }
        if reply.isAwaitingCameraApproval {
            phase = .awaitingCameraApproval
            let deadline = Date().addingTimeInterval(timing.approvalTimeout)
            while reply.isAwaitingCameraApproval {
                guard Date() < deadline else { throw RemoteShootingError.approvalTimedOut }
                try await Task.sleep(for: timing.approvalPollInterval)
                reply = try await run { try await camera.send(command, busyRetries: 1, busyDelay: delay) }
            }
        }
        switch reply.result {
        case "err_already_connected", "err_user_refused", "err_unsuitable_app", "err_others_requesting":
            throw RemoteShootingError.cameraDeclined(reply.result)
        default:
            // `ok`, or firmware without access control: the mode switch decides.
            return
        }
    }

    private func startLiveView() async throws {
        // A poll-triggered restart and a user retry can overlap across awaits;
        // the first one owns the socket and the camera's stream target.
        guard !isStartingLiveView else { return }
        isStartingLiveView = true
        defer { isStartingLiveView = false }
        stopLiveViewSource()
        let source = makeLiveViewSource()
        let mailbox = self.mailbox
        mailbox.reset()
        let port = try source.start { [weak self] event in
            guard mailbox.post(event) else { return }
            Task { @MainActor [weak self] in self?.drainMailbox() }
        }
        liveViewSource = source
        streamPort = port
        if phase != .live { phase = .connecting("Starting live view…") }
        let camera = self.camera
        let delay = timing.busyRetryDelay
        do {
            try await run { try await camera.sendChecked(.startStream(port: port), busyRetries: 5, busyDelay: delay) }
        } catch {
            stopLiveViewSource()
            throw error
        }
        streamRequestedAt = Date()
        lastStreamRestart = Date()
        failedStreamRestarts = 0
    }

    private func resumeAfterInterruption() async {
        guard lease != nil else { return }
        phase = .connecting("Reconnecting to the camera…")
        let camera = self.camera
        do {
            let state = try await run { try await camera.cameraState(timeoutInterval: 4) }
            consecutiveFailures = 0
            apply(state)
            if state.mode == .playback {
                phase = .paused(.cameraInPlayback)
                return
            }
            try await startLiveView()
        } catch LumixError.staleConnection {
            await finish(failure: LumixError.staleConnection)
        } catch is CancellationError {
            return
        } catch {
            // The camera may have dropped the remote session while the app was away.
            do {
                try await prepareCameraAndLiveView(requestAccess: true)
            } catch {
                await finish(failure: error)
            }
        }
    }

    // MARK: Polling

    private func startPolling() {
        pollTask?.cancel()
        let interval = timing.pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.pollOnce()
            }
        }
    }

    private static func isPollable(_ phase: RemoteShootingPhase) -> Bool {
        switch phase {
        case .live, .paused(.cameraInPlayback), .paused(.cameraBusy), .paused(.liveViewStalled),
             .paused(.connectionLost), .connecting:
            return true
        default:
            return false
        }
    }

    private func pollOnce() async {
        guard lease != nil, !isInBackground, Self.isPollable(phase) else { return }
        guard camera.belongsToCurrentConnection else {
            await finish(failure: LumixError.staleConnection)
            return
        }
        let camera = self.camera
        do {
            let state = try await run { try await camera.cameraState(timeoutInterval: 3) }
            // The app may have been backgrounded or the screen closed while waiting.
            guard lease != nil, !isInBackground, Self.isPollable(phase) else { return }
            consecutiveFailures = 0
            let previous = cameraState
            apply(state)
            noteCameraBodyActivity(previous: previous, current: state)

            if state.mode == .playback {
                if phase != .paused(.cameraInPlayback) {
                    stopLiveViewSource()
                    phase = .paused(.cameraInPlayback)
                }
                return
            }
            switch phase {
            case .paused(.cameraInPlayback), .paused(.connectionLost):
                phase = .connecting("Restarting live view…")
                try await startLiveView()
            default:
                try await checkLiveViewHealth()
            }
            guard lease != nil, !isInBackground else { return }
            await refreshSettings(force: false)
            await refreshMenus(force: false)
        } catch LumixError.staleConnection {
            await finish(failure: LumixError.staleConnection)
        } catch is CancellationError {
            return
        } catch let error as CameraModeCoordinatorError {
            await finish(failure: error)
        } catch {
            consecutiveFailures += 1
            if consecutiveFailures >= timing.connectionFailureLimit, phase != .paused(.connectionLost) {
                stopContinuousActions()
                stopLiveViewSource()
                phase = .paused(.connectionLost)
            }
        }
    }

    private func checkLiveViewHealth() async throws {
        let reference = lastFrameAt ?? streamRequestedAt ?? .distantPast
        guard Date().timeIntervalSince(reference) > timing.frameStallTimeout else {
            failedStreamRestarts = 0
            return
        }
        guard Date().timeIntervalSince(lastStreamRestart) >= timing.streamRestartInterval else { return }
        lastStreamRestart = Date()
        failedStreamRestarts += 1
        if failedStreamRestarts > timing.stalledRestartLimit, phase == .live {
            phase = .paused(.liveViewStalled)
        }
        guard let port = streamPort, liveViewSource != nil else {
            try await startLiveView()
            return
        }
        // When frames stop, ask the camera to resume, as Panasonic's app does.
        let camera = self.camera
        let reply = try await run { try await camera.send(.startStream(port: port), busyRetries: 0) }
        if !reply.isOK, reply.result != LumixResultCode.noReply, phase == .live || phase == .paused(.liveViewStalled) {
            phase = .paused(.cameraBusy)
        }
    }

    /// A drop in the remaining-shots count we did not cause means the camera's own
    /// shutter button was used; the gallery must refresh when the user returns.
    private func noteCameraBodyActivity(previous: LumixCameraState?, current: LumixCameraState) {
        guard !isShutterPressed, !isConfirmingCapture,
              let before = previous?.remainingPhotos, let after = current.remainingPhotos, after < before else { return }
        show("A photo was taken on the camera.", style: .info)
    }

    private func refreshSettings(force: Bool) async {
        guard force || Date().timeIntervalSince(lastSettingsRefresh) >= timing.settingsRefreshInterval else { return }
        lastSettingsRefresh = Date()
        let camera = self.camera
        var values: [RemoteShootingSetting.Kind: LumixSettingValue] = [:]
        for kind in RemoteShootingSetting.Kind.allCases {
            if let value = try? await run({ try await camera.setting(kind.settingType) }) {
                values[kind] = value
            }
        }
        settingValues = values
        apertureValue = try? await run { try await camera.setting("focal") }
        shutterValue = try? await run { try await camera.setting("shtrspeed") }
        if let reply = try? await run({ try await camera.perform(.getInfo("lens"), timeoutInterval: 5) }) {
            lensInfo = LumixLensInfo(reply: reply) ?? lensInfo
        }
        recomputeControls()
    }

    private func refreshMenus(force: Bool) async {
        let camera = self.camera
        if !didRequestSchema {
            didRequestSchema = true
            if let reply = try? await run({ try await camera.perform(.getInfo("allmenu"), timeoutInterval: 20) }), reply.isOK {
                schema = LumixMenuSchema.parse(Data(reply.raw.utf8))
            }
        }
        guard force || Date().timeIntervalSince(lastMenuRefresh) >= timing.menuRefreshInterval else { return }
        lastMenuRefresh = Date()
        if let reply = try? await run({ try await camera.perform(.getInfo("curmenu"), timeoutInterval: 10) }), reply.isOK {
            let parsed = LumixCurrentMenu.parse(reply.raw)
            if !parsed.entries.isEmpty { currentMenu = parsed }
        }
        recomputeControls()
    }

    private func recomputeControls() {
        let derived = RemoteShootingControls.derive(
            schema: schema,
            currentMenu: currentMenu,
            values: settingValues,
            aperture: apertureValue,
            shutter: shutterValue,
            lens: lensInfo,
            capabilities: capabilities
        )
        if derived != controls { controls = derived }
        if !controls.isManualFocus, focusPosition != nil { focusPosition = nil }
    }

    private func applySettingCommand(_ command: LumixCommand, description: String) async {
        let camera = self.camera
        let delay = timing.busyRetryDelay
        do {
            let reply = try await run { try await camera.send(command, busyRetries: 3, busyDelay: delay) }
            if reply.isOK {
                show(description, style: .success)
            } else {
                show(LumixResultCode.message(for: reply.result), style: .error)
            }
            await refreshMenus(force: true)
            await refreshSettings(force: true)
        } catch {
            await handleCommandError(error)
        }
    }

    // MARK: Capture confirmation

    /// A successful `capture` reply alone does not prove a photo was written: in a
    /// dark AF-C scene the camera can accept the command without exposing. Look for
    /// card activity or a changed remaining-shots count before reporting success.
    private func confirmCapture(after baseline: LumixCameraState?) async {
        isConfirmingCapture = true
        defer { isConfirmingCapture = false }
        let camera = self.camera
        let deadline = Date().addingTimeInterval(timing.captureConfirmationTimeout)
        while Date() < deadline {
            guard let state = try? await run({ try await camera.cameraState(timeoutInterval: 2) }) else {
                if lease == nil { return }
                try? await Task.sleep(for: timing.captureConfirmationPollInterval)
                continue
            }
            apply(state)
            let countChanged = baseline?.remainingPhotos != nil && state.remainingPhotos != baseline?.remainingPhotos
            if state.isAccessingCard || countChanged {
                show("Photo saved to the camera's card.", style: .success)
                return
            }
            try? await Task.sleep(for: timing.captureConfirmationPollInterval)
        }
        show("The camera did not confirm a new photo. It may not have been able to focus.", style: .warning)
    }

    // MARK: Live view frames

    private func drainMailbox() {
        let delivery = mailbox.take()
        feed.malformedFrames += delivery.malformedCount
        guard let frame = delivery.frame, liveViewSource != nil, !isInBackground else { return }
        feed.frame = frame
        feed.framesReceived += delivery.frameCount
        lastFrameAt = frame.receivedAt
        failedStreamRestarts = 0
        switch phase {
        case .connecting, .paused(.liveViewStalled), .paused(.cameraBusy):
            phase = .live
        default:
            break
        }
    }

    private func stopLiveViewSource() {
        liveViewSource?.stop()
        liveViewSource = nil
        streamPort = nil
        lastFrameAt = nil
        streamRequestedAt = nil
    }

    private func stopContinuousActions() {
        stopFocusRepeat()
        isZooming = false
    }

    // MARK: Helpers

    private func apply(_ state: LumixCameraState) {
        // Publish only real changes: the keep-alive runs every second, and each
        // publish redraws the screen, including any settings menu that is open.
        if cameraState != state { cameraState = state }
    }

    /// Runs one camera command through the serial gate, refusing to touch a camera
    /// after this session lost its lease or its connection.
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

    private func handleCommandError(_ error: Error) async {
        switch error {
        case LumixError.staleConnection:
            await finish(failure: error)
        case is CancellationError:
            break
        default:
            show(error.localizedDescription, style: .error)
        }
    }

    private func handleRevokedLease() {
        pollTask?.cancel()
        pollTask = nil
        stopContinuousActions()
        stopLiveViewSource()
        lease = nil
        isShutterPressed = false
        phase = .failed(LumixError.staleConnection.localizedDescription)
    }

    private func finish(failure error: Error) async {
        pollTask?.cancel()
        pollTask = nil
        stopContinuousActions()
        stopLiveViewSource()
        if let lease {
            coordinator.endExclusive(lease)
            self.lease = nil
        }
        isShutterPressed = false
        if error is CancellationError {
            phase = .ended
        } else {
            phase = .failed(error.localizedDescription)
        }
    }

    private func show(_ message: String, style: RemoteShootingNotice.Style) {
        notice = RemoteShootingNotice(message: message, style: style)
    }
}

/// The newest live-view frame and frame counters, observed only by the viewfinder.
@MainActor
final class RemoteLiveViewFeed: ObservableObject {
    @Published fileprivate(set) var frame: LumixLiveViewFrame?
    @Published fileprivate(set) var framesReceived = 0
    @Published fileprivate(set) var malformedFrames = 0
}

/// Coalesces live-view frames so the main actor only ever renders the newest one.
final class LiveViewMailbox: @unchecked Sendable {
    struct Delivery {
        let frame: LumixLiveViewFrame?
        let frameCount: Int
        let malformedCount: Int
    }

    private let lock = NSLock()
    private var latest: LumixLiveViewFrame?
    private var frameCount = 0
    private var malformedCount = 0
    private var isScheduled = false

    /// Stores an event. Returns true when the caller must schedule a drain.
    func post(_ event: LumixLiveViewEvent) -> Bool {
        lock.withLock {
            switch event {
            case let .frame(frame):
                latest = frame
                frameCount += 1
            case .malformed:
                malformedCount += 1
            }
            guard !isScheduled else { return false }
            isScheduled = true
            return true
        }
    }

    func take() -> Delivery {
        lock.withLock {
            defer {
                latest = nil
                frameCount = 0
                malformedCount = 0
                isScheduled = false
            }
            return Delivery(frame: latest, frameCount: frameCount, malformedCount: malformedCount)
        }
    }

    func reset() {
        _ = take()
    }
}
