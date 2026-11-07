import Foundation
import XCTest
@testable import GM1Sync

@MainActor
final class CameraModeCoordinatorTests: XCTestCase {
    func testSharedPlaybackPreparationWaitsForTheExclusiveActivity() async throws {
        let coordinator = CameraModeCoordinator()
        let lease = try await coordinator.beginExclusive(.remoteShooting)
        let log = OperationLog()

        let preparation = Task { @MainActor in
            try await coordinator.performSharedOperation { await log.append("playmode") }
        }
        try await Task.sleep(for: .milliseconds(80))
        let beforeEnd = await log.entries
        XCTAssertTrue(beforeEnd.isEmpty, "Playback preparation must not run while remote shooting holds the camera")

        coordinator.endExclusive(lease)
        try await preparation.value
        let afterEnd = await log.entries
        XCTAssertEqual(afterEnd, ["playmode"])
        XCTAssertEqual(coordinator.completedExclusiveActivities, 1)
        XCTAssertEqual(coordinator.lastCompletedActivity, .remoteShooting)
    }

    func testExclusiveActivityWaitsForAnInFlightPreparation() async throws {
        let coordinator = CameraModeCoordinator()
        let gate = AsyncGate()
        let preparation = Task { @MainActor in
            try await coordinator.performSharedOperation { await gate.wait() }
        }
        try await Task.sleep(for: .milliseconds(30))

        let exclusive = Task { @MainActor in try await coordinator.beginExclusive(.remoteShooting) }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(coordinator.exclusiveActivity, .remoteShooting, "The pending activity is visible")
        XCTAssertFalse(coordinator.isExclusiveActivityRunning, "…but it is not granted while playmode is in flight")

        await gate.open()
        try await preparation.value
        let lease = try await exclusive.value
        XCTAssertTrue(coordinator.isValid(lease))
        coordinator.endExclusive(lease)
    }

    func testOnlyOneExclusiveActivityAtATime() async throws {
        let coordinator = CameraModeCoordinator()
        let lease = try await coordinator.beginExclusive(.remoteShooting)
        do {
            _ = try await coordinator.beginExclusive(CameraActivity(id: "other", title: "Other", mode: .playback))
            XCTFail("A second exclusive activity must be refused")
        } catch let error as CameraModeCoordinatorError {
            XCTAssertEqual(error, .busy(.remoteShooting))
        }
        coordinator.endExclusive(lease)
        coordinator.endExclusive(lease)
        XCTAssertEqual(coordinator.completedExclusiveActivities, 1, "Ending twice is harmless")
        let next = try await coordinator.beginExclusive(.remoteShooting)
        coordinator.endExclusive(next)
    }

    func testCancelledPreparationNeverRuns() async throws {
        let coordinator = CameraModeCoordinator()
        let lease = try await coordinator.beginExclusive(.remoteShooting)
        let log = OperationLog()
        let preparation = Task { @MainActor in
            try await coordinator.performSharedOperation { await log.append("playmode") }
        }
        try await Task.sleep(for: .milliseconds(40))
        preparation.cancel()
        do {
            try await preparation.value
            XCTFail("A cancelled preparation must not complete")
        } catch is CancellationError {}
        coordinator.endExclusive(lease)
        try await Task.sleep(for: .milliseconds(40))
        let entries = await log.entries
        XCTAssertTrue(entries.isEmpty)
    }

    func testConnectionChangeRevokesTheActivityAndInvalidatesItsLease() async throws {
        let scope = CameraConnectionScope()
        let coordinator = CameraModeCoordinator(connectionScope: scope)
        let lease = try await coordinator.beginExclusive(.remoteShooting)
        var revoked = false
        lease.onRevoked = { revoked = true }
        XCTAssertTrue(coordinator.isValid(lease))

        scope.invalidate()
        XCTAssertFalse(coordinator.isValid(lease), "A lease from an earlier connection is never valid")

        let log = OperationLog()
        let preparation = Task { @MainActor in
            try await coordinator.performSharedOperation { await log.append("playmode") }
        }
        try await Task.sleep(for: .milliseconds(40))
        coordinator.connectionDidChange()
        try await preparation.value
        XCTAssertTrue(revoked)
        XCTAssertNil(coordinator.exclusiveActivity)
        let entries = await log.entries
        XCTAssertEqual(entries, ["playmode"])
    }

    func testStaleClientRefusesRequestsBeforeTouchingTheNetwork() async throws {
        let scope = CameraConnectionScope()
        // Nothing listens on this address; a stale client must fail without trying.
        let client = LumixClient(host: "127.0.0.1", connectionScope: scope)
        XCTAssertTrue(client.belongsToCurrentConnection)
        scope.invalidate()
        XCTAssertFalse(client.belongsToCurrentConnection)

        let started = Date()
        do {
            _ = try await client.perform(.getState)
            XCTFail("A stale client must refuse to send")
        } catch let error as LumixError {
            XCTAssertEqual(error, .staleConnection)
        }
        do {
            _ = try await client.prepareForBrowsing()
            XCTFail("A stale client must not switch the new camera into playback")
        } catch let error as LumixError {
            XCTAssertEqual(error, .staleConnection)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)

        let fresh = LumixClient(host: "127.0.0.1", connectionScope: scope)
        XCTAssertTrue(fresh.belongsToCurrentConnection)
    }

    func testViewModelStartsANewConnectionGenerationOnEveryTransition() async throws {
        let reachability = ReachabilitySwitch(isReachable: true)
        let model = ProbeViewModel(
            cameraNetworkStore: KeychainCameraNetworkStore(service: UUID().uuidString),
            checkCamera: { _, _ in await reachability.value }
        )
        await model.refreshConnectionStatus()
        XCTAssertTrue(model.isCameraConnected)
        let connectedClient = model.makeClient()
        let connectedGeneration = model.connectionGeneration
        XCTAssertTrue(connectedClient.belongsToCurrentConnection)

        await reachability.set(false)
        await model.refreshConnectionStatus()
        XCTAssertFalse(model.isCameraConnected)
        XCTAssertNotEqual(model.connectionGeneration, connectedGeneration)
        XCTAssertFalse(connectedClient.belongsToCurrentConnection, "Requests from the old connection are refused")

        await reachability.set(true)
        await model.refreshConnectionStatus()
        XCTAssertTrue(model.isCameraConnected)
        XCTAssertFalse(connectedClient.belongsToCurrentConnection, "…even after the camera comes back at the same address")
        XCTAssertTrue(model.makeClient().belongsToCurrentConnection)

        let beforeHostChange = model.makeClient()
        model.host = "192.168.54.2"
        XCTAssertFalse(beforeHostChange.belongsToCurrentConnection)
    }
}

actor OperationLog {
    private(set) var entries: [String] = []
    func append(_ entry: String) { entries.append(entry) }
}

actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private actor ReachabilitySwitch {
    private(set) var value: Bool
    init(isReachable: Bool) { value = isReachable }
    func set(_ isReachable: Bool) { value = isReachable }
}
