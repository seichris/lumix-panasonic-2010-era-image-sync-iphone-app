import Foundation

/// Something that needs the camera in a particular operating mode.
struct CameraActivity: Hashable, Sendable, CustomStringConvertible {
    let id: String
    let title: String
    let mode: LumixCameraMode?

    var description: String { title }

    static let gallery = CameraActivity(id: "gallery", title: "Browsing camera media", mode: .playback)
    static let remoteShooting = CameraActivity(id: "remote-shooting", title: "Remote shooting", mode: .record)
}

enum CameraModeCoordinatorError: LocalizedError, Equatable {
    case busy(CameraActivity)
    case connectionChanged

    var errorDescription: String? {
        switch self {
        case let .busy(activity): return "\(activity.title) is using the camera. Finish it first."
        case .connectionChanged: return "The camera connection changed."
        }
    }
}

/// Grants one exclusive camera activity at a time.
@MainActor
final class CameraActivityLease {
    let id = UUID()
    let activity: CameraActivity
    let connection: CameraConnectionToken?
    fileprivate(set) var isActive = true
    /// Called when the coordinator revokes the lease because the camera connection changed.
    var onRevoked: (@MainActor () -> Void)?

    fileprivate init(activity: CameraActivity, connection: CameraConnectionToken?) {
        self.activity = activity
        self.connection = connection
    }
}

/// Coordinates which part of the app may change the camera's operating mode.
///
/// The gallery switches the camera into playback mode whenever it prepares to
/// browse. That must not happen while remote shooting holds the camera in record
/// mode, and remote shooting must not start while a gallery preparation is in
/// flight. Shared gallery preparations therefore wait for an exclusive activity
/// to end, and an exclusive activity waits for in-flight preparations to drain.
@MainActor
final class CameraModeCoordinator: ObservableObject {
    @Published private(set) var exclusiveActivity: CameraActivity?
    /// Incremented whenever an exclusive activity ends; observers reload state the activity changed.
    @Published private(set) var completedExclusiveActivities = 0
    private(set) var lastCompletedActivity: CameraActivity?

    private let connectionScope: CameraConnectionScope?
    private var exclusiveLease: CameraActivityLease?
    private var sharedOperations = 0
    private var sharedWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var sharedWaiterOrder: [UUID] = []
    private var exclusiveWaiter: (id: UUID, continuation: CheckedContinuation<Void, Error>)?

    init(connectionScope: CameraConnectionScope? = nil) {
        self.connectionScope = connectionScope
    }

    var isExclusiveActivityRunning: Bool { exclusiveLease != nil }

    // MARK: Shared playback operations (gallery)

    /// Runs a playback-mode preparation, waiting while an exclusive activity owns the camera.
    func performSharedOperation<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        try await waitForSharedAccess()
        sharedOperations += 1
        defer {
            sharedOperations -= 1
            resumeExclusiveWaiterIfPossible()
        }
        return try await operation()
    }

    private func waitForSharedAccess() async throws {
        try Task.checkCancellation()
        // An exclusive request that is waiting for drainage keeps priority, so a
        // stream of gallery refreshes cannot starve remote shooting.
        guard exclusiveLease != nil || exclusiveWaiter != nil else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sharedWaiters[id] = continuation
                sharedWaiterOrder.append(id)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelSharedWaiter(id) }
        }
    }

    private func cancelSharedWaiter(_ id: UUID) {
        sharedWaiterOrder.removeAll { $0 == id }
        sharedWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func resumeSharedWaiters() {
        guard exclusiveLease == nil, exclusiveWaiter == nil else { return }
        let order = sharedWaiterOrder
        sharedWaiterOrder = []
        for id in order {
            sharedWaiters.removeValue(forKey: id)?.resume()
        }
    }

    // MARK: Exclusive activities (remote shooting, location writing, push transfer)

    /// Claims the camera for one exclusive activity. Fails immediately when another
    /// exclusive activity is running; waits for in-flight gallery preparations.
    func beginExclusive(_ activity: CameraActivity) async throws -> CameraActivityLease {
        try Task.checkCancellation()
        if let current = exclusiveLease?.activity ?? (exclusiveWaiter != nil ? exclusiveActivity : nil) {
            throw CameraModeCoordinatorError.busy(current)
        }
        guard exclusiveWaiter == nil else { throw CameraModeCoordinatorError.busy(activity) }
        let connection = connectionScope?.current
        exclusiveActivity = activity

        if sharedOperations > 0 {
            let id = UUID()
            do {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        exclusiveWaiter = (id, continuation)
                    }
                } onCancel: {
                    Task { @MainActor [weak self] in self?.cancelExclusiveWaiter(id) }
                }
            } catch {
                if exclusiveLease == nil { exclusiveActivity = nil }
                resumeSharedWaiters()
                throw error
            }
        }

        if let connectionScope, let connection, !connectionScope.isCurrent(connection) {
            exclusiveActivity = nil
            resumeSharedWaiters()
            throw CameraModeCoordinatorError.connectionChanged
        }
        let lease = CameraActivityLease(activity: activity, connection: connection)
        exclusiveLease = lease
        exclusiveActivity = activity
        return lease
    }

    /// Ends an exclusive activity. Safe to call more than once.
    func endExclusive(_ lease: CameraActivityLease) {
        guard lease.isActive else { return }
        lease.isActive = false
        guard exclusiveLease?.id == lease.id else { return }
        exclusiveLease = nil
        exclusiveActivity = nil
        lastCompletedActivity = lease.activity
        completedExclusiveActivities += 1
        resumeSharedWaiters()
    }

    func isValid(_ lease: CameraActivityLease) -> Bool {
        guard lease.isActive, exclusiveLease?.id == lease.id else { return false }
        guard let connectionScope, let connection = lease.connection else { return true }
        return connectionScope.isCurrent(connection)
    }

    /// Revokes the exclusive activity after the camera connection changed. The
    /// owner is told through `onRevoked` and must stop using the camera.
    func connectionDidChange() {
        if let waiter = exclusiveWaiter {
            exclusiveWaiter = nil
            waiter.continuation.resume(throwing: CameraModeCoordinatorError.connectionChanged)
        }
        if let lease = exclusiveLease {
            let onRevoked = lease.onRevoked
            endExclusive(lease)
            onRevoked?()
        } else {
            exclusiveActivity = nil
            resumeSharedWaiters()
        }
    }

    private func cancelExclusiveWaiter(_ id: UUID) {
        guard let waiter = exclusiveWaiter, waiter.id == id else { return }
        exclusiveWaiter = nil
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func resumeExclusiveWaiterIfPossible() {
        guard sharedOperations == 0, let waiter = exclusiveWaiter else { return }
        exclusiveWaiter = nil
        waiter.continuation.resume()
    }
}
