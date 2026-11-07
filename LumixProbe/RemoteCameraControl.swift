import Foundation

/// The `cam.cgi` surface used by remote shooting. `LumixClient` is the real
/// implementation; tests and the UI-test fixture provide scripted cameras.
protocol RemoteCameraControlling: Sendable {
    var host: String { get }
    /// False once the connection that created this camera handle has ended.
    var belongsToCurrentConnection: Bool { get }
    func perform(_ command: LumixCommand, timeoutInterval: TimeInterval?) async throws -> LumixCommandReply
}

extension LumixClient: RemoteCameraControlling {}

extension RemoteCameraControlling {
    /// Sends a command, retrying while the camera answers `err_busy`.
    func send(
        _ command: LumixCommand,
        busyRetries: Int = 3,
        busyDelay: Duration = .seconds(1),
        timeoutInterval: TimeInterval? = nil
    ) async throws -> LumixCommandReply {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let reply = try await perform(command, timeoutInterval: timeoutInterval)
            guard reply.isBusy, attempt < busyRetries else { return reply }
            attempt += 1
            try await Task.sleep(for: busyDelay)
        }
    }

    /// Like `send`, but throws `LumixError.cameraRejected` for any result other than `ok`.
    @discardableResult
    func sendChecked(
        _ command: LumixCommand,
        busyRetries: Int = 3,
        busyDelay: Duration = .seconds(1),
        timeoutInterval: TimeInterval? = nil
    ) async throws -> LumixCommandReply {
        let reply = try await send(command, busyRetries: busyRetries, busyDelay: busyDelay, timeoutInterval: timeoutInterval)
        guard reply.isOK else {
            throw LumixError.cameraRejected(code: reply.result, command: command.description)
        }
        return reply
    }

    func cameraState(timeoutInterval: TimeInterval? = nil) async throws -> LumixCameraState {
        let reply = try await perform(.getState, timeoutInterval: timeoutInterval)
        guard let state = LumixCameraState(reply: reply) else {
            throw LumixError.cameraRejected(code: reply.result, command: LumixCommand.getState.description)
        }
        return state
    }

    func setting(_ type: String) async throws -> LumixSettingValue? {
        let reply = try await send(.getSetting(type), busyRetries: 1, busyDelay: .milliseconds(300))
        return LumixSettingValue(reply: reply, type: type)
    }

    func capabilityInfo() async throws -> CameraCapabilities {
        let reply = try await perform(.getInfo("capability"), timeoutInterval: 20)
        guard reply.isOK else {
            throw LumixError.cameraRejected(code: reply.result, command: "getinfo capability")
        }
        return CameraCapabilityParser.parse(Data(reply.raw.utf8))
    }
}

/// Runs camera commands one at a time, in order. Image App-era cameras handle
/// overlapping control requests poorly, and Panasonic's app serializes them too.
actor CameraCommandGate {
    private var isRunning = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<Value: Sendable>(_ operation: @Sendable () async throws -> Value) async throws -> Value {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async {
        guard isRunning else {
            isRunning = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            isRunning = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
